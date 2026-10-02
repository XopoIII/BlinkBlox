--!nocheck
--- Packet 1.7.0 definitions as a game writes them, for test/ConvertStubs.luau: every kind of type
--- the library has, packets with a response, a name that is not an identifier, and a listener
--- connected in the same file. Read by the converter, never run as a module.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packet = require(ReplicatedStorage.Packet)

local Item = { Id = Packet.NumberU16, Name = Packet.String, Tint = Packet.Color3 }

local Packets = {
	Equip = Packet("Equip", Packet.NumberU8, Item),
	Contents = Packet("Contents", { Item }),
	Clear = Packet("Clear"),
	Chat = Packet("Player Chat", Packet.StringLong),

	Move = Packet("Move", Packet.CFrameF24U8, Packet.Vector3S16, Packet.Vector3F24, Packet.Vector3F32),
	Look = Packet("Look", Packet.Vector2S16, Packet.NumberF16, Packet.NumberF24, Packet.NumberF64),
	Counts = Packet("Counts", Packet.NumberS8, Packet.NumberS16, Packet.NumberS24, Packet.NumberS32),
	Sizes = Packet("Sizes", Packet.NumberU24, Packet.NumberU32, Packet.NumberF32, Packet.Boolean8),
	Packed = Packet("Packed", Packet.NumberU4, Packet.Boolean1, Packet.BooleanNumber),
	Layout = Packet("Layout", Packet.UDim, Packet.UDim2, Packet.NumberRange, Packet.BrickColor, Packet.ColorSequence),
	Chunk = Packet("Chunk", Packet.Buffer, Packet.BufferLong),
	Pick = Packet("Pick", Packet.Instance, Packet.Any),

	Region = Packet("Region", Packet.Region3, Packet.Rect),
	Material = Packet("Material", Packet.EnumItem, Packet.Static1),
	Pair = Packet("Pair", { Packet.NumberU8, Packet.NumberU8 }),

	Price = Packet("Price", Packet.NumberU16):Response(Packet.NumberU32, Packet.Boolean8),
	Ping = Packet("Ping"):Response(),
}

Packets.Price.ResponseTimeout = 5

if RunService:IsServer() then
	Packets.Equip.OnServerEvent:Connect(function(Player, Slot, Equipped)
		print(Player, Slot, Equipped)
	end)

	Packets.Price.OnServerInvoke = function(_Player, Id)
		return Id * 2, true
	end
end

return Packets
