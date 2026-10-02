--!strict
--- What the recording stubs share: values that stand for types, and the tidying a recorded draft
--- needs before it is printed.
---
--- A runtime library's definitions are code. `ByteNet.struct({ id = ByteNet.uint8 })` is a call, and
--- the stub that answers it hands back a token: a table holding the Draft type the real library
--- would have built a serialiser for. The definitions pass tokens around as they would the real
--- thing, and what reaches `definePacket` is the type of the packet.
---
--- Two things are lost on the way and put right here. A Luau table has no order, so a struct's
--- fields are sorted by name: the draft must come out the same on every run. And a definitions file
--- builds one struct through a function it calls five times, which arrives as five equal structs, so
--- a shape used more than once is given a name.
local Draft = require("./Draft")

type Type = Draft.Type
type Declaration = Draft.Declaration

--- A value a stub hands out in place of one of its library's types.
export type Token = { [any]: any }

--- The key a token keeps its type under: a table, so no definitions file can name it.
local MARK = {}

local Shapes = {}

function Shapes.Token(Type: Type): Token
	return { [MARK] = Type }
end

--- The type `Value` stands for, if it is a token.
function Shapes.Read(Value: any): Type?
	return if type(Value) == "table" then Value[MARK] else nil
end

--- The type `Value` stands for. `What` names it in the error raised when it stands for none.
function Shapes.Expect(Value: any, What: string): Type
	local Type = Shapes.Read(Value)
	if not Type then
		error(`{What} is not one of the library's types, but a {typeof(Value)}`, 0)
	end

	return Type
end

--- A struct of the fields in `Fields`, each a token, in the order of their names.
function Shapes.Struct(Fields: { [any]: any }, What: string): Type
	local Names: { string } = {}
	for Name in Fields do
		if type(Name) ~= "string" then
			error(`{What} has a field that is not named by a string`, 0)
		end

		table.insert(Names, Name)
	end
	table.sort(Names)

	local Found: { Draft.Field } = {}
	for _, Name in Names do
		table.insert(Found, { Name = Name, Type = Shapes.Expect(Fields[Name], `{What}.{Name}`) })
	end

	return Draft.Struct(Found)
end

--- A struct's shape as text: two structs with the same fields of the same types have the same one.
local function Key(Type: Type?): string
	if not Type then
		return ""
	end

	local Parts: { string } = { Type.Kind, Type.Name or "" }
	if Type.Range then
		table.insert(Parts, `{Type.Range.Min or ""}..{Type.Range.Max or ""}`)
	end

	table.insert(Parts, Key(Type.Key))
	table.insert(Parts, Key(Type.Of))
	for _, Field in (Type.Fields or {}) :: { Draft.Field } do
		table.insert(Parts, `{Field.Name or ""}:{Key(Field.Type)}`)
	end

	return `({table.concat(Parts, " ")})`
end

--- Counts each struct shape under `Type`, noting the order they are first met in.
local function Count(Type: Type?, Counts: { [string]: number }, Order: { string })
	if not Type then
		return
	end

	if Type.Kind == "Struct" then
		local Shape = Key(Type)
		if not Counts[Shape] then
			table.insert(Order, Shape)
		end
		Counts[Shape] = (Counts[Shape] or 0) + 1
	end

	Count(Type.Key, Counts, Order)
	Count(Type.Of, Counts, Order)
	for _, Field in (Type.Fields or {}) :: { Draft.Field } do
		Count(Field.Type, Counts, Order)
	end
end

--- Gives every struct shape used more than once in `Source` a declaration and a name, `Shape1`
--- onward in the order they are met, and notes that the names are the converter's.
function Shapes.Name(Source: Draft.Draft)
	local Counts: { [string]: number } = {}
	local Order: { string } = {}

	local function Each(Body: { Declaration }, Visit: (Declaration: Declaration) -> ())
		for _, Declaration in Body do
			if Declaration.Kind == "Scope" then
				Each(Declaration.Body :: { Declaration }, Visit)
			else
				Visit(Declaration)
			end
		end
	end

	Each(Source.Body, function(Declaration)
		Count(Declaration.Data, Counts, Order)
		Count(Declaration.Return, Counts, Order)
	end)

	local Names: { [string]: string } = {}
	local Declared: { Declaration } = {}

	--- `Type` with each repeated shape replaced by its name; the shape itself is declared once,
	--- when it is first replaced, after the shapes inside it.
	local function Replace(Type: Type?): Type?
		if not Type then
			return nil
		end

		local Shape = if Type.Kind == "Struct" then Key(Type) else nil
		local Copy = table.clone(Type)
		Copy.Key = Replace(Type.Key)
		Copy.Of = Replace(Type.Of)
		if Type.Fields then
			local Fields: { Draft.Field } = {}
			for _, Field in Type.Fields do
				table.insert(Fields, { Name = Field.Name, Type = Replace(Field.Type) :: Type })
			end
			Copy.Fields = Fields
		end

		if not Shape or Counts[Shape] < 2 then
			return Copy
		end

		if not Names[Shape] then
			Names[Shape] = `Shape{#Declared + 1}`
			table.insert(Declared, { Kind = "Type", Name = Names[Shape], Type = Copy })
		end

		return Draft.Reference(Names[Shape])
	end

	Each(Source.Body, function(Declaration)
		Declaration.Data = Replace(Declaration.Data)
		Declaration.Return = Replace(Declaration.Return)
	end)

	if #Declared == 0 then
		return
	end

	--> Names are global to the schema, so the shapes go at the top, before any scope.
	table.move(Source.Body, 1, #Source.Body, #Declared + 1)
	for Index, Declaration in Declared do
		Source.Body[Index] = Declaration
	end

	table.insert(Source.Notes, {
		Severity = "Lossy",
		Message = `{#Declared} struct(s) used by more than one event were named Shape1 onward: `
			.. "the definitions give them no name, so choose one",
	})
end

return Shapes
