--!strict
--- The diagnostic shown in the editor: the text of its message, and the key that says whether a new
--- one would draw anything different from the one already drawn.
local Error = require("@compiler/Modules/Error")
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

return Diagnostics
