--!strict
--- What a converter reads out of another tool's definitions, before any of it is BlinkBlox text.
---
--- Every front end builds one of these -- the zap parser from a `.zap` file, the recording stubs from
--- a runtime library's definitions -- and Print.luau turns it into a schema. Keeping the two apart is
--- what lets five tools share one printer, one set of TODO markers and one checklist.
---
--- A field left nil means the source did not say: an event with no `From` came from a library whose
--- events go both ways, and the printer marks it for the reader instead of guessing silently.

--- Bounds as the source wrote them, kept as text so `0.5` and `1000000` print as they were read.
export type Range = { Min: string?, Max: string? }

--- A struct field, or one value of a tuple; a tuple's value may have no name.
export type Field = { Name: string?, Type: Type }

export type Variant = { Name: string, Fields: { Field } }

export type Type = {
	Kind: "Primitive"
		| "Reference"
		| "Struct"
		| "Array"
		| "Map"
		| "Enum"
		| "TaggedEnum"
		| "Tuple"
		| "Optional"
		| "Unmapped",
	--- Primitive: the BlinkBlox spelling, generics and class included (`vector<i16>`, `Instance(Part)`).
	--- Reference: the name of a declared type, dotted when it sits in a scope.
	Name: string?,
	--- A number's values, or the length of a string, a buffer or an array.
	Range: Range?,
	--- Struct and Tuple.
	Fields: { Field }?,
	--- What an Array or an Optional holds, and a Map's values.
	Of: Type?,
	--- A Map's keys.
	Key: Type?,
	--- A unit Enum's values.
	Values: { string }?,
	--- A TaggedEnum's tag field and its variants.
	Tag: string?,
	Variants: { Variant }?,
	--- Unmapped: the source text of what BlinkBlox has no type for, printed in a comment.
	Original: string?,
}

--- Something the reader has to know about the conversion: a construct that became a near
--- equivalent (`Lossy`), or one with no equivalent that the draft leaves out or widens (`Dropped`).
export type Note = {
	Severity: "Lossy" | "Dropped",
	Message: string,
	--- The declaration it is about, and the line of the source it was read from.
	Subject: string?,
	Line: number?,
}

export type Declaration = {
	Kind: "Type" | "Event" | "Function" | "Scope",
	Name: string,
	--- Comments the source carried on this declaration, without their `--`.
	Comments: { string }?,
	--- Type.
	Type: Type?,
	--- Type: a schema cannot declare it, and Aliases.luau wrote it out wherever it was used.
	IsWrittenOut: boolean?,
	--- Event and Function. nil: the source does not declare a direction.
	From: ("Server" | "Client")?,
	--- Event. nil: the source does not declare it.
	Reliability: ("Reliable" | "Unreliable" | "OrderedUnreliable")?,
	Call: string?,
	--- Event: a rate limit the source did carry, in events a second.
	Rate: string?,
	--- Function.
	Yield: string?,
	Data: Type?,
	Return: Type?,
	--- Scope.
	Body: { Declaration }?,
}

export type Option = {
	Name: string,
	--- As it is written after the `=`: quoted when it is a string.
	Value: string,
	Comments: { string }?,
}

export type Draft = {
	--- The tool the definitions were written for and the version the converter was written against.
	Tool: string,
	Version: string,
	Options: { Option },
	Body: { Declaration },
	Notes: { Note },
}

local Draft = {}

function Draft.new(Tool: string, Version: string): Draft
	return { Tool = Tool, Version = Version, Options = {}, Body = {}, Notes = {} }
end

function Draft.Primitive(Name: string, Range: Range?): Type
	return { Kind = "Primitive", Name = Name, Range = Range }
end

function Draft.Reference(Name: string): Type
	return { Kind = "Reference", Name = Name }
end

function Draft.Struct(Fields: { Field }): Type
	return { Kind = "Struct", Fields = Fields }
end

function Draft.Array(Of: Type, Range: Range?): Type
	return { Kind = "Array", Of = Of, Range = Range }
end

function Draft.Map(Key: Type, Of: Type): Type
	return { Kind = "Map", Key = Key, Of = Of }
end

function Draft.Enum(Values: { string }): Type
	return { Kind = "Enum", Values = Values }
end

function Draft.TaggedEnum(Tag: string, Variants: { Variant }): Type
	return { Kind = "TaggedEnum", Tag = Tag, Variants = Variants }
end

function Draft.Tuple(Fields: { Field }): Type
	return { Kind = "Tuple", Fields = Fields }
end

--- An optional of an optional is the one optional, and `unknown` admits nil as it is: a schema
--- refuses `unknown?`.
function Draft.Optional(Of: Type): Type
	if Of.Kind == "Optional" or Of.Kind == "Unmapped" or (Of.Kind == "Primitive" and Of.Name == "unknown") then
		return Of
	end

	return { Kind = "Optional", Of = Of }
end

function Draft.Unmapped(Original: string): Type
	return { Kind = "Unmapped", Original = Original }
end

--- Whether `Name` can be written as a field, a value or a declaration in a schema.
function Draft.IsIdentifier(Name: string): boolean
	return string.match(Name, "^[%a_][%w_]*$") ~= nil
end

--- `Name` with everything a schema cannot spell replaced, for a key the source wrote as a string.
function Draft.Identifier(Name: string): string
	local Spelled = string.gsub(Name, "[^%w_]", "_")
	if Spelled == "" or string.match(Spelled, "^%d") then
		Spelled = `_{Spelled}`
	end

	return Spelled
end

return Draft
