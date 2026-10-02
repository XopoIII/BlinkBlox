--!nocheck
--- ByteNet 0.4.3 definitions as a game writes them, for test/ConvertStubs.luau: every type the
--- library has, two namespaces, a module of the game's own required beside it, one that is not
--- there, and a listener connected in the same file. Read by the converter, never run as a module.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Analytics = require(ReplicatedStorage.Shared.Analytics)
local ByteNet = require(ReplicatedStorage.Packages.ByteNet)
local Constants = require(script.Parent.Constants)

local function Item()
	return ByteNet.struct({
		id = ByteNet.uint16,
		name = ByteNet.string,
		tint = ByteNet.optional(ByteNet.vec3),
	})
end

local Inventory = ByteNet.defineNamespace("Inventory", function()
	return {
		Equip = ByteNet.definePacket({ value = ByteNet.struct({ slot = ByteNet.uint8, item = Item() }) }),
		Contents = ByteNet.definePacket({ value = ByteNet.array(Item()) }),
		Clear = ByteNet.definePacket({ value = ByteNet.nothing }),
	}
end)

local World = ByteNet.defineNamespace(Constants.WorldNamespace, function()
	return {
		Move = ByteNet.definePacket({
			value = ByteNet.struct({
				at = ByteNet.cframe,
				aim = ByteNet.vec2,
				speed = ByteNet.float32,
				height = ByteNet.float64,
				frame = ByteNet.int32,
				lean = ByteNet.int8,
				turn = ByteNet.int16,
				seed = ByteNet.uint32,
				grounded = ByteNet.bool,
			}),
			reliabilityType = "unreliable",
		}),
		Chunk = ByteNet.definePacket({ value = ByteNet.buff }),
		Scores = ByteNet.definePacket({ value = ByteNet.map(ByteNet.string, ByteNet.uint32) }),
		Pick = ByteNet.definePacket({ value = ByteNet.inst }),
		Anything = ByteNet.definePacket({ value = ByteNet.unknown }),
	}
end)

if RunService:IsServer() then
	Inventory.Equip.listen(function(Data, Player)
		Analytics.Record(Player, Data.slot)
	end)
end

return { Inventory = Inventory, World = World }
