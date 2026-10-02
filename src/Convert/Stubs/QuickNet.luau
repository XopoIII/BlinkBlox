--!strict
--- A stand-in for QuickNet that records what a game defines with it.
---
--- A game calls `QuickNet:register("Hit", Data.Instance, Data.NumberU8)` and chains what the event
--- is onto the result: `:Unreliable()`, `:SetRateLimit(20, 1)`, `:Response(Data.Boolean)`. Handed
--- this instead, the same code runs and each event lands in a Draft. Written against QuickNet
--- v0.3.5-beta (commit f7cfdf5): `src/QuickNet.luau`, `src/QuickNet/DataTypes.luau` and
--- `docs/types.md`. The names below are that library's public names, and none of its code is here.
---
--- QuickNet is the one library here that limits how often a client may fire, sixty times a second
--- unless an event says otherwise, so its drafts carry a `Rate` where the others ask for one.
local Draft = require("../Draft")
local Inbound = require("../Inbound")
local Shapes = require("../Shapes")

type Type = Draft.Type
type Declaration = Draft.Declaration

local QuickNet = {}

--- The version of QuickNet whose definitions this records.
QuickNet.VERSION = "0.3.5-beta"
QuickNet.NAME = "QuickNet"

--- `Config.DefaultRateLimit`: what an event is held to when it sets none.
local DEFAULT_RATE = "60"

--- `QuickNet.Data`'s types that a schema has, under its own names. A fixed-point type becomes the
--- plain one: a schema chooses its encoding itself.
local TYPES: { [string]: Type } = {
	NumberU4 = Draft.Primitive("u8", { Max = "15" }),
	NumberU8 = Draft.Primitive("u8"),
	NumberU16 = Draft.Primitive("u16"),
	NumberU32 = Draft.Primitive("u32"),
	NumberI8 = Draft.Primitive("i8"),
	NumberI16 = Draft.Primitive("i16"),
	NumberI32 = Draft.Primitive("i32"),
	NumberF16 = Draft.Primitive("f16"),
	NumberF32 = Draft.Primitive("f32"),
	NumberF64 = Draft.Primitive("f64"),
	CFrameFX8 = Draft.Primitive("CFrame"),
	CFrameI16FX16 = Draft.Primitive("CFrame"),
	CFrameFX16 = Draft.Primitive("CFrame"),
	CFrameF16 = Draft.Primitive("CFrame"),
	CFrameF32Aligned = Draft.Primitive("CFrame"),
	CFrameF32FX16 = Draft.Primitive("CFrame"),
	CFrameF32 = Draft.Primitive("CFrame"),
	Vector3FX8 = Draft.Primitive("vector"),
	Vector3I16 = Draft.Primitive("vector<i16>"),
	Vector3FX16 = Draft.Primitive("vector"),
	Vector3F16 = Draft.Primitive("vector<f16>"),
	Vector3F32 = Draft.Primitive("vector"),
	Vector2FX8 = Draft.Primitive("Vector2"),
	Vector2I16 = Draft.Primitive("Vector2"),
	Vector2FX16 = Draft.Primitive("Vector2"),
	Vector2F16 = Draft.Primitive("Vector2"),
	Vector2F32 = Draft.Primitive("Vector2"),
	String = Draft.Primitive("string", { Max = "255" }),
	StringLong = Draft.Primitive("string"),
	Color3 = Draft.Primitive("Color3"),
	BrickColor = Draft.Primitive("BrickColor"),
	Boolean = Draft.Primitive("boolean"),
	Buffer = Draft.Primitive("buffer"),
	Instance = Draft.Primitive("Instance"),
	Player = Draft.Primitive("Instance(Player)"),
	DateTime32 = Draft.Primitive("DateTime"),
	DateTime64 = Draft.Primitive("DateTimeMillis"),
	TweenInfo = Draft.Primitive("TweenInfo"),
	ColorSequence = Draft.Primitive("ColorSequence"),
	NumberRange = Draft.Primitive("NumberRange"),
	UDim = Draft.Primitive("UDim"),
	UDim2 = Draft.Primitive("UDim2"),
	Any = Draft.Primitive("unknown"),
}

--- Types with no equivalent.
local MISSING = { "Nil", "EnumItem", "NumberSequence", "Region3", "PhysicalProperties", "Rect" }

--- An event's methods, which do nothing: a definitions file that also fires or listens still loads.
local SENDS = { "FireClient", "FireClients", "FireAllClients", "FireAllExcept", "FireServer", "SetResponseTimeout" }

--- A signal that is never fired.
local function Signal(): { [string]: any }
	local function Connection()
		return { Disconnect = function() end }
	end

	return {
		Connect = Connection,
		ConnectAsync = Connection,
		Once = Connection,
		Wait = function()
			error("An event was waited on while its definitions were being read: nothing arrives here", 0)
		end,
	}
end

