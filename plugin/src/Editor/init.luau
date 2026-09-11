--!strict

-- ******************************* --
-- 			AX3NX / AXEN		   --
-- ******************************* --

---- Services ----

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

---- Imports ----

local Highlight = require("@self/Highlight")
local State = require("./State")
local Utility = require("@self/Utility")

local Profiler = require("./Profiler")

local Lexer = require("@compiler/Lexer")
local Parser = require("@compiler/Parser")
local Settings = require("@compiler/Settings")

local Error = require("@compiler/Modules/Error")

local StylingHooks: { { OnSourceChanged: (Text: string, PreviousText: string, Cursor: number, Gain: number) -> (string, number) } } =
	{
		require("@self/Styling/AutoIndent"),
		require("@self/Styling/AutoBracket"),
	}

---- Settings ----

local ICONS = {
	Event = "rbxassetid://16506730516",
	Field = "rbxassetid://16506725096",
	Snippet = "rbxassetid://16506712161",
	Keyword = "rbxassetid://16506695241",
	Variable = "rbxassetid://16506719167",
	Primitive = "rbxassetid://16506695241",
}

local THEME = {
	Text = Color3.fromHex("#FFFFFF"),
	Keyword = Color3.fromHex("#6796E6"),
	Primitive = Color3.fromHex("#4EC9B0"),
	Identifier = Color3.fromHex("#9CDCFE"),

	Class = Color3.fromHex("#B5CEA8"),
	Number = Color3.fromHex("#B5CEA8"),
	String = Color3.fromHex("#ADF195"),
	Bracket = Color3.fromHex("#FFFFFF"),
	Boolean = Color3.fromHex("#B5CEA8"),
	Comment = Color3.fromHex("#529955"),

	Error = Color3.fromHex("#FF5050"),
	Warning = Color3.fromHex("#D7BA7D"),

	Complete = Color3.fromHex("#04385f"),

	Line = {
		Active = Color3.fromHex("FFFFFF"),
		Inactive = Color3.fromHex("787878"),
	},
}

--> The same colours as hex, which is what rich-text markup takes. Built once: ToHex allocates, and
--> the highlighter asks for a colour per token.
local PALETTE: Highlight.Palette = {
	Text = THEME.Text:ToHex(),
	Keyword = THEME.Keyword:ToHex(),
	Primitive = THEME.Primitive:ToHex(),
	Identifier = THEME.Identifier:ToHex(),
	Class = THEME.Class:ToHex(),
	Number = THEME.Number:ToHex(),
	String = THEME.String:ToHex(),
	Bracket = THEME.Bracket:ToHex(),
	Boolean = THEME.Boolean:ToHex(),
	Comment = THEME.Comment:ToHex(),
	Error = THEME.Error:ToHex(),
}
-- This is a comment
local PRIMITIVES = {}
for Primitive in Settings.Primtives do
	table.insert(PRIMITIVES, { Label = Primitive, Insert = Primitive })
end

local SYMBOLS: { [string]: { { Label: string, Insert: string } } } = {
	Event = {},
	Field = {},
	Snippet = {},
	Keyword = {
		{ Label = "set", Insert = "set %s = {}" },
		{ Label = "map", Insert = "map %s = {[]: }" },
		{ Label = "type", Insert = "type %s = " },
		{ Label = "enum", Insert = "enum %s = {}" },
		{ Label = "struct", Insert = "struct %s {}" },
		{ Label = "event", Insert = "event %s {}" },
		{ Label = "function", Insert = "function %s {}" },
		{ Label = "import", Insert = "import %s as " },
		{ Label = "scope", Insert = "scope %s {}" },
		{ Label = "export", Insert = "export " },
	},
	Variable = {},
	Primitive = PRIMITIVES,
}

local SCROLL_LINES = 2
local CURSOR_BLINK_RATE = 0.5
local PRE_ALLOCATED_LINES = 2_000

type CompletionItem = {
	Icon: string,
	Label: string,
	Insert: string,
}

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

--> Objects
local SourceLexer = Lexer.new("Highlighting")
local SourceParser = Parser.new()

local EditorWidget: DockWidgetPluginGui

---- Variables ----

local Lines = 0
local Scroll = State.new(0)
local Predictions: State.Class<{ Index: number, Items: { CompletionItem } }> = State.new({ Index = 1, Items = {} })

local CursorTimer = 0
local PreviousText = Input.Text
local PreviousLine: TextLabel?
local PreviousCursorPosition: number?
local NavigationPending: { Direction: number, Position: number }?
local CompletionPending: boolean?
local IgnoreCursorChange: boolean?

