--!strict
--- The completion popup: the items listed under the cursor, the selected one highlighted.
local Completion = require("./Completion")
local Instances = require("../Instances")

export type Layout = {
	--- The popup, and the row cloned per item (with `Icon` and `Text` children).
	Container: Frame,
	Template: Frame,
	--- The cursor's absolute position, the editor's absolute size, and the height of a line.
	Anchor: Vector2,
	Area: Vector2,
	LineHeight: number,
	Highlight: Color3,
}

local Popup = {}

--- Shows `Items` with `Selected` highlighted, one line below the cursor and clamped inside the editor;
--- hides the popup when there is nothing to offer.
function Popup.Render(Layout: Layout, Items: { Completion.Item }, Selected: number)
	local Container = Layout.Container
	if #Items == 0 then
		Container.Visible = false
		return
	end

	local HorizontalWidth = math.max(0, (Layout.Area.X - Container.Size.X.Offset) - 10)
	Container.Position =
		UDim2.fromOffset(math.clamp(Layout.Anchor.X, 0, HorizontalWidth), Layout.Anchor.Y + Layout.LineHeight)

	Container.Visible = true
	Instances.ClearChildrenWhichAre(Container, "Frame")

	for Index, Item in Items do
		local Frame = Layout.Template:Clone() :: any
		Frame.Icon.Image = Item.Icon
		Frame.Text.Text = Item.Label

		if Index == Selected then
			Frame.BackgroundColor3 = Layout.Highlight
		end

		Frame.Parent = Container
	end
end

return Popup
