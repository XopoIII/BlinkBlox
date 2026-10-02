--!strict
--- Which of a Draft's types a client can send, and what in them nothing bounds.
---
--- A length without an upper bound matters where a client chooses it: the server reads what a
--- hostile client names. The same array in an event only the server fires is the server's own
--- business. So the printer marks only what this module finds on the way in, and a draft of server
--- broadcasts is not buried under markers that change nothing.
local Draft = require("./Draft")

type Type = Draft.Type
type Declaration = Draft.Declaration

--- A type declaration and the scopes it sits in, outermost first.
export type Entry = { Declaration: Declaration, Scope: { string } }

local Inbound = {}

--- Every type declaration by its dotted name.
function Inbound.Index(Body: { Declaration }, Scope: { string }, Into: { [string]: Entry })
	for _, Declaration in Body do
		local Path = table.clone(Scope)
		table.insert(Path, Declaration.Name)

		if Declaration.Kind == "Type" then
			Into[table.concat(Path, ".")] = { Declaration = Declaration, Scope = Scope }
		elseif Declaration.Kind == "Scope" then
			Inbound.Index(Declaration.Body :: { Declaration }, Path, Into)
		end
	end
end

--- The names `Type` refers to.
local function References(Type: Type?, Into: { string })
	if not Type then
		return
	end

	if Type.Kind == "Reference" then
		table.insert(Into, Type.Name :: string)
	end

	References(Type.Of, Into)
	References(Type.Key, Into)
	for _, Field in (Type.Fields or {}) :: { Draft.Field } do
		References(Field.Type, Into)
	end
	for _, Variant in (Type.Variants or {}) :: { Draft.Variant } do
		for _, Field in Variant.Fields do
			References(Field.Type, Into)
		end
	end
end

--- The declaration `Name` means from inside `Scope`: the innermost scope that declares it wins.
function Inbound.Resolve(Types: { [string]: Entry }, Name: string, Scope: { string }): Entry?
	for Depth = #Scope, 0, -1 do
		local Path = table.move(Scope, 1, Depth, 1, {})
		table.insert(Path, Name)

		local Found = Types[table.concat(Path, ".")]
		if Found then
			return Found
		end
	end

	return nil
end

--- The type declarations a client's data can reach: the payload of each event a client fires, the
--- half of each function a client supplies, and everything those name. An event with no direction
--- counts, since the reader has yet to say it is not a client's.
function Inbound.Reachable(Body: { Declaration }): { [Declaration]: true }
	local Types: { [string]: Entry } = {}
	Inbound.Index(Body, {}, Types)

	local Reached: { [Declaration]: true } = {}
	local Queue: { { Type: Type?, Scope: { string } } } = {}

	local function Roots(Declarations: { Declaration }, Scope: { string })
		for _, Declaration in Declarations do
			if Declaration.Kind == "Event" and Declaration.From ~= "Server" then
				table.insert(Queue, { Type = Declaration.Data, Scope = Scope })
			elseif Declaration.Kind == "Function" then
				local Sent = if Declaration.From == "Server" then Declaration.Return else Declaration.Data
				table.insert(Queue, { Type = Sent, Scope = Scope })
			elseif Declaration.Kind == "Scope" then
				local Path = table.clone(Scope)
				table.insert(Path, Declaration.Name)
				Roots(Declaration.Body :: { Declaration }, Path)
			end
		end
	end
	Roots(Body, {})

	while #Queue > 0 do
		local Item = table.remove(Queue) :: { Type: Type?, Scope: { string } }
		local Names: { string } = {}
		References(Item.Type, Names)

		for _, Name in Names do
			local Found = Inbound.Resolve(Types, Name, Item.Scope)
			if Found and not Reached[Found.Declaration] then
				Reached[Found.Declaration] = true
				table.insert(Queue, { Type = Found.Declaration.Type, Scope = Found.Scope })
			end
		end
	end

	return Reached
end

--- The source text of each construct in `Type` that the draft could only call `unknown`.
function Inbound.Unmapped(Type: Type?, Into: { string }?): { string }
	local Found: { string } = Into or {}
	if not Type then
		return Found
	end

	if Type.Kind == "Unmapped" then
		table.insert(Found, (string.gsub(Type.Original :: string, "%s+", " ")))
	end

	Inbound.Unmapped(Type.Of, Found)
	Inbound.Unmapped(Type.Key, Found)
	for _, Field in (Type.Fields or {}) :: { Draft.Field } do
		Inbound.Unmapped(Field.Type, Found)
	end
	for _, Variant in (Type.Variants or {}) :: { Draft.Variant } do
		for _, Field in Variant.Fields do
			Inbound.Unmapped(Field.Type, Found)
		end
	end

	return Found
end

--- What about `Type` itself a sender sets without limit, if anything.
local function Unlimited(Type: Type): string?
	local HasMax = Type.Range ~= nil and Type.Range.Max ~= nil

	if Type.Kind == "Unmapped" or (Type.Kind == "Primitive" and Type.Name == "unknown") then
		return "unknown is not validated"
	elseif Type.Kind == "Map" then
		return "a map cannot be bounded: prefer a bounded array"
	elseif HasMax then
		return nil
	elseif Type.Kind == "Array" then
		return "array length"
	elseif Type.Kind == "Primitive" and (Type.Name == "string" or Type.Name == "buffer") then
		return `{Type.Name} length`
	end

	return nil
end

--- Adds to `Into` each place in `Type` a sender sets a size or a value that nothing limits, as the
--- path to it and what it is. Named types are not followed: each is marked where it is declared.
function Inbound.Unbounded(Type: Type?, Path: string, Into: { string })
	if not Type then
		return
	end

	local Here = if Path == "" then "the value" else Path
	local Why = Unlimited(Type)
	if Why then
		table.insert(Into, `{Here} ({Why})`)
	end

	if Type.Kind == "Array" then
		Inbound.Unbounded(Type.Of, `{Path}[]`, Into)
	elseif Type.Kind == "Map" then
		Inbound.Unbounded(Type.Key, `{Path}[key]`, Into)
		Inbound.Unbounded(Type.Of, `{Path}[value]`, Into)
	elseif Type.Kind == "Optional" then
		Inbound.Unbounded(Type.Of, Path, Into)
	end

	for Position, Field in (Type.Fields or {}) :: { Draft.Field } do
		local Name = Field.Name or `#{Position}`
		Inbound.Unbounded(Field.Type, if Path == "" then Name else `{Path}.{Name}`, Into)
	end
	for _, Variant in (Type.Variants or {}) :: { Draft.Variant } do
		for _, Field in Variant.Fields do
			local Name = `{Variant.Name}.{Field.Name}`
			Inbound.Unbounded(Field.Type, if Path == "" then Name else `{Path}.{Name}`, Into)
		end
	end
end

return Inbound