--- A table in a schema. An array lists its types by position: one is a uniform array of any
--- length, several are a static array of exactly those. A dictionary keyed by a type is a uniform
--- one, a map; keyed by names it is a static one, a struct.
local function Table(Value: { [any]: any }, What: string): Type
	if #Value == 1 then
		return Draft.Array(Shapes.Expect(Value[1], `{What}'s element`))
	elseif #Value > 1 then
		local First = Shapes.Expect(Value[1], `{What}[1]`)
		for Index = 2, #Value do
			if Shapes.Expect(Value[Index], `{What}[{Index}]`) ~= First then
				return Draft.Unmapped("a static array of different types")
			end
		end

		return Draft.Array(First, { Min = tostring(#Value), Max = tostring(#Value) })
	end

	local Key, Only = next(Value)
	local KeyType = Shapes.Read(Key)
	if KeyType and next(Value, Key) == nil then
		return Draft.Map(KeyType, Shapes.Expect(Only, `{What}'s values`))
	end

	local Named: { [string]: any } = {}
	for Name, Field in Value do
		Named[Draft.Identifier(tostring(Name))] = Field
	end
	return Shapes.Struct(Named, What)
end

--- The type a value in a schema stands for: one of `Data`'s, or a table of them.
local function Read(Value: any, What: string): Type
	local Type = Shapes.Read(Value)
	if Type then
		return Type
	elseif type(Value) == "table" then
		--> QuickNet lets a table be written inline anywhere a type goes, so its insides are read
		--> the same way, by wrapping each table in a token first.
		local Tokens: { [any]: any } = {}
		for Key, Inner in Value do
			Tokens[Key] = if Shapes.Read(Inner) or type(Inner) ~= "table"
				then Inner
				else Shapes.Token(Read(Inner, What))
		end
		return Table(Tokens, What)
	end

	return error(`{What} is not one of QuickNet.Data's types, but a {typeof(Value)}`, 0)
end

--- `Data.literal`: values known when the schema is written. Names alone are a unit enum.
local function Literal(...: any): any
	local Values: { string } = {}
	for Index = 1, select("#", ...) do
		local Value = select(Index, ...)
		if type(Value) ~= "string" or not Draft.IsIdentifier(Value) then
			return Shapes.Token(Draft.Unmapped("a literal of values that are not all names"))
		end
		table.insert(Values, Value)
	end

	return Shapes.Token(Draft.Enum(Values))
end

--- The module to hand the definitions, and the function that returns what they defined.
function QuickNet.new(): ({ [string]: any }, () -> Draft.Draft)
	local Into = Draft.new(QuickNet.NAME, QuickNet.VERSION)

	local Data: { [string]: any } = {}
	for Name, Type in TYPES do
		Data[Name] = Shapes.Token(Type)
	end
	for _, Name in MISSING do
		Data[Name] = Shapes.Token(Draft.Unmapped(`QuickNet.Data.{Name}`))
	end

	function Data.optional(Value: any)
		return Shapes.Token(Draft.Optional(Read(Value, "An optional's value")))
	end
	function Data.union()
		return Shapes.Token(Draft.Unmapped("a union"))
	end
	Data.unionMany = Data.union
	Data.literal = Literal

	--- The values an event carries: none, one, or several in order.
	local function Values(Subject: string, ...: any): Type?
		local Fields: { Draft.Field } = {}
		for Index = 1, select("#", ...) do
			local Type = Read((select(Index, ...)), `"{Subject}" value {Index}`)
			for _, Original in Inbound.Unmapped(Type) do
				table.insert(Into.Notes, {
					Severity = "Dropped",
					Subject = Subject,
					Message = `{Original} has no equivalent and became unknown, which is not validated`,
				})
			end
			table.insert(Fields, { Type = Type })
		end

		if #Fields == 0 then
			return nil
		end
		return if #Fields == 1 then Fields[1].Type else Draft.Tuple(Fields)
	end

	local Module: { [string]: any } = { Data = Data }

	function Module.addEnumItems() end

	function Module.register(_, Name: any, ...: any): any
		local Subject = tostring(Name)
		local Declaration: Declaration = {
			Kind = "Event",
			Name = Draft.Identifier(Subject),
			Reliability = "Reliable",
			--> A listener is connected to run in line or on a thread of its own, and there may be many.
			Call = "ManyAsync",
			Rate = DEFAULT_RATE,
			Data = Values(Subject, ...),
		}
		table.insert(Into.Body, Declaration)

		local Object: { [string]: any } = { OnServerEvent = Signal(), OnClientEvent = Signal() }
		for _, Method in SENDS do
			Object[Method] = function()
				return Object
			end
		end

		--- Events a second: `Max` in every `Window` seconds. One lifted to no limit has none to carry.
		function Object.SetRateLimit(_, Max: number, Window: number)
			local Rate = Max / Window
			Declaration.Rate = if Rate == math.huge or Rate ~= Rate then nil else string.format("%g", Rate)
			return Object
		end

		function Object.Unreliable()
			Declaration.Reliability = "Unreliable"
			return Object
		end

		--- An event with a response is a call that is answered: a function, which a client makes.
		function Object.Response(_, ...: any)
			Declaration.Kind = "Function"
			Declaration.From = "Client"
			Declaration.Reliability = nil
			Declaration.Call = nil
			Declaration.Yield = "Coroutine"
			Declaration.Return = Values(Subject, ...)
			return Object
		end

		function Object.InvokeServer()
			error("A function was invoked while its definitions were being read: nothing answers here", 0)
		end

		return Object
	end

	local function Unknown(Where: string)
		return {
			__index = function(_, Name: any)
				error(
					`{Where}.{Name} is not known to the converter, which was written for QuickNet {QuickNet.VERSION}`,
					0
				)
			end,
		}
	end
	setmetatable(Data, Unknown("QuickNet.Data"))
	setmetatable(Module, Unknown("QuickNet"))

	return Module :: any, function()
		Shapes.Name(Into)
		return Into
	end
end

return QuickNet
