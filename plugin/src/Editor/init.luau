--!strict

-- ******************************* --
-- 			AX3NX / AXEN		   --
-- ******************************* --

---- Services ----

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")

---- Imports ----

local Analysis = require("@self/Analysis")
local Completion = require("@self/Completion")
local Diagnostics = require("@self/Diagnostics")
local Gutter = require("@self/Gutter")
local Highlight = require("@self/Highlight")
local Popup = require("@self/Popup")
local Spans = require("@self/Spans")
local State = require("./State")
local Theme = require("@self/Theme")
local Utility = require("@self/Utility")

local Instances = require("./Instances")
local Profiler = require("./Profiler")

local Lexer = require("@compiler/Lexer")
local Parser = require("@compiler/Parser")

local Error = require("@compiler/Modules/Error")

local StylingHooks: { { OnSourceChanged: (Text: string, PreviousText: string, Cursor: number, Gain: number) -> (string, number) } } =
	{
		require("@self/Styling/AutoIndent"),
		require("@self/Styling/AutoBracket"),
	}

---- Settings ----

local THEME = Theme.THEME
local PALETTE = Theme.PALETTE

local SCROLL_LINES = 2
local CURSOR_BLINK_RATE = 0.5
local PRE_ALLOCATED_LINES = 2_000

type CompletionItem = Completion.Item

---- Constants ----

local Editor = {}

--> Interface Instances
local Container: typeof(script.Parent.Widget) = script.Widget
local EditorContainer = Container.Editor
local CompletionContainer = Container.Completion

local TextContainer = EditorContainer.Text
local LinesContainer = EditorContainer.Lines

local Input = TextContainer.Input
local Cursor = TextContainer.Cursor
local Display = TextContainer.Display
local Selection = TextContainer.Selection
local ErrorSelection = TextContainer.Error

local ErrorContainer = Container.Error
local ErrorText = ErrorContainer.Text

local LineTemplate = LinesContainer.Line:Clone()
local ErrorTemplate = ErrorSelection.Line:Clone()
local SelectionTemplate = Selection.Line:Clone()
local CompletionTemplate = CompletionContainer.Option:Clone()

local TextSize = Input.TextSize
local TextHeight = TextSize * Display.LineHeight

local LineGutter = Gutter.new(LinesContainer, LineTemplate :: any, TextHeight, THEME.Line)

--> Objects
local SourceLexer = Lexer.new("Highlighting")

local EditorWidget: DockWidgetPluginGui

---- Variables ----

local Scroll = State.new(0)
local Predictions: State.Class<{ Index: number, Items: { CompletionItem } }> = State.new({ Index = 1, Items = {} })

local CursorTimer = 0
local PreviousText = Input.Text
local PreviousCursorPosition: number?
local NavigationPending: { Direction: number, Position: number }?
local CompletionPending: boolean?
local IgnoreCursorChange: boolean?

local AnalysisError: State.Class<Error.Class?> = State.new(nil :: any)
local SourceAnalysis = Analysis.new(function(Diagnostic)
	AnalysisError:Set(Diagnostic)
end)
local RenderedDiagnostic: string?
local AbstractSyntaxTree: Parser.Body?

---- Private Functions ----

