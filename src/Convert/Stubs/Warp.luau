--!strict
--- A stand-in for Warp that records what a game defines with it.
---
--- Warp's events are names, and an event gets its types when the game calls
--- `Server.useSchema("Hit", Schema.struct({ .. }))`. Handed this instead, the same code runs and
--- each schema lands in a Draft. Written against Warp 1.1.0-pre7: `src/Util/Buffer/init.luau` and
--- `docs/api/1.1`. The names below are that library's public names, and none of its code is here.
---
--- Warp says the least of the libraries read here. An event has no direction, and whether it is
--- reliable is an argument of each `Fire`, so both are left for the reader. An event the game fires
--- with no schema has no types at all: it is recorded only when the definitions name it.
local Draft = require("../Draft")
local Inbound = require("../Inbound")
local Shapes = require("../Shapes")

type Type = Draft.Type
type Declaration = Draft.Declaration

local Warp = {}

--- The version of Warp whose definitions this records.
Warp.VERSION = "1.1.0-pre7"
Warp.NAME = "Warp"

--- `Schema`'s types that a schema has, under its own names.
local TYPES: { [string]: Type } = {
	u8 = Draft.Primitive("u8"),
	i8 = Draft.Primitive("i8"),
	u16 = Draft.Primitive("u16"),
	i16 = Draft.Primitive("i16"),
	u32 = Draft.Primitive("u32"),
	i32 = Draft.Primitive("i32"),
	f16 = Draft.Primitive("f16"),
	f32 = Draft.Primitive("f32"),
	f64 = Draft.Primitive("f64"),
	boolean = Draft.Primitive("boolean"),
	string = Draft.Primitive("string"),
	buffer = Draft.Primitive("buffer"),
	--> Warp sends a Vector3's components as f16.
	vector3 = Draft.Primitive("vector<f16>"),
	vector3int16 = Draft.Primitive("vector<i16>"),
	vector2 = Draft.Primitive("Vector2"),
	vector2int16 = Draft.Primitive("Vector2"),
	cframe = Draft.Primitive("CFrame"),
	color3 = Draft.Primitive("Color3"),
	color3f16 = Draft.Primitive("Color3"),
	instance = Draft.Primitive("Instance"),
	udim = Draft.Primitive("UDim"),
	udim2 = Draft.Primitive("UDim2"),
	numberrange = Draft.Primitive("NumberRange"),
	colorsequence = Draft.Primitive("ColorSequence"),
	brickcolor = Draft.Primitive("BrickColor"),
	tweeninfo = Draft.Primitive("TweenInfo"),
	datetime = Draft.Primitive("DateTime"),
}

--- What stands for the data of an event the definitions name and give no schema.
local NO_SCHEMA = "no schema at all"

--- Types with no equivalent.
local MISSING = { "rect", "ray", "numbersequence", "physicalproperties", "font" }

--- A side's methods that send, listen or wait, none of which does anything here: a definitions
--- file that also connects its listeners still loads.
local INERT = { "Fire", "Fires", "FireExcept", "Disconnect", "DisconnectAll", "Destroy", "awaitReady" }

--- The module to hand the definitions, and the function that returns what they defined.
function Warp.new(): ({ [string]: any }, () -> Draft.Draft)
	local Into = Draft.new(Warp.NAME, Warp.VERSION)
	local Events: { [string]: Declaration } = {}

	local function Unknown(Where: string)
		return {
			__index = function(_, Name: any)
				error(`{Where}.{Name} is not known to the converter, which was written for Warp {Warp.VERSION}`, 0)
			end,
		}
	end

	local Schema: { [string]: any } = {}
	for Name, Type in TYPES do
		Schema[Name] = Shapes.Token(Type)
	end
	for _, Name in MISSING do
		Schema[Name] = Shapes.Token(Draft.Unmapped(`Schema.{Name}`))
	end

	function Schema.optional(Item: any)
		return Shapes.Token(Draft.Optional(Shapes.Expect(Item, "An optional's item")))
	end

	function Schema.array(Item: any)
		return Shapes.Token(Draft.Array(Shapes.Expect(Item, "An array's item")))
	end

	function Schema.map(Key: any, Value: any)
		return Shapes.Token(Draft.Map(Shapes.Expect(Key, "A map's key"), Shapes.Expect(Value, "A map's value")))
	end

	function Schema.struct(Fields: any)
		return Shapes.Token(Shapes.Struct(Fields, "A struct"))
	end

	--- A type of the game's own, written by functions a schema has no way to hold.
	function Schema.custom_datatype(Name: any)
		rawset(Schema, Name, Shapes.Token(Draft.Unmapped(`the custom datatype {Name}`)))
	end
	setmetatable(Schema, Unknown("Schema"))

	--- The event called `Name`, made the first time the definitions name it.
	local function Event(Name: any): Declaration
		local Subject = tostring(Name)
		if not Events[Subject] then
			Events[Subject] = {
				Kind = "Event",
				Name = Draft.Identifier(Subject),
				--> A listener may return values for an Invoke, so it may yield; there may be many.
				Call = "ManyAsync",
				--> Warp has no schema for it yet, and may never: without one it packs any value.
				Data = Draft.Unmapped(NO_SCHEMA),
			}
		end

		return Events[Subject]
	end

	local function Listen(Name: any)
		Event(Name)
		return { Connected = true, Disconnect = function() end }
	end

	--- `Warp.Server()` and `Warp.Client()` answer with the same members here: what is defined
	--- through either is the same event.
	local function Side(): any
		local Members: { [string]: any } = { Schema = Schema, Connect = Listen, Once = Listen }
		for _, Name in INERT do
			Members[Name] = function() end
		end

		function Members.useSchema(Name: any, Definition: any)
			Event(Name).Data = Shapes.Expect(Definition, `The schema of "{Name}"`)
		end

		function Members.reg_namespaces(Names: any)
			for _, Name in Names do
				Event(Name)
			end
		end

		function Members.Wait()
			error("An event was waited on while its definitions were being read: nothing arrives here", 0)
		end
		Members.Invoke = Members.Wait

		return setmetatable(Members, Unknown("Warp's server or client"))
	end

	local Module: { [string]: any } = {
		Server = Side,
		Client = Side,
		Buffer = { Schema = Schema },
	}
	setmetatable(Module, Unknown("Warp"))

	return Module :: any,
		function()
			--> The definitions give schemas from a table, in no order: by name, so a draft is the same twice.
			local Names: { string } = {}
			for Name in Events do
				table.insert(Names, Name)
			end
			table.sort(Names)

			for _, Name in Names do
				local Declaration = Events[Name]
				for _, Original in Inbound.Unmapped(Declaration.Data) do
					table.insert(Into.Notes, {
						Severity = "Dropped",
						Subject = Name,
						Message = if Original == NO_SCHEMA
							then "the definitions name this event and give it no schema: its data is unknown, which is not validated"
							else `{Original} has no equivalent and became unknown, which is not validated`,
					})
				end
				table.insert(Into.Body, Declaration)
			end

			Shapes.Name(Into)
			return Into
		end
end

return Warp
