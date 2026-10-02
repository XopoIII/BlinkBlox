--!strict
--- A stand-in for ByteNet that records what a game defines with it.
---
--- A game's definitions file requires ByteNet and calls it: `defineNamespace`, `definePacket`,
--- `struct`, `uint8`. Handed this instead, the same file runs and every packet it defines lands in a
--- Draft; nothing is sent and no remote is made. Written against ByteNet 0.4.3's `src/init.luau` and
--- `src/types.luau`: the names below are that library's public names, and none of its code is here.
---
--- ByteNet says less than a schema needs. A packet has no direction -- either side may `send` it --
--- so every event comes out with its direction left for the reader to state.
local Draft = require("../Draft")
local Shapes = require("../Shapes")

type Declaration = Draft.Declaration

--- A packet as `definePacket` left it, waiting for the namespace that names it.
type Pending = { Data: Draft.Type?, Reliability: "Reliable" | "Unreliable" }

local ByteNet = {}

--- The version of ByteNet whose definitions this records.
ByteNet.VERSION = "0.4.3"
ByteNet.NAME = "ByteNet"

--- ByteNet's types that are a value, and what a schema calls each.
local VALUES: { [string]: string } = {
	bool = "boolean",
	uint8 = "u8",
	uint16 = "u16",
	uint32 = "u32",
	int8 = "i8",
	int16 = "i16",
	int32 = "i32",
	float32 = "f32",
	float64 = "f64",
	cframe = "CFrame",
	string = "string",
	vec2 = "Vector2",
	vec3 = "vector",
	buff = "buffer",
	inst = "Instance",
	unknown = "unknown",
}

--- A packet's methods, which do nothing: a definitions file that also listens or sends still loads.
local SENDS = { "send", "sendTo", "sendToAll", "sendToAllExcept", "sendToList", "listen" }

--- The module to hand the definitions, and the function that returns what they defined.
function ByteNet.new(): ({ [string]: any }, () -> Draft.Draft)
	local Into = Draft.new(ByteNet.NAME, ByteNet.VERSION)
	local Pending: { [any]: Pending } = {}
	--> `nothing` is a packet with no data, which is not a type: it is told apart by identity.
	local Nothing = Shapes.Token(Draft.Primitive("unknown"))

	local Module: { [string]: any } = { nothing = Nothing }
	for Name, Primitive in VALUES do
		Module[Name] = Shapes.Token(Draft.Primitive(Primitive))
	end

	function Module.struct(Format: any)
		return Shapes.Token(Shapes.Struct(Format, "A struct"))
	end

	function Module.array(Value: any)
		return Shapes.Token(Draft.Array(Shapes.Expect(Value, "An array's value")))
	end

	function Module.optional(Value: any)
		return Shapes.Token(Draft.Optional(Shapes.Expect(Value, "An optional's value")))
	end

	function Module.map(Key: any, Value: any)
		return Shapes.Token(Draft.Map(Shapes.Expect(Key, "A map's key"), Shapes.Expect(Value, "A map's value")))
	end

	function Module.definePacket(Props: any)
		if type(Props) ~= "table" then
			error("definePacket takes a table with a value", 0)
		end

		local Packet: { [string]: any } = {}
		for _, Name in SENDS do
			Packet[Name] = function() end
		end
		Packet.wait = function()
			error("A packet was waited on while its definitions were being read: nothing arrives here", 0)
		end
		Packet.getListeners = function()
			return {}
		end

		Pending[Packet] = {
			Data = if Props.value == Nothing then nil else Shapes.Expect(Props.value, "A packet's value"),
			Reliability = if Props.reliabilityType == "unreliable" then "Unreliable" else "Reliable",
		}
		return Packet
	end

	function Module.defineNamespace(Name: any, Input: any)
		local Packets = Input()
		local Names: { string } = {}
		for Key in Packets do
			table.insert(Names, tostring(Key))
		end
		table.sort(Names)

		local Body: { Declaration } = {}
		for _, Key in Names do
			local Packet = Pending[Packets[Key]]
			if not Packet then
				error(`{Name}.{Key} is not a packet made by definePacket`, 0)
			end

			table.insert(Body, {
				Kind = "Event",
				Name = Draft.Identifier(Key),
				--> Each listener ByteNet calls may yield, and a packet may have many.
				Call = "ManyAsync",
				Reliability = Packet.Reliability,
				Data = Packet.Data,
			})
		end

		table.insert(Into.Body, { Kind = "Scope", Name = Draft.Identifier(tostring(Name)), Body = Body })
		return Packets
	end

	--> A name this does not know is one a later ByteNet added, or a typo: either way the draft would
	--> be missing something, so it is said instead of answered with nil.
	setmetatable(Module, {
		__index = function(_, Name: any)
			error(`ByteNet.{Name} is not known to the converter, which was written for ByteNet {ByteNet.VERSION}`, 0)
		end,
	})

	return Module :: any, function()
		Shapes.Name(Into)
		return Into
	end
end

return ByteNet
