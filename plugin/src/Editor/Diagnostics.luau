--!strict
--- The diagnostic shown in the editor: the text of its message, and the key that says whether a new
--- one would draw anything different from the one already drawn.
local Error = require("@compiler/Modules/Error")
local Instances = require("../Instances")
local Spans = require("./Spans")
local Utility = require("./Utility")

local Diagnostics = {}

--- Everything the rendered diagnostic depends on, as one string.
---
--- The point is to answer "would this draw the same thing again?" without drawing it. What the
--- render reads is the diagnostic itself and the source UP TO the end of its span -- that decides
--- which line the underline sits on, how wide it is, and what line numbers the message quotes.
--- Anything typed after the error touches none of it.
function Diagnostics.Key(Diagnostic: Error.Class?, Source: string): string?
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

	table.insert(Parts, string.sub(Source, 1, Primary.Span.End))
	return table.concat(Parts, "|")
end

--- The rich-text message: severity, name and code, then each label with the line it points at.
function Diagnostics.Message(Diagnostic: Error.Class, Source: string, Theme: { Error: Color3, Warning: Color3 }): string
	local IsWarning = (Diagnostic.Severity == "Warning")
	local SeverityColor = IsWarning and Theme.Warning or Theme.Error
	local SeverityLabel = `<font color="#{SeverityColor:ToHex()}">{IsWarning and "Warning" or "Error"}</font>`

	local Message =
		`{SeverityLabel} {Error.GetNameFromCode(Diagnostic.Code)}: {Diagnostic.RawMessage} <font transparency="0.5"><i>BlinkBlox({Diagnostic.Code})</i></font>`
	for _, Label in Diagnostic.Labels do
		local Line = Utility.GetCurrentLine(Source, Label.Span.Start)
		Message ..= `\n{Label.Text} [L{Line}]`
	end

	return Message
end

--- Decorates an underline frame drawn by Spans: the fill clipped to the text it covers and coloured
--- for a warning, and the message shown beside the mouse while it is over the line.
function Diagnostics.Underline(
	Popup: GuiObject,
	Widget: DockWidgetPluginGui,
	WarningColor: Color3?
): (Line: Frame & { Fill: GuiObject }, Covered: string) -> ()
	return function(Line, Covered)
		local Fill = Line.Fill :: TextLabel
		if WarningColor then
			Fill.TextColor3 = WarningColor
		end

		Line.MouseEnter:Connect(function()
			local Position = Widget:GetRelativeMousePosition()
			Popup.Visible = true
			Popup.Position = UDim2.fromOffset(Position.X + 4, Position.Y)
		end)

		Line.MouseLeave:Connect(function()
			Popup.Visible = false
		end)

		Fill.MaxVisibleGraphemes = #Covered
	end
end

export type View = {
	--- The message box, shown while the mouse is over the underline.
	Popup: GuiObject,
	Message: TextLabel,
	--- Holds the underline frames; each is cloned from `Template`.
	Underlines: Instance,
	Template: Frame & { Fill: GuiObject },
	Widget: DockWidgetPluginGui,
	LineHeight: number,
	TextSize: number,
	Font: Font,
	Theme: { Error: Color3, Warning: Color3 },
}

--- Clears what was drawn and draws `Diagnostic`, if any: the message, and an underline where its
--- primary label begins. `Source` is the editor's text, `Content` the same without rich text.
function Diagnostics.Draw(View: View, Diagnostic: Error.Class?, Source: string, Content: string)
	View.Popup.Visible = false
	Instances.ClearChildrenWhichAre(View.Underlines, "Frame")

	local Labels = if Diagnostic then Diagnostic.Labels else {}
	if not Diagnostic or #Labels == 0 then
		return
	end

	local IsWarning = (Diagnostic.Severity == "Warning")
	View.Message.Text = Diagnostics.Message(Diagnostic, Source, View.Theme)

	local Span = Labels[#Labels].Span
	Spans.Draw({
		Template = View.Template,
		Parent = View.Underlines,
		Text = string.sub(Content, 1, Span.End),
		Start = Span.Start,
		Finish = Span.End,
		LineHeight = View.LineHeight,
		TextSize = View.TextSize,
		Font = View.Font,
		FillOffset = 10,
		FirstLineOnly = true,
		Decorate = Diagnostics.Underline(View.Popup, View.Widget, if IsWarning then View.Theme.Warning else nil),
	})
end

return Diagnostics