local AnalysisError: State.Class<Error.Class?> = State.new(nil :: any)
local RenderedDiagnostic: string?
local AbstractSyntaxTree: Parser.Body?

---- Private Functions ----

local function ScrollTowards(Direction: number)
	local Value = Scroll:Get()
	local Maximum = math.max(1, (Input.TextBounds.Y - EditorContainer.AbsoluteSize.Y) // TextHeight + SCROLL_LINES)
	Scroll:Set(math.clamp(Value + (Direction * SCROLL_LINES), 0, Maximum))
end

local function ClearChildrenWhichAre(Parent: Instance, Class: string)
	for _, Child in Parent:GetChildren() do
		if Child:IsA(Class) then
			Child:Destroy()
		end
	end
end

local function GetLineAtPosition(Text: string, Position: number): number
	local _, Count = string.gsub(string.sub(Text, 1, Position - 1), "\n", "")
	return Count + 1
end

local function GetPrediction(): CompletionItem?
	local Items = Predictions:Get()
	local Item = Items.Items[Items.Index]
	if not Item then
		return
	end

	return Item
end

local function UpdateColors()
	--> One assignment, not two. This used to write the plain source first "to render text
	--> immediately" and then overwrite it with the highlighted version in the same frame, so the
	--> engine laid out and rich-text-parsed the whole document twice and drew the first pass never.
	Display.TextColor3 = THEME.Text
	Display.Text = Highlight.Render(Input.Text, SourceLexer, PALETTE)
end

local function UpdateAnalysis()
	local Success, Result = pcall(function()
		return SourceParser:Parse(Editor.GetSource())
	end)

	if Success then
		AnalysisError:Set(nil)
		AbstractSyntaxTree = Result
	end
end

local function UpdateCompletion()
	local Line = Utility.GetLineRangeAtPosition(Input.Text, Input.CursorPosition)
	local Items: { CompletionItem } = {}

	--> Match Keywords
	local function MatchSymbols()
		local Word = Utility.GetWordRangeAtPosition(Line.Text, Input.CursorPosition - Line.Start)
		local Text = Word.Text
		if #Text == 0 then
			return
		end

		--> Match keywords
		if Word.Index == 1 then
			for _, Symbol in SYMBOLS.Keyword do
				local Label = Symbol.Label
				local Stub = string.sub(Label, 1, #Text)
				if Stub ~= Text or Stub == Label then
					continue
				end

				table.insert(Items, {
					Icon = ICONS.Keyword,
					Label = Label,
					Insert = Symbol.Insert,
				})
			end
		end

		--> Match symbols
		local Previous = Utility.GetWordRangeBeforePosition(Line.Text, Word.Start - 1)
		if Previous.Text == "" then
			return
		end

		if string.match(Previous.Text, ":$") or Previous.Text == "=" then
			for _, Symbol in SYMBOLS.Primitive do
				local Label = Symbol.Label
				local Stub = string.sub(Label, 1, #Text)
				if Stub ~= Text or Stub == Label then
					continue
				end

				table.insert(Items, {
					Icon = ICONS.Primitive,
					Label = Label,
					Insert = Label,
				})
			end

			if AbstractSyntaxTree then
				for Symbol in AbstractSyntaxTree.Value.Symbols do
					local Stub = string.sub(Symbol, 1, #Text)
					if Stub ~= Text or Stub == Symbol then
						continue
					end

					table.insert(Items, {
						Icon = ICONS.Variable,
						Label = Symbol,
						Insert = Symbol,
					})
				end
			end
		end
	end

	MatchSymbols()

	--> Update predictions
	Predictions:Set({
		Index = 1,
		Items = Items,
	})
end

--- The gutter label for a line, created if the pre-allocated run does not reach that far.
---
--- PRE_ALLOCATED_LINES labels are built at startup, and this used to index them directly. A document
--- longer than that found no child and threw -- "2001 is not a valid member of Frame" -- which took
--- the whole editor down rather than degrading. UpdateHighlightedLine already clamped; the line
--- counter and SetSource did not, so it was reachable just by typing or by opening a long file.
local function GetLine(Index: number): TextLabel
	local Existing = LinesContainer:FindFirstChild(tostring(Index))
	if Existing then
		return Existing :: TextLabel
	end

	local Line = LineTemplate:Clone()
	Line.Name = tostring(Index)
	Line.Text = tostring(Index)
	Line.TextColor3 = THEME.Line.Inactive
	Line.TextTransparency = 1
	Line.Position = UDim2.fromOffset(0, TextHeight * (Index - 1))
	Line.Parent = LinesContainer
	return Line
end

local function UpdateHighlightedLine()
	local Line = math.max(Utility.GetCurrentLine(Input.Text, Input.CursorPosition), 1)
	local Label = GetLine(Line)
	if PreviousLine then
		PreviousLine.TextColor3 = THEME.Line.Inactive
	end

	PreviousLine = Label
	Label.TextColor3 = THEME.Line.Active
end

---- Event Functions -----

local function OnErrorEmitted(Object: Error.Class)
	AnalysisError:Set(Object)
end

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
				Index = Navigation.Direction == -1 and ((Value.Index - 2) % Count) + 1 or (Value.Index % Count) + 1,
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
	--> Insert new or delete lines
	local Difference = (Value - Lines)

	if Difference > 0 then
		for Index = (Lines + 1), Value do
			GetLine(Index).TextTransparency = 0
		end
	elseif Difference < 0 then
		for Index = Lines, (Value + 1), -1 do
			GetLine(Index).TextTransparency = 1
		end
	end

	Lines = Value

	--> Update highlighted line
	UpdateHighlightedLine()
end

local function OnScrollChanged(Value: number)
	EditorContainer.Position = UDim2.fromOffset(EditorContainer.Position.X.Offset, TextHeight * -Value)
end

local function OnPredictionsChanged()
	local Value = Predictions:Get()
	local Items = Value.Items
	if #Items == 0 then
		CompletionContainer.Visible = false
		return
	end

	--> Update completion position
	local AbsoluteSize = EditorContainer.AbsoluteSize
	local AbsolutePosition = Cursor.AbsolutePosition
	local HorisontalWidth = math.max(0, (AbsoluteSize.X - CompletionContainer.Size.X.Offset) - 10)
	CompletionContainer.Position =
		UDim2.fromOffset(math.clamp(AbsolutePosition.X, 0, HorisontalWidth), AbsolutePosition.Y + TextSize)

	CompletionContainer.Visible = true
	ClearChildrenWhichAre(CompletionContainer, "Frame")

	for Index, Item in Items do
		local Frame = CompletionTemplate:Clone()
		Frame.Icon.Image = Item.Icon
		Frame.Text.Text = Item.Label

		if Index == Value.Index then
			Frame.BackgroundColor3 = THEME.Complete
		end

		Frame.Parent = CompletionContainer
	end
end

--- Everything the rendered diagnostic depends on, as one string.
---
--- The point is to answer "would this draw the same thing again?" without drawing it. What the
--- render reads is the diagnostic itself and the source UP TO the end of its span -- that decides
--- which line the underline sits on, how wide it is, and what line numbers the message quotes.
--- Anything typed after the error touches none of it.
local function DiagnosticKey(Diagnostic: Error.Class?): string?
	if not Diagnostic then
		return nil
	end

	local Labels = Diagnostic.Labels
	local Primary = Labels[#Labels]
	if not Primary then
		return nil
	end

	local Parts = { `{Diagnostic.Code}|{Diagnostic.Severity}|{Diagnostic.RawMessage}` }
	for _, Label in Labels do
		table.insert(Parts, `{Label.Span.Start}:{Label.Span.End}:{Label.Text}`)
	end

	table.insert(Parts, string.sub(Input.ContentText, 1, Primary.Span.End))
	return table.concat(Parts, "|")
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
	local Key = DiagnosticKey(Diagnostic)
	if Key == RenderedDiagnostic then
		return
	end

	RenderedDiagnostic = Key

	--> Clear previous error
	ErrorContainer.Visible = false
	ClearChildrenWhichAre(ErrorSelection, "Frame")

	--> No errors
	if not Diagnostic then
		return
	end

	local Labels = Diagnostic.Labels
	if #Labels == 0 then
		return
	end

	--> Error message
	local IsWarning = (Diagnostic.Severity == "Warning")
	local SeverityColor = IsWarning and THEME.Warning or THEME.Error
	local SeverityLabel = `<font color="#{SeverityColor:ToHex()}">{IsWarning and "Warning" or "Error"}</font>`

	local Message =
		`{SeverityLabel} {Error.GetNameFromCode(Diagnostic.Code)}: {Diagnostic.RawMessage} <font transparency="0.5"><i>Blink({Diagnostic.Code})</i></font>`
	for _, Label in Labels do
		local Line = Utility.GetCurrentLine(Input.Text, Label.Span.Start)
		Message ..= `\n{Label.Text} [L{Line}]`
	end

	ErrorText.Text = Message

	--> Highlight error
	local Primary = Labels[#Labels]

	local Span = Primary.Span
	local Start = Span.Start
	local Finish = Span.End

	local Text = string.sub(Input.ContentText, 1, Finish)
	local Slices = string.split(Text, "\n")

	local Offset = 0
	for Index, Slice in Slices do
		local First = Offset
		Offset += (#Slice + 1)

		--> Every line above the span used to get a zero-width frame of its own, for no reason except
		--> that a UIListLayout was doing the vertical positioning and needed something to stack. An
		--> error on line 800 therefore cost 800 clones per keystroke: 39ms, measured in Studio, and
		--> linear in the line number. Positioning by line makes it one frame wherever the error is.
		if Offset < Start then
			continue
		end

		local Line = ErrorTemplate:Clone()
		Line.Size = UDim2.new(1, 0, 0, TextHeight)
		Line.Position = UDim2.fromOffset(0, TextHeight * (Index - 1))
		local Fill = Line.Fill
		if IsWarning then
			Fill.TextColor3 = THEME.Warning
		end

		--> Calculate selection bounds
		local Substring = Slice
		if First < Start then
			Substring = string.sub(Slice, (Start - First), #Slice)
		elseif Index == #Slices then
			Substring = string.sub(Slice, 1, math.max(1, Finish - First))
		end

		--> Empty lines should appear as one space thick selections
		if Substring == "" then
			Substring = " "
		end

		local SelectionBoundsParams = Instance.new("GetTextBoundsParams")
		SelectionBoundsParams.Text = Substring
		SelectionBoundsParams.Size = TextSize
		SelectionBoundsParams.Font = Display.FontFace

		local SelectionBounds = TextService:GetTextBoundsAsync(SelectionBoundsParams)
		Fill.Size = UDim2.new(0, SelectionBounds.X, 1, 0)

		--> Calculate selection offset
		if Start > First then
			local Prefix = string.sub(Slice, 1, (Start - First) - 1)
			if Prefix ~= "" then
				local OffsetBoundsParams = Instance.new("GetTextBoundsParams")
				OffsetBoundsParams.Text = Prefix
				OffsetBoundsParams.Size = TextSize
				OffsetBoundsParams.Font = Display.FontFace

				local OffsetBounds = TextService:GetTextBoundsAsync(OffsetBoundsParams)
				Fill.Position = UDim2.new(0, OffsetBounds.X, 0, 10)
			end
		end

		Line.MouseEnter:Connect(function()
			local Position = EditorWidget:GetRelativeMousePosition()
			ErrorContainer.Visible = true
			ErrorContainer.Position = UDim2.fromOffset(Position.X + 4, Position.Y)
		end)

		Line.MouseLeave:Connect(function()
			ErrorContainer.Visible = false
		end)

		Line.Fill.MaxVisibleGraphemes = #Substring
		Line.Parent = ErrorSelection

		break
	end
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
	local GetTextBoundsParams = Instance.new("GetTextBoundsParams")
	GetTextBoundsParams.Text = Line
	GetTextBoundsParams.Size = TextSize
	GetTextBoundsParams.Font = Display.FontFace

	local TextBounds = TextService:GetTextBoundsAsync(GetTextBoundsParams)

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

		if PreviousCursorPosition ~= nil then
			local InputText = Input.Text
			local CurrentLine = GetLineAtPosition(InputText, CursorPosition)
			local PriorLine = GetLineAtPosition(InputText, PreviousCursorPosition)

			if math.abs(CurrentLine - PriorLine) == 1 and math.abs(CursorPosition - PreviousCursorPosition) > 1 then
				NavigationPending = {
					Direction = CurrentLine > PriorLine and 1 or -1,
					Position = PreviousCursorPosition,
				}
			end
		end
	end

	PreviousCursorPosition = CursorPosition
	Profiler.profileEnd()
end

local function OnSelectionChanged()
	--> Clear previous selection
	ClearChildrenWhichAre(Selection, "Frame")

	--> Nothing is selected
	local CursorPosition = Input.CursorPosition
	local SelectionStart = Input.SelectionStart
	if CursorPosition == -1 or SelectionStart == -1 then
		return
	end

	local Start = math.min(CursorPosition, SelectionStart)
	local Finish = math.max(CursorPosition, SelectionStart)

	local Text = string.sub(Input.ContentText, 1, Finish - 1)
	local Slices = string.split(Text, "\n")

	local Offset = 0
	for Index, Slice in Slices do
		local First = Offset
		Offset += (#Slice + 1)

		--> Same as the diagnostics above: only the selected lines need a frame now.
		if Offset < Start then
			continue
		end

		local Line = SelectionTemplate:Clone()
		Line.Size = UDim2.new(1, 0, 0, TextHeight)
		Line.Position = UDim2.fromOffset(0, TextHeight * (Index - 1))
		local Fill = Line.Fill

		--> Calculate selection bounds
		local Substring = Slice
		if First < Start then
			Substring = string.sub(Slice, (Start - First), #Slice)
		elseif Index == #Slices then
			Substring = string.sub(Slice, 1, math.max(1, Finish - First))
		end

		--> Empty lines should appear as one space thick selections
		if Substring == "" then
			Substring = " "
		end

		local SelectionBoundsParams = Instance.new("GetTextBoundsParams")
		SelectionBoundsParams.Text = Substring
		SelectionBoundsParams.Size = TextSize
		SelectionBoundsParams.Font = Display.FontFace

		local SelectionBounds = TextService:GetTextBoundsAsync(SelectionBoundsParams)
		Fill.Size = UDim2.new(0, SelectionBounds.X, 1, 0)

		--> Calculate selection offset
		if Start > First then
			local Prefix = string.sub(Slice, 1, (Start - First) - 1)
			if Prefix ~= "" then
				local OffsetBoundsParams = Instance.new("GetTextBoundsParams")
				OffsetBoundsParams.Text = Prefix
				OffsetBoundsParams.Size = TextSize
				OffsetBoundsParams.Font = Display.FontFace

				local OffsetBounds = TextService:GetTextBoundsAsync(OffsetBoundsParams)
				Fill.Position = UDim2.new(0, OffsetBounds.X, 0, 0)
			end
		end

		Line.Parent = Selection
	end
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
		local CursorIndex = (Input.CursorPosition - 1)
		local Character = string.sub(Text, CursorIndex, CursorIndex)

		if Item and Character == "\t" then
			local Insert = Item.Insert
			local Offset = (#Insert + 1)

			local Start, End = string.find(Insert, "%s", 1, true)
			if Start and End then
				Offset = Start
				Insert = string.sub(Insert, 1, Start - 1) .. string.sub(Insert, End + 1)
			end

			--> Move cursor behind tab character
			CursorIndex -= 1

			local Line = Utility.GetLineRangeAtPosition(Text, CursorIndex)
			local Position = (CursorIndex - Line.Start + 1)

			local Word = Utility.GetWordRangeAtPosition(Line.Text, Position)
			local Length = #Word.Text

			CursorIndex -= Length

			--> Match characters before replacement and after tab (2)
			Text = (string.sub(Text, 1, CursorIndex) .. Insert .. string.sub(Text, CursorIndex + Length + 2))

			PreviousText = Text
			Input.Text = Text

			Input.CursorPosition = -1
			Input.CursorPosition = (CursorIndex + Offset)

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
	if #Slices ~= Lines then
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

--> Create lines in the background
local function GenerateLinesAsync()
	local Tick = os.clock()
	for Index = 1, PRE_ALLOCATED_LINES do
		local Elapsed = (os.clock() - Tick)
		if Elapsed > (1 / 120) then
			task.wait()
			Tick = os.clock()
		end

		GetLine(Index)
	end
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
	task.spawn(GenerateLinesAsync)

	--> Preload fira sans
	ContentProvider:PreloadAsync({ Display }, function(AssetId: string, AssetFetchStatus: Enum.AssetFetchStatus)
		if AssetId ~= "" and AssetFetchStatus ~= Enum.AssetFetchStatus.Success then
			warn("[BLINK] There was an issue preloading the editors font.")
		end
	end)

	--> Remove templates
	Selection.Line:Destroy()
	ErrorSelection.Line:Destroy()
	LinesContainer.Line:Destroy()
	CompletionContainer.Option:Destroy()

	--> The overlays position their frames by line number now, which a UIListLayout would override.
	-->
	--> Destroyed here rather than deleted from Widget.rbxmx so that re-exporting the widget from
	--> Studio, which is how it is maintained, cannot quietly bring the old behaviour back. What it
	--> cost while it was in charge: the only way to place a frame on line N was to stack N frames, so
	--> a diagnostic on line 800 rebuilt 800 instances on every keystroke -- 39ms, measured.
	for _, Overlay in { Selection, ErrorSelection } do
		local Layout = Overlay:FindFirstChildOfClass("UIListLayout")
		if Layout then
			Layout:Destroy()
		end
	end

	--> Sort auto complete symbols
	for _, Symbols in SYMBOLS do
		table.sort(Symbols, function(a, b)
			return #a.Label < #b.Label
		end)
	end

	--> Connections
	Error.OnEmit = OnErrorEmitted

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

---- Connections ----

return Editor
