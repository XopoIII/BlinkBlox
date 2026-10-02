--!nocheck
--- QuickNet v0.3.5-beta definitions as a game writes them, for test/ConvertStubs.luau: every kind
--- of table the library takes, rate limits set and lifted, an unreliable event, functions, and the
--- types with no equivalent. Read by the converter, never run as a module.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local QuickNet = require(ReplicatedStorage.QuickNet)
local Data = QuickNet.Data

QuickNet:addEnumItems({ Enum.Material.Ice, Enum.Material.Sand })

local function Item()
	return { id = Data.NumberU16, name = Data.String, owner = Data.Player }
end

local Events = {
	Equip = QuickNet:register("Equip", Data.NumberU8, Item()):SetRateLimit(10, 1),
	Contents = QuickNet:register("Contents", { Item() }),
	Clear = QuickNet:register("Clear"),
	Move = QuickNet:register("Move", Data.CFrameF32FX16, Data.Vector3I16, Data.Vector3F16)
		:Unreliable()
		:SetRateLimit(120, 2),
	Flood = QuickNet:register("Flood", Data.NumberU8):SetRateLimit(math.huge, 1),

	Numbers = QuickNet:register(
		"Numbers",
		Data.NumberU4,
		Data.NumberU32,
		Data.NumberI8,
		Data.NumberI16,
		Data.NumberI32
	),
	Floats = QuickNet:register("Floats", Data.NumberF16, Data.NumberF32, Data.NumberF64, Data.Boolean),
	Vectors = QuickNet:register("Vectors", Data.Vector3FX8, Data.Vector3FX16, Data.Vector3F32, Data.Vector2I16),
	Looks = QuickNet:register("Looks", Data.Color3, Data.BrickColor, Data.TweenInfo, Data.ColorSequence),
	Layout = QuickNet:register("Layout", Data.UDim, Data.UDim2, Data.NumberRange),
	Times = QuickNet:register("Times", Data.DateTime32, Data.DateTime64),
	Blob = QuickNet:register("Blob", Data.Buffer, Data.StringLong, Data.Instance, Data.Any),

	Triple = QuickNet:register("Triple", { Data.NumberF32, Data.NumberF32, Data.NumberF32 }),
	Mixed = QuickNet:register("Mixed", { Data.NumberU8, Data.String }),
	Scores = QuickNet:register("Scores", { [Data.String] = Data.NumberU32 }),
	Nested = QuickNet:register("Nested", { { tags = { Data.String }, at = Data.Vector3F32 } }),
	Loose = QuickNet:register("Loose", { Data.Any }),

	Maybe = QuickNet:register("Maybe", Data.optional(Data.NumberF32), Data.optional(Item())),
	State = QuickNet:register("State", Data.literal("Idle", "Chase", "Sleep")),
	Odd = QuickNet:register("Odd", Data.literal("Upgrade", 123, true)),
	Either = QuickNet:register("Either", Data.union(Data.NumberU8, Data.String)),
	Region = QuickNet:register("Region", Data.Region3, Data.Rect, Data.EnumItem, Data.NumberSequence),

	Price = QuickNet:register("Price", Data.NumberU16):Response(Data.NumberU32, Data.Boolean):SetResponseTimeout(5),
	Ping = QuickNet:register("Ping"):Response(),
}

if RunService:IsServer() then
	Events.Equip.OnServerEvent:Connect(function(Player, Slot, Equipped)
		print(Player, Slot, Equipped)
	end)

	Events.Price.OnServerInvoke = function(_Player, Id)
		return Id * 2, true
	end
end

return Events
