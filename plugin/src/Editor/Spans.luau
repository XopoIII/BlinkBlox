--!strict
--- Drawing a span of the source as highlighted frames, one per line it covers: the selection, and
--- the underline of a diagnostic. The two used to be separate copies of the same loop.
---
--- Each line's frame is placed by its line number and its fill is sized by measuring the text before
--- and inside the span, since the editor's font is not monospace.
local TextService = game:GetService("TextService")

local Spans = {}

--- How much room `Text` takes in the editor's font.
function Spans.Measure(Text: string, TextSize: number, Font: Font): Vector2
	local Params = Instance.new("GetTextBoundsParams")
	Params.Text = Text
	Params.Size = TextSize
	Params.Font = Font

	return TextService:GetTextBoundsAsync(Params)
end

export type Options = {
	--- Cloned per line. Its `Fill` child is the highlighted part.
	Template: Frame & { Fill: GuiObject },
	Parent: Instance,
	--- The source up to the end of the span.
	Text: string,
	Start: number,
	Finish: number,
	LineHeight: number,
	TextSize: number,
	Font: Font,
	--- Vertical offset of the fill inside its line, for an underline drawn below the text.
	FillOffset: number,
	--- Stop after the first line, for a diagnostic that marks where it begins.
	FirstLineOnly: boolean,
	--- Called with each line's frame and the text it covers, before it is parented.
	Decorate: ((Line: Frame & { Fill: GuiObject }, Covered: string) -> ())?,
}

function Spans.Draw(Options: Options)
	local Start, Finish = Options.Start, Options.Finish
	local Slices = string.split(Options.Text, "\n")

	local Offset = 0
	for Index, Slice in Slices do
		local First = Offset
		Offset += (#Slice + 1)

		--> Only the lines the span covers get a frame. Every line above it used to get a zero-width
		--> one of its own, because a UIListLayout was doing the vertical positioning and needed
		--> something to stack: an error on line 800 cost 800 clones per keystroke, 39ms, measured in
		--> Studio. Positioning by line makes it one frame wherever the span is.
		if Offset < Start then
			continue
		end

		local Line = Options.Template:Clone()
		Line.Size = UDim2.new(1, 0, 0, Options.LineHeight)
		Line.Position = UDim2.fromOffset(0, Options.LineHeight * (Index - 1))
		local Fill = Line.Fill

		--> Calculate selection bounds
		local Covered = Slice
		if First < Start then
			Covered = string.sub(Slice, (Start - First), #Slice)
		elseif Index == #Slices then
			Covered = string.sub(Slice, 1, math.max(1, Finish - First))
		end

		--> Empty lines should appear as one space thick selections
		if Covered == "" then
			Covered = " "
		end

		local Bounds = Spans.Measure(Covered, Options.TextSize, Options.Font)
		Fill.Size = UDim2.new(0, Bounds.X, 1, 0)

		--> Calculate selection offset
		if Start > First then
			local Prefix = string.sub(Slice, 1, (Start - First) - 1)
			if Prefix ~= "" then
				local PrefixBounds = Spans.Measure(Prefix, Options.TextSize, Options.Font)
				Fill.Position = UDim2.new(0, PrefixBounds.X, 0, Options.FillOffset)
			end
		end

		if Options.Decorate then
			Options.Decorate(Line, Covered)
		end

		Line.Parent = Options.Parent

		if Options.FirstLineOnly then
			break
		end
	end
end

--- Readies the overlays a span is drawn into.
---
--- Spans position their frames by line number, which a UIListLayout would override. It is destroyed
--- here rather than deleted from Widget.rbxmx so that re-exporting the widget from Studio, which is
--- how it is maintained, cannot quietly bring the old behaviour back. What it cost while it was in
--- charge: the only way to place a frame on line N was to stack N frames, so a diagnostic on line
--- 800 rebuilt 800 instances on every keystroke -- 39ms, measured.
function Spans.Prepare(Overlays: { Instance })
	for _, Overlay in Overlays do
		local Layout = Overlay:FindFirstChildOfClass("UIListLayout")
		if Layout then
			Layout:Destroy()
		end
	end
end

return Spans
