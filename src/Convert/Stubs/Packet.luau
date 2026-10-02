--!strict
--- A stand-in for Packet that records what a game defines with it.
---
--- A game calls the module -- `Packet("Hit", Packet.Instance, Packet.NumberU8)` -- and keeps what it
--- returns. Handed this instead, the same code runs and each packet lands in a Draft. Written against
--- Packet 1.7.0's `init.luau` and `Types/init.luau`: the names below are that library's public
--- names, and none of its code is here.
---
--- Packet's types are strings, `Packet.NumberU8` being `"NumberU8"`, and a table of them is an array
--- when it holds one and a struct otherwise. This reads the same values the same way.
local Draft = require("../Draft")
local Shapes = require("../Shapes")

type Type = Draft.Type
type Declaration = Draft.Declaration

local Packet = {}

--- The version of Packet whose definitions this records.
Packet.VERSION = "1.7.0"
Packet.NAME = "Packet"

--- Packet's types that a schema has under another name. `String` and `Buffer` carry a one-byte
--- length, which is a bound the draft can keep; the `Long` ones carry two, a schema's own limit.
local TYPES: { [string]: Type } = {
	Any = Draft.Primitive("unknown"),
	NumberS8 = Draft.Primitive("i8"),
	NumberS16 = Draft.Primitive("i16"),
	NumberS24 = Draft.Primitive("i24"),
	NumberS32 = Draft.Primitive("i32"),
	NumberU8 = Draft.Primitive("u8"),
	NumberU16 = Draft.Primitive("u16"),
	NumberU24 = Draft.Primitive("u24"),
	NumberU32 = Draft.Primitive("u32"),
	NumberF16 = Draft.Primitive("f16"),
	NumberF24 = Draft.Primitive("f24"),
	NumberF32 = Draft.Primitive("f32"),
	NumberF64 = Draft.Primitive("f64"),
	String = Draft.Primitive("string", { Max = "255" }),
	StringLong = Draft.Primitive("string"),
	Buffer = Draft.Primitive("buffer", { Max = "255" }),
	BufferLong = Draft.Primitive("buffer"),
	Instance = Draft.Primitive("Instance"),
	Boolean8 = Draft.Primitive("boolean"),
	NumberRange = Draft.Primitive("NumberRange"),
	BrickColor = Draft.Primitive("BrickColor"),
	Color3 = Draft.Primitive("Color3"),
	UDim = Draft.Primitive("UDim"),
	UDim2 = Draft.Primitive("UDim2"),
	ColorSequence = Draft.Primitive("ColorSequence"),
	Vector2S16 = Draft.Primitive("Vector2"),
	Vector2F24 = Draft.Primitive("Vector2"),
	Vector2F32 = Draft.Primitive("Vector2"),
	Vector3S16 = Draft.Primitive("vector<i16>"),
	Vector3F24 = Draft.Primitive("vector<f24>"),
	Vector3F32 = Draft.Primitive("vector"),
	CFrameF24U8 = Draft.Primitive("CFrame"),
	CFrameF32U8 = Draft.Primitive("CFrame"),
	CFrameF32U16 = Draft.Primitive("CFrame"),
	--> Packet's packed bytes, as the tables they are read into.
	NumberU4 = Draft.Array(Draft.Primitive("u8", { Max = "15" }), { Min = "2", Max = "2" }),
	Boolean1 = Draft.Array(Draft.Primitive("boolean"), { Min = "8", Max = "8" }),
	BooleanNumber = Draft.Struct({
		{ Name = "Boolean", Type = Draft.Primitive("boolean") },
		{ Name = "Number", Type = Draft.Primitive("u8", { Max = "127" }) },
	}),
}

--- Types with no equivalent, and why.
local MISSING: { [string]: string } = {
	Nil = "a value that is always nil",
	Rect = "a Rect",
	Region3 = "a Region3",
	NumberSequence = "a NumberSequence",
	EnumItem = "an EnumItem of any of the enums the game listed; a schema names one enum, as Enum(Material)",
	Characters = "a string of the characters the game listed",
	Static1 = "one of the values the game listed in Static1",
	Static2 = "one of the values the game listed in Static2",
	Static3 = "one of the values the game listed in Static3",
}

