--!strict
--- Makes a Draft's named types ones a schema can declare.
---
--- A schema names a struct, an enum and a map each under its own keyword, and `type` names only a
--- plain value, an array of one or an optional of one. Other tools name anything: `Item[]`, an
--- optional struct, another name for a struct. Such a name cannot be declared, so it is written out
--- wherever it was used, which sends the same thing, and a struct that had no name of its own under
--- the array is given one first.
local Draft = require("./Draft")
local Inbound = require("./Inbound")

type Type = Draft.Type
type Declaration = Draft.Declaration
type Entry = Inbound.Entry

--- Kinds that `type` cannot name: each has a keyword of its own.
local KEYWORDED = { Struct = true, Enum = true, TaggedEnum = true, Map = true }

local Aliases = {}

--- What an array or an optional is of, in the end, and whether `Type` was one.
local function Core(Type: Type): (Type, boolean)
	local IsWrapped = false
	while Type.Kind == "Array" or Type.Kind == "Optional" do
		Type = Type.Of :: Type
		IsWrapped = true
	end

	return Type, IsWrapped
end

--- `Type` with the innermost type under its arrays and optionals replaced by `Inner`.
local function Rewrap(Type: Type, Inner: Type): Type
	if Type.Kind ~= "Array" and Type.Kind ~= "Optional" then
		return Inner
	end

	local Copy = table.clone(Type)
	Copy.Of = Rewrap(Type.Of :: Type, Inner)
	return Copy
end

--- Gives a struct, an enum or a map written under an array or an optional a declaration of its own,
--- named after the type that held it.
local function Hoist(Body: { Declaration })
	local Index = 1
	while Index <= #Body do
		local Declaration = Body[Index]
		if Declaration.Kind == "Scope" then
			Hoist(Declaration.Body :: { Declaration })
		elseif Declaration.Kind == "Type" then
			local Inner, IsWrapped = Core(Declaration.Type :: Type)
			if IsWrapped and KEYWORDED[Inner.Kind] then
				local Name = `{Declaration.Name}Value`
				Declaration.Type = Rewrap(Declaration.Type :: Type, Draft.Reference(Name))
				local Hoisted: Declaration = { Kind = "Type", Name = Name, Type = Inner }
				table.insert(Body, Index, Hoisted)
				Index += 1
			end
		end

		Index += 1
	end
end

--- Whether `type` can declare this: a plain value in the end, however many names it goes through.
local function IsPlain(Types: { [string]: Entry }, Entry: Entry, Seen: { [Declaration]: true }): boolean
	local Inner = Core(Entry.Declaration.Type :: Type)
	if Inner.Kind ~= "Reference" then
		return not KEYWORDED[Inner.Kind]
	end

	--> A name that leads back to itself, or to nothing declared, is left for the compiler to refuse.
	local Target = Inbound.Resolve(Types, Inner.Name :: string, Entry.Scope)
	if not Target or Seen[Target.Declaration] then
		return true
	end

	Seen[Target.Declaration] = true
	return IsPlain(Types, Target, Seen)
end

--- Settles `Source` in place: every named type left in it is one a schema declares.
function Aliases.Settle(Source: Draft.Draft)
	Hoist(Source.Body)

	local Types: { [string]: Entry } = {}
	Inbound.Index(Source.Body, {}, Types)

	local Written: { [Declaration]: Entry } = {}
	for _, Entry in Types do
		local Declaration = Entry.Declaration
		if not KEYWORDED[(Declaration.Type :: Type).Kind] and not IsPlain(Types, Entry, {}) then
			Written[Declaration] = Entry
		end
	end

	--- `Type` with each name that cannot be declared written out. Inside one that was written out,
	--- the names that remain are spelled from the top: they were read in its scope, not this one.
	local function Expand(Type: Type?, Scope: { string }, IsQualified: boolean, Depth: number): Type?
		if not Type or Depth > 32 then
			return Type
		end

		if Type.Kind == "Reference" then
			local Target = Inbound.Resolve(Types, Type.Name :: string, Scope)
			if Target and Written[Target.Declaration] then
				return Expand(Target.Declaration.Type, Target.Scope, true, Depth + 1)
			elseif Target and IsQualified then
				local Path = table.clone(Target.Scope)
				table.insert(Path, Target.Declaration.Name)
				return Draft.Reference(table.concat(Path, "."))
			end

			return Type
		elseif Type.Kind == "Optional" then
			return Draft.Optional(Expand(Type.Of, Scope, IsQualified, Depth) :: Type)
		end

		local Copy = table.clone(Type)
		Copy.Of = Expand(Type.Of, Scope, IsQualified, Depth)
		Copy.Key = Expand(Type.Key, Scope, IsQualified, Depth)

		if Type.Fields then
			local Fields: { Draft.Field } = {}
			for _, Field in Type.Fields do
				table.insert(
					Fields,
					{ Name = Field.Name, Type = Expand(Field.Type, Scope, IsQualified, Depth) :: Type }
				)
			end
			Copy.Fields = Fields
		end

		if Type.Variants then
			local Variants: { Draft.Variant } = {}
			for _, Variant in Type.Variants do
				local Fields: { Draft.Field } = {}
				for _, Field in Variant.Fields do
					table.insert(
						Fields,
						{ Name = Field.Name, Type = Expand(Field.Type, Scope, IsQualified, Depth) :: Type }
					)
				end
				table.insert(Variants, { Name = Variant.Name, Fields = Fields })
			end
			Copy.Variants = Variants
		end

		return Copy
	end

	local function Walk(Body: { Declaration }, Scope: { string })
		for _, Declaration in Body do
			if Declaration.Kind == "Scope" then
				local Path = table.clone(Scope)
				table.insert(Path, Declaration.Name)
				Walk(Declaration.Body :: { Declaration }, Path)
			elseif Written[Declaration] then
				Declaration.IsWrittenOut = true
				table.insert(Source.Notes, {
					Severity = "Lossy",
					Subject = Declaration.Name,
					Message = "a schema names no array or optional of a struct, an enum or a map, "
						.. "nor a second name for one: this type is written out where it was used",
				})
			else
				Declaration.Type = Expand(Declaration.Type, Scope, false, 0)
				Declaration.Data = Expand(Declaration.Data, Scope, false, 0)
				Declaration.Return = Expand(Declaration.Return, Scope, false, 0)
			end
		end
	end
	Walk(Source.Body, {})
end

return Aliases