local function ScrollTowards(Direction: number)
	local Value = Scroll:Get()
	local Maximum = math.max(1, (Input.TextBounds.Y - EditorContainer.AbsoluteSize.Y) // TextHeight + SCROLL_LINES)
	Scroll:Set(math.clamp(Value + (Direction * SCROLL_LINES), 0, Maximum))
end

local function GetPrediction(): CompletionItem?
	local Items = Predictions:Get()
	return Items.Items[Items.Index]
end

local function UpdateColors()
	--> One assignment, not two. This used to write the plain source first "to render text
	--> immediately" and then overwrite it with the highlighted version in the same frame, so the
	--> engine laid out and rich-text-parsed the whole document twice and drew the first pass never.
	Display.TextColor3 = THEME.Text
	Display.Text = Highlight.Render(Input.Text, SourceLexer, PALETTE)
end

local function UpdateAnalysis()
	local Tree = SourceAnalysis:Run(Editor.GetSource())
	if Tree then
		AbstractSyntaxTree = Tree
	end
end

local function UpdateCompletion()
	local Symbols = if AbstractSyntaxTree then AbstractSyntaxTree.Value.Symbols else nil
	Predictions:Set({
		Index = 1,
		Items = Completion.Match(Input.Text, Input.CursorPosition, Symbols),
	})
end

local function UpdateHighlightedLine()
	--> GetCurrentLine also returns the lines; only the number is wanted.
	LineGutter:Highlight((Utility.GetCurrentLine(Input.Text, Input.CursorPosition)))
end

---- Event Functions -----

local function OnPreRender(DeltaTime: number)
	if NavigationPending then
		local Navigation = NavigationPending
		NavigationPending = nil

		local Value = Predictions:Get()
		local Count = #Value.Items
		if Count > 0 then
			--> Cursor should be first for proper autocomplete positioning
			local NavigationPosition = Navigation.Position
			IgnoreCursorChange = true
			Input.CursorPosition = NavigationPosition
			PreviousCursorPosition = NavigationPosition

			Predictions:Set({
				Index = Completion.Step(Value.Index, Count, Navigation.Direction),
				Items = Value.Items,
			})
		end
	elseif CompletionPending then
		UpdateCompletion()
	end

	CompletionPending = nil

	if Input.CursorPosition == -1 then
		return
	end

	CursorTimer += DeltaTime
	if CursorTimer < CURSOR_BLINK_RATE then
		return
	end

	CursorTimer -= CURSOR_BLINK_RATE
	Cursor.Visible = not Cursor.Visible
end

--> State functions
local function OnLinesChanged(Value: number)
	LineGutter:Resize(Value)
	UpdateHighlightedLine()
end

local function OnScrollChanged(Value: number)
	EditorContainer.Position = UDim2.fromOffset(EditorContainer.Position.X.Offset, TextHeight * -Value)
end

local function OnPredictionsChanged()
	local Value = Predictions:Get()
	Popup.Render({
		Container = CompletionContainer :: any,
		Template = CompletionTemplate :: any,
		Anchor = Cursor.AbsolutePosition,
		Area = EditorContainer.AbsoluteSize,
		LineHeight = TextSize,
		Highlight = THEME.Complete,
	}, Value.Items, Value.Index)
end

local function OnAnalysisErrorChanged()
	local Diagnostic = AnalysisError:Get()

	--> Nothing to redraw.
	-->
	--> This is not a micro-optimisation. State.Set re-notifies unconditionally for table values, and
	--> UpdateAnalysis builds a fresh Error object on every parse -- and while a schema is being typed
	--> it is almost always incomplete, so the parser throws on almost every keystroke. The result was
	--> that this whole function ran per character even when the error had not changed: it destroyed
	--> and rebuilt the underline frames, cloning one per line from the top of the file down to the
	--> error, and called the YIELDING GetTextBoundsAsync up to twice for the line it kept.
	local Key = Diagnostics.Key(Diagnostic, Input.ContentText)
	if Key == RenderedDiagnostic then
		return
	end

	RenderedDiagnostic = Key

	--> Clear previous error
	ErrorContainer.Visible = false
	Instances.ClearChildrenWhichAre(ErrorSelection, "Frame")

	--> No errors
	if not Diagnostic then
		return
	end

	local Labels = Diagnostic.Labels
	if #Labels == 0 then
		return
	end

	local IsWarning = (Diagnostic.Severity == "Warning")
	local Message = Diagnostics.Message(Diagnostic, Input.Text, THEME)
	ErrorText.Text = Message

	--> Underline where the primary label begins.
	local Primary = Labels[#Labels]
	local Span = Primary.Span

	Spans.Draw({
		Template = ErrorTemplate :: any,
		Parent = ErrorSelection,
		Text = string.sub(Input.ContentText, 1, Span.End),
		Start = Span.Start,
		Finish = Span.End,
		LineHeight = TextHeight,
		TextSize = TextSize,
		Font = Display.FontFace,
		FillOffset = 10,
		FirstLineOnly = true,
		Decorate = Diagnostics.Underline(ErrorContainer, EditorWidget, if IsWarning then THEME.Warning else nil),
	})
end

--> RBXScriptSignal functions

local function OnCursorPositionChanged()
	local CursorPosition = Input.CursorPosition
	if CursorPosition == -1 then
		Cursor.Visible = false
		return
	end

	Profiler.profileBegin("Cursor")

	local Text = string.sub(Input.Text, 1, CursorPosition - 1)
	local Slices = string.split(Text, "\n")

	--> Calculate current end line position
	local Line = Slices[#Slices] or ""
	local TextBounds = Spans.Measure(Line, TextSize, Display.FontFace)

	--> Update cursor size and position
	Cursor.Size = UDim2.fromOffset(2, TextSize)
	Cursor.Position = UDim2.fromOffset(TextBounds.X - 1, TextHeight * (#Slices - 1))

	--> Update highlighted line
	Profiler.profileBegin("Highlight LN")
	UpdateHighlightedLine()
	Profiler.profileEnd()

	--> Ignore navigation or completion when cursor restored by OnPreRender
	if IgnoreCursorChange then
		IgnoreCursorChange = nil
	elseif #Predictions:Get().Items > 0 then
		CompletionPending = true

		local Direction = PreviousCursorPosition
			and Completion.Navigation(Input.Text, CursorPosition, PreviousCursorPosition)
		if PreviousCursorPosition and Direction then
			NavigationPending = { Direction = Direction, Position = PreviousCursorPosition }
		end
	end

	PreviousCursorPosition = CursorPosition
	Profiler.profileEnd()
end

local function OnSelectionChanged()
	--> Clear previous selection
	Instances.ClearChildrenWhichAre(Selection, "Frame")

	--> Nothing is selected
	local CursorPosition = Input.CursorPosition
	local SelectionStart = Input.SelectionStart
	if CursorPosition == -1 or SelectionStart == -1 then
		return
	end

	local Start = math.min(CursorPosition, SelectionStart)
	local Finish = math.max(CursorPosition, SelectionStart)

	Spans.Draw({
		Template = SelectionTemplate :: any,
		Parent = Selection,
		Text = string.sub(Input.ContentText, 1, Finish - 1),
		Start = Start,
		Finish = Finish,
		LineHeight = TextHeight,
		TextSize = TextSize,
		Font = Display.FontFace,
		FillOffset = 0,
		FirstLineOnly = false,
	})
end

local function OnSourceChanged()
	NavigationPending = nil
	CompletionPending = nil

	--> Pressing enter inserts a carriage return (ROBLOX please fix)
	local Text = Input.Text
	local Gain = math.sign(#Text - #PreviousText)

	local NoReturnCarriage = string.gsub(Text, "\r", "")
	if NoReturnCarriage ~= Text then
		Input.Text = NoReturnCarriage
		return
	end

	--> Auto complete
	if Gain == 1 then
		Profiler.profileBegin("Insertion")

		local Item = GetPrediction()
		local Tab = (Input.CursorPosition - 1)

		if Item and string.sub(Text, Tab, Tab) == "\t" then
			local Expanded, Position = Completion.Expand(Text, Tab, Item)

			PreviousText = Expanded
			Input.Text = Expanded

			Input.CursorPosition = -1
			Input.CursorPosition = Position

			Profiler.profileEnd()
			return
		end

		Profiler.profileEnd()
	end

	--> Run styling hooks
	Profiler.profileBegin("Styling")

	local FinalText, FinalCursor = Text, Input.CursorPosition
	for _, Hook in StylingHooks do
		FinalText, FinalCursor = Hook.OnSourceChanged(FinalText, PreviousText, FinalCursor, Gain)
	end

	Profiler.profileEnd()

	--> Update previous text
	PreviousText = FinalText

	--> If a styling hook altered the final text then don't do any additional work
	if FinalText ~= Text then
		Input.Text = FinalText
		Input.CursorPosition = FinalCursor

		return
	end

	--> Update line counter
	Profiler.profileBegin("Line counter")

	local Slices = string.split(Text, "\n")
	if #Slices ~= LineGutter.Count then
		OnLinesChanged(#Slices)
	end

	Profiler.profileEnd()

	--> Perform lexer pass
	Profiler.profileBegin("Analysis")
	UpdateAnalysis()
	Profiler.profileEnd()

	Profiler.profileBegin("Completion")
	UpdateCompletion()
	Profiler.profileEnd()

	Profiler.profileBegin("Highlighting")
	UpdateColors()
	Profiler.profileEnd()

	--> Update cursor after text change
	PreviousCursorPosition = Input.CursorPosition
	OnCursorPositionChanged()
end

---- Public Functions ----

function Editor.GetSource(): string
	return Input.Text
end

function Editor.SetSource(Source: string)
	Scroll:Set(0)
	Input.Text = Source
end

---- Initialization ----

function Editor.Initialize(Widget: DockWidgetPluginGui)
	EditorWidget = Widget
	--> Create lines in the background
	task.spawn(LineGutter.PreallocateAsync, LineGutter, PRE_ALLOCATED_LINES)

	--> Preload fira sans
	ContentProvider:PreloadAsync({ Display }, function(AssetId: string, AssetFetchStatus: Enum.AssetFetchStatus)
		if AssetId ~= "" and AssetFetchStatus ~= Enum.AssetFetchStatus.Success then
			warn("[BlinkBlox] There was an issue preloading the editors font.")
		end
	end)

	--> Remove templates
	Selection.Line:Destroy()
	ErrorSelection.Line:Destroy()
	LinesContainer.Line:Destroy()
	CompletionContainer.Option:Destroy()

	Spans.Prepare({ Selection, ErrorSelection })

	--> Connections
	Error.OnEmit = function(Diagnostic)
		return SourceAnalysis:Emitted(Diagnostic)
	end

	Scroll:OnChange(OnScrollChanged)
	Predictions:OnChange(OnPredictionsChanged)
	AnalysisError:OnChange(OnAnalysisErrorChanged)

	--> Fixes a weird bug with the cursor being moved to character 6000
	Input.Focused:Once(function()
		Input:ReleaseFocus(true)
		RunService.PreRender:Wait()

		Input:CaptureFocus()
		Input.CursorPosition = 1
	end)

	Input:GetPropertyChangedSignal("Text"):Connect(function()
		Profiler.profileBegin("Total")
		OnSourceChanged()
		Profiler.profileEnd()
	end)

	Input:GetPropertyChangedSignal("SelectionStart"):Connect(OnSelectionChanged)
	Input:GetPropertyChangedSignal("CursorPosition"):Connect(OnSelectionChanged)
	Input:GetPropertyChangedSignal("CursorPosition"):Connect(OnCursorPositionChanged)
	Input.InputChanged:Connect(function(InputObject)
		if InputObject.UserInputType == Enum.UserInputType.MouseWheel then
			ScrollTowards(-InputObject.Position.Z)
		end
	end)

	RunService.PreRender:Connect(OnPreRender)
end

return Editor