--- A signal that is never fired: a definitions file that connects to it still loads.
local function Signal(): { [string]: any }
	local function Connection()
		return { Disconnect = function() end }
	end

	return {
		Connect = Connection,
		Once = Connection,
		Fire = function() end,
		Wait = function()
			error("A packet was waited on while its definitions were being read: nothing arrives here", 0)
		end,
	}
end

--- The module to hand the definitions, and the function that returns what they defined.
function Packet.new(): ({ [string]: any }, () -> Draft.Draft)
	local Into = Draft.new(Packet.NAME, Packet.VERSION)
	local Packets: { [string]: any } = {}
	local Read: (Value: any, Subject: string) -> Type

	local function Note(Severity: "Lossy" | "Dropped", Subject: string, Message: string)
		table.insert(Into.Notes, { Severity = Severity, Subject = Subject, Message = Message })
	end

	--- A table of types: an array when it holds one, a struct of its keys otherwise.
	local function Table(Value: { [any]: any }, Subject: string): Type
		local Keys: { any } = {}
		for Key in Value do
			table.insert(Keys, Key)
		end

		if #Value == 1 and #Keys == 1 then
			return Draft.Array(Read(Value[1], Subject))
		end

		local Fields: { Draft.Field } = {}
		for _, Key in Keys do
			if type(Key) ~= "string" then
				Note("Dropped", Subject, "a table of several types with no names has no equivalent and became unknown")
				return Draft.Unmapped("a table of types keyed by position")
			end
		end

		table.sort(Keys)
		for _, Key in Keys do
			table.insert(Fields, { Name = Draft.Identifier(Key), Type = Read(Value[Key], Subject) })
		end
		return Draft.Struct(Fields)
	end

	function Read(Value: any, Subject: string): Type
		if type(Value) == "table" then
			return Table(Value, Subject)
		elseif type(Value) ~= "string" then
			error(`Packet "{Subject}" was given a {typeof(Value)} where it takes one of Packet's types`, 0)
		elseif TYPES[Value] then
			return table.clone(TYPES[Value])
		elseif MISSING[Value] then
			Note("Dropped", Subject, `Packet.{Value} is {MISSING[Value]}: it has no equivalent and became unknown`)
			return Draft.Unmapped(`Packet.{Value}`)
		end

		return error(`Packet.{Value} is not known to the converter, which was written for Packet {Packet.VERSION}`, 0)
	end

	--- The values a packet carries: none, one, or several in order.
	local function Values(Subject: string, ...: any): Type?
		local Fields: { Draft.Field } = {}
		for Index = 1, select("#", ...) do
			table.insert(Fields, { Type = Read((select(Index, ...)), Subject) })
		end

		if #Fields == 0 then
			return nil
		end
		return if #Fields == 1 then Fields[1].Type else Draft.Tuple(Fields)
	end

	local function Constructor(_, Name: any, ...: any): any
		local Subject = tostring(Name)
		if Packets[Subject] then
			return Packets[Subject]
		end

		local Declaration: Declaration = {
			Kind = "Event",
			Name = Draft.Identifier(Subject),
			--> Packet has one channel, a RemoteEvent, and fires each listener of a signal.
			Reliability = "Reliable",
			Call = "ManyAsync",
			Data = Values(Subject, ...),
		}
		if Declaration.Name ~= Subject then
			Note("Lossy", Subject, `"{Subject}" is not a name a schema can spell and became {Declaration.Name}`)
		end
		table.insert(Into.Body, Declaration)

		local Object: { [string]: any } = {
			Type = "Packet",
			Name = Subject,
			OnServerEvent = Signal(),
			OnClientEvent = Signal(),
			Fire = function() end,
			FireClient = function() end,
		}

		--- A packet with a response is a call that is answered: a function.
		function Object.Response(Self: any, ...: any)
			Declaration.Kind = "Function"
			Declaration.Reliability = nil
			Declaration.Call = nil
			Declaration.Yield = "Coroutine"
			Declaration.Return = Values(Subject, ...)
			return Self
		end

		Packets[Subject] = Object
		return Object
	end

	local Module: { [string]: any } = {}
	for Name in TYPES do
		Module[Name] = Name
	end
	for Name in MISSING do
		Module[Name] = Name
	end

	setmetatable(Module, {
		__call = Constructor,
		__index = function(_, Name: any)
			error(`Packet.{Name} is not known to the converter, which was written for Packet {Packet.VERSION}`, 0)
		end,
	})

	return Module :: any, function()
		Shapes.Name(Into)
		return Into
	end
end

return Packet
