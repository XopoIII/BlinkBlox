--!strict
--- The line numbers beside the editor: one label per line, shown for the lines the document has, the
--- one holding the cursor in the active colour.
local Gutter = {}
Gutter.__index = Gutter

export type Colors = { Active: Color3, Inactive: Color3 }

export type Gutter = typeof(setmetatable(
	{} :: {
		Container: Instance,
		Template: TextLabel,
		LineHeight: number,
		Colors: Colors,
		--- How many lines are shown.
		Count: number,
		Highlighted: TextLabel?,
	},
	Gutter
))

function Gutter.new(Container: Instance, Template: TextLabel, LineHeight: number, Colors: Colors): Gutter
	return setmetatable({
		Container = Container,
		Template = Template,
		LineHeight = LineHeight,
		Colors = Colors,
		Count = 0,
		Highlighted = nil,
	}, Gutter)
end

--- The label for a line, created if the pre-allocated run does not reach that far.
---
--- PRE_ALLOCATED_LINES labels are built at startup, and this used to index them directly. A document
--- longer than that found no child and threw -- "2001 is not a valid member of Frame" -- which took
--- the whole editor down rather than degrading. It was reachable just by typing or by opening a
--- long file.
function Gutter.Get(self: Gutter, Index: number): TextLabel
	local Existing = self.Container:FindFirstChild(tostring(Index))
	if Existing then
		return Existing :: TextLabel
	end

	local Line = self.Template:Clone()
	Line.Name = tostring(Index)
	Line.Text = tostring(Index)
	Line.TextColor3 = self.Colors.Inactive
	Line.TextTransparency = 1
	Line.Position = UDim2.fromOffset(0, self.LineHeight * (Index - 1))
	Line.Parent = self.Container
	return Line
end

--- Marks `Line` as the one holding the cursor.
function Gutter.Highlight(self: Gutter, Line: number)
	local Label = self:Get(math.max(Line, 1))
	if self.Highlighted then
		self.Highlighted.TextColor3 = self.Colors.Inactive
	end

	self.Highlighted = Label
	Label.TextColor3 = self.Colors.Active
end

--- Shows labels for `Count` lines, hiding any past it.
function Gutter.Resize(self: Gutter, Count: number)
	if Count > self.Count then
		for Index = (self.Count + 1), Count do
			self:Get(Index).TextTransparency = 0
		end
	elseif Count < self.Count then
		for Index = self.Count, (Count + 1), -1 do
			self:Get(Index).TextTransparency = 1
		end
	end

	self.Count = Count
end

--- Builds the first `Count` labels in the background, a slice per frame.
function Gutter.PreallocateAsync(self: Gutter, Count: number)
	local Tick = os.clock()
	for Index = 1, Count do
		local Elapsed = (os.clock() - Tick)
		if Elapsed > (1 / 120) then
			task.wait()
			Tick = os.clock()
		end

		self:Get(Index)
	end
end

return Gutter
