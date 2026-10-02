--!strict
--- zap's type expressions, read into Draft types.
---
--- Most of zap's types are BlinkBlox's under the same name. The ones that are not are each handled
--- by name below, and each leaves a note: nothing is widened or left out without saying so.
local Draft = require("../Draft")
local Stream = require("./Stream")

type Stream = Stream.Stream
type Type = Draft.Type

local NUMBERS: { [string]: true } = {
	f32 = true,
	f64 = true,
	i8 = true,
	i16 = true,
	i32 = true,
	u8 = true,
	u16 = true,
	u32 = true,
}

--- Names zap resolves to a type of its own, and what BlinkBlox calls each.
local BUILTIN: { [string]: string } = {
	boolean = "boolean",
	unknown = "unknown",
	CFrame = "CFrame",
	AlignedCFrame = "CFrame",
	Color3 = "Color3",
	BrickColor = "BrickColor",
	DateTime = "DateTime",
	DateTimeMillis = "DateTimeMillis",
	Vector2 = "Vector2",
	Vector3 = "vector",
}

local Types = {}

--- `0..100`, `0..`, `..100`, `100`, or `..` for no bound at all.
local function Range(Self: Stream): Draft.Range?
	local Min: string?
	local Max: string?

	if Stream.Peek(Self).Kind == "Number" then
		Min = Stream.Next(Self).Text
		if not Stream.Accept(Self, "..") then
			return { Min = Min, Max = Min }
		end
	else
		Stream.Expect(Self, "..")
	end

	if Stream.Peek(Self).Kind == "Number" then
		Max = Stream.Next(Self).Text
	end

	return if Min or Max then { Min = Min, Max = Max } else nil
end

--- The range in parentheses after a type's name, when there is one.
local function Bounds(Self: Stream): Draft.Range?
	if not Stream.Accept(Self, "(") then
		return nil
	end

	local Found = Range(Self)
	Stream.Expect(Self, ")")
	return Found
end

--- A struct field's or an enum value's name, which zap also takes as a string.
local function Key(Self: Stream): string
	local Token = Stream.Next(Self)
	if Token.Kind == "Word" then
		return Token.Text
	elseif Token.Kind ~= "String" then
		Stream.Fail(Token, "a name")
	end

	if Draft.IsIdentifier(Token.Text) then
		return Token.Text
	end

	local Name = Draft.Identifier(Token.Text)
	Stream.Note(Self, "Lossy", `"{Token.Text}" is not a name a schema can spell and became {Name}`, Token.Line)
	return Name
end

local function Fields(Self: Stream): { Draft.Field }
	local Found: { Draft.Field } = {}
	Stream.Expect(Self, "{")
	while not Stream.Is(Self, "}") do
		local Name = Key(Self)
		Stream.Expect(Self, ":")
		table.insert(Found, { Name = Name, Type = Types.Parse(Self) })
		if not Stream.Accept(Self, ",") then
			break
		end
	end
	Stream.Expect(Self, "}")
	return Found
end

local function Enum(Self: Stream): Type
	if Stream.Peek(Self).Kind == "String" then
		local Tag = Stream.Next(Self).Text
		local Variants: { Draft.Variant } = {}
		Stream.Expect(Self, "{")
		while not Stream.Is(Self, "}") do
			local Name = Key(Self)
			table.insert(Variants, { Name = Name, Fields = Fields(Self) })
			if not Stream.Accept(Self, ",") then
				break
			end
		end
		Stream.Expect(Self, "}")
		return Draft.TaggedEnum(Tag, Variants)
	end

	local Values: { string } = {}
	Stream.Expect(Self, "{")
	while not Stream.Is(Self, "}") do
		table.insert(Values, Key(Self))
		if not Stream.Accept(Self, ",") then
			break
		end
	end
	Stream.Expect(Self, "}")
	return Draft.Enum(Values)
end

--- `vector`, or `vector(x, y)` and `vector(x, y, z)` naming each component's number type.
local function Vector(Self: Stream, Line: number): Type
	if not Stream.Accept(Self, "(") then
		return Draft.Primitive("vector")
	end

	local Components: { Type } = {}
	repeat
		table.insert(Components, Types.Parse(Self))
	until not Stream.Accept(Self, ",")
	Stream.Expect(Self, ")")

	local Name = Components[1].Name
	local Uniform = true
	for _, Component in Components do
		Uniform = Uniform and Component.Kind == "Primitive" and Component.Name == Name and Component.Range == nil
	end

	if #Components == 2 then
		Stream.Note(Self, "Lossy", "a two-component vector became a vector: Z is sent, not left out", Line)
	end

	if not Uniform then
		Stream.Note(Self, "Lossy", "a vector whose components differ in type became a plain vector, of f32", Line)
		return Draft.Primitive("vector")
	end

	return Draft.Primitive(if Name == "f32" then "vector" else `vector<{Name}>`)
end

