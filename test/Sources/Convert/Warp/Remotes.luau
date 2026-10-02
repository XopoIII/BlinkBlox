--!nocheck
--- Warp 1.1.0-pre7 definitions as a game writes them, for test/ConvertStubs.luau: schemas given
--- from a table, every type the library has, a custom datatype, names registered with no schema,
--- and a listener connected in the same file. Read by the converter, never run as a module.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Warp = require(ReplicatedStorage.Warp)

local Side = if RunService:IsServer() then Warp.Server() else Warp.Client()
local Schema = Side.Schema

Schema.custom_datatype("u64", {}, function() end, function() end)

local function Item()
	return Schema.struct({
		id = Schema.u16,
		name = Schema.string,
		tint = Schema.optional(Schema.color3),
	})
end

local SCHEMAS = {
	Equip = Schema.struct({ slot = Schema.u8, item = Item() }),
	Contents = Schema.array(Item()),
	Move = Schema.struct({
		at = Schema.cframe,
		velocity = Schema.vector3,
		cell = Schema.vector3int16,
		aim = Schema.vector2,
		grid = Schema.vector2int16,
	}),
	Numbers = Schema.struct({
		a = Schema.i8,
		b = Schema.i16,
		c = Schema.i32,
		d = Schema.u32,
		e = Schema.f16,
		f = Schema.f32,
		g = Schema.f64,
		h = Schema.boolean,
	}),
	Looks = Schema.struct({
		tint = Schema.color3f16,
		team = Schema.brickcolor,
		fade = Schema.colorsequence,
		open = Schema.tweeninfo,
		span = Schema.numberrange,
		size = Schema.udim2,
		pad = Schema.udim,
		joined = Schema.datetime,
	}),
	Chunk = Schema.buffer,
	Pick = Schema.instance,
	Scores = Schema.map(Schema.string, Schema.u32),
	Region = Schema.struct({ area = Schema.rect, aim = Schema.ray, curve = Schema.numbersequence }),
	Surface = Schema.struct({ material = Schema.physicalproperties, face = Schema.font, big = Schema.u64 }),
}

Side.reg_namespaces({ "Equip", "Notify", "Ping" })

for Name, Definition in SCHEMAS do
	Side.useSchema(Name, Definition)
end

if RunService:IsServer() then
	Side.Connect("Equip", function(Player, Data)
		print(Player, Data.slot)
	end)

	Side.Connect("Chat", function(Player, Message)
		print(Player, Message)
	end)
end

return Side