local function Map(Self: Stream, Line: number): Type
	Stream.Expect(Self, "{")
	Stream.Expect(Self, "[")
	local KeyType = Types.Parse(Self)
	Stream.Expect(Self, "]")
	Stream.Expect(Self, ":")
	local Value = Types.Parse(Self)
	Stream.Expect(Self, "}")

	--> A schema refuses an optional key or value: an absent entry is how a table says nil.
	if KeyType.Kind == "Optional" or Value.Kind == "Optional" then
		Stream.Note(Self, "Lossy", "a map's optional key or value became required: a map holds no nil", Line)
		KeyType = if KeyType.Kind == "Optional" then KeyType.Of :: Type else KeyType
		Value = if Value.Kind == "Optional" then Value.Of :: Type else Value
	end

	return Draft.Map(KeyType, Value)
end

--- `(A | B | C)`, read only to find where it ends: BlinkBlox has no type that is one of several.
local function Union(Self: Stream): Type
	local Open = Stream.Expect(Self, "(")
	repeat
		Types.Parse(Self)
	until not Stream.Accept(Self, "|")
	local Close = Stream.Expect(Self, ")")

	Stream.Note(
		Self,
		"Dropped",
		"a union has no equivalent and became unknown, which is not validated; a tagged enum is the checked form",
		Open.Line
	)
	return Draft.Unmapped(string.sub(Self.Source, Open.Start, Close.Finish))
end

--- `Instance`, `Instance.Class` or `Instance(Class)`.
local function Instance(Self: Stream): Type
	if Stream.Accept(Self, ".") then
		return Draft.Primitive(`Instance({Stream.Word(Self, "a class").Text})`)
	elseif Stream.Accept(Self, "(") then
		local Class = Stream.Word(Self, "a class").Text
		Stream.Expect(Self, ")")
		return Draft.Primitive(`Instance({Class})`)
	end

	return Draft.Primitive("Instance")
end

--- A type that begins with one of zap's own words and takes a range after it.
local function Ranged(Self: Stream, Token: Stream.Token): Type?
	local Name = Token.Text
	if NUMBERS[Name] or Name == "buffer" then
		return Draft.Primitive(Name, Bounds(Self))
	elseif Name == "string" then
		--> `.utf8` and `.binary` choose what zap checks; the bytes on the wire are a string's either way.
		if Stream.Accept(Self, ".") and Stream.Word(Self, "utf8 or binary").Text == "utf8" then
			Stream.Note(Self, "Lossy", "string.utf8 became string: nothing checks that it is UTF-8", Token.Line)
		end

		return Draft.Primitive("string", Bounds(Self))
	end

	return nil
end

--- A type that begins with a word zap reads as one only before a brace: `struct`, `enum`, `map`
--- and `set` are names like any other elsewhere.
local function Braced(Self: Stream, Token: Stream.Token): Type?
	local Name = Token.Text
	if Name == "enum" and Stream.Peek(Self).Kind == "String" then
		return Enum(Self)
	elseif not Stream.Is(Self, "{") then
		return nil
	end

	if Name == "struct" then
		return Draft.Struct(Fields(Self))
	elseif Name == "enum" then
		return Enum(Self)
	elseif Name == "map" then
		return Map(Self, Token.Line)
	elseif Name == "set" then
		Stream.Expect(Self, "{")
		local Member = Types.Parse(Self)
		Stream.Expect(Self, "}")
		Stream.Note(Self, "Lossy", "a set became a map to boolean: every value in it is true", Token.Line)
		return Draft.Map(Member, Draft.Primitive("boolean"))
	end

	return nil
end

local function Primary(Self: Stream): Type
	if Stream.Is(Self, "(") then
		return Union(Self)
	end

	local Token = Stream.Word(Self, "a type")
	local Name = Token.Text

	local Own = Ranged(Self, Token) or Braced(Self, Token)
	if Own then
		return Own
	elseif Name == "vector" then
		return Vector(Self, Token.Line)
	elseif Name == "Instance" then
		return Instance(Self)
	end

	--> A name, or a path through namespaces: scopes are named the same way.
	while Stream.Accept(Self, ".") do
		Name ..= `.{Stream.Word(Self, "a name").Text}`
	end

	if Name == "AlignedCFrame" then
		Stream.Note(Self, "Lossy", "AlignedCFrame became CFrame: there is no axis-aligned encoding", Token.Line)
	end

	local Builtin = BUILTIN[Name]
	return if Builtin then Draft.Primitive(Builtin) else Draft.Reference(Name)
end

--- A type, with any `[..]` and `?` after it.
function Types.Parse(Self: Stream): Type
	local Type = Primary(Self)
	while true do
		if Stream.Accept(Self, "[") then
			local Length = if Stream.Is(Self, "]") then nil else Range(Self)
			Stream.Expect(Self, "]")
			Type = Draft.Array(Type, Length)
		elseif Stream.Accept(Self, "?") then
			Type = Draft.Optional(Type)
		else
			return Type
		end
	end
end

return Types
