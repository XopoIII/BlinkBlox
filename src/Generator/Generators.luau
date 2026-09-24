--!strict
--!native
--!optimize 2

--- Luau types and serialisers for type declarations, the per-event read and write functions, and the
--- walk over a schema's declarations that dispatches each one to its generator.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Fragments = require("./Fragments")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Serde = require("./Serde")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode

local IGNORED_TYPES_IN_SHARED = Fragments.IGNORED_TYPES_IN_SHARED
local Types = Prefabs.Types
local Primitives = Prefabs.Primitives
local Declarations = Serde

local Generators = {}

--- Dispatches a node to the serde function for its kind. Serde.Emit points back here so that a
--- struct, an array or a map can emit whatever it contains without either file requiring the other.
function Generators.UserType(Declaration: Type, Read: Blocks.Block, Write: Blocks.Block, Variable: string?)
	local Name = Declaration.Name
	local Target = Variable or "Value"

	if not _G.RELEASE then
		Read:Comment(`{Target}: {Name}`)
		Write:Comment(`{Target}: {Name}`)
	end

	if Declaration.Type == "Primitive" then
		local Kind = (Declaration :: Parser.Primitive).Tokens.Primitive.Value
		if Kind == "Instance" then
			Read:Line("RecieveInstanceCursor += 1")
		end

		Declarations.Primitive(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Set" then
		Declarations.Set(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Map" then
		Declarations.Map(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Enum" then
		Declarations.Enum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Struct" then
		Declarations.Struct(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Tuple" then
		Declarations.Tuple(Declaration, Read, Write)
	elseif Declaration.Type == "TagEnum" then
		Declarations.TagEnum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Array" then
		Declarations.Array(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Optional" then
		Declarations.Optional(Declaration, Read, Write, Target)
	end
end

function Generators.LuauType(
	Declaration: Type,
	UseTypeAsValue: boolean?,
	Prefix: string?
): (string, string, string, string)
	Prefix = Prefix or ""

	local Type = "nil"
	local Values = "Value: nil"
	local Export = Util.GetExportName(Declaration.Name, State.Scope)
	local Returns = `{Prefix}Value`

	if Declaration.Type == "Primitive" then
		local Tokens = (Declaration :: Parser.Primitive).Tokens
		local Primitive = Primitives[Tokens.Primitive.Value]
		if type(Primitive.Type) == "function" then
			Type = Primitive.Type(Declaration :: Parser.Primitive)
		else
			Type = Primitive.Type
		end
	elseif Declaration.Type == "Set" then
		Type = Util.SetType((Declaration :: Parser.Set).Value.Values)
	elseif Declaration.Type == "Enum" then
		local Value = (Declaration :: Parser.Enum).Value
		Type = `({Util.GenerateEnumLiterals(Value.Values)})`
	elseif Declaration.Type == "TagEnum" then
		local Value = (Declaration :: Parser.TagEnum).Value
		Type = Util.TagEnumType(Value.Tag, Value.Values, function(Variant)
			return (Generators.LuauType(Variant))
		end)
	elseif Declaration.Type == "Map" then
		local MapValue = (Declaration :: Parser.Map).Value
		local Key = Generators.LuauType(MapValue.Values[1])
		local Value = Generators.LuauType(MapValue.Values[2])
		Type = `\{[{Key}]: {Value}\}`
	elseif Declaration.Type == "Struct" then
		Type = Util.StructType(Declaration.Value.Values, function(Field)
			return (Generators.LuauType(Field))
		end, false)
	elseif Declaration.Type == "Generic" then
		Type = `{Declaration.Value.Generic}`
	elseif Declaration.Type == "Tuple" then
		local Value = (Declaration :: Parser.Tuple).Value

		local TupleTypes = { "nil" }
		local Variables = { "Value" }
		local AnnotatedVariables = { "Value: nil" }

		--> The prefix applies to a named element too: a function's Data and Return packs share a scope
		--> in the generated body, so it is what keeps `(id: u8)` and `(id: string)` from colliding.
		for Index, TupleValue in Value.Values do
			local Variable = `{Prefix}{Value.Names[Index] or `Value{Index}`}`
			local ValueType = Generators.LuauType(TupleValue)

			TupleTypes[Index] = ValueType
			Variables[Index] = Variable
			AnnotatedVariables[Index] = `{Variable}: {ValueType}`
		end

		Type = table.concat(TupleTypes, ", ")
		Values = table.concat(AnnotatedVariables, ", ")
		Returns = table.concat(Variables, ", ")
	elseif Declaration.Type == "Array" then
		local Value = Declaration.Value
		Type = `\{ {Generators.LuauType(Value.Of)} }`
	elseif Declaration.Type == "Optional" then
		local Value = Declaration.Value
		Type = `{Generators.LuauType(Value.Of)}?`
	end

	--> Generalized type generation, works for everything except tuples
	if Declaration.Type ~= "Tuple" then
		Values = `{Prefix}Value: {UseTypeAsValue and Type or Export}`
	end

	return Type, Values, Export, Returns
end

function Generators.Type(Declaration: Type)
	local Value = Declaration.Value
	local Type, _, Export = Generators.LuauType(Declaration)

	local Generics = Util.GenericsHeader(Value.Generics)

	--> Write luau export
	State.LuauTypes.PushMultiline(`export type {Export}{Generics} = {Type}`, 1, 0)
end

function Generators.Export(Declaration: Type)
	local Name = Declaration.Name
	local _, Values, Export, Returns = Generators.LuauType(Declaration)

	local Read = Blocks.Function(State.Casing.Read, "Buffer: buffer", `({Export})`, true)
	local Write = Blocks.Function(State.Casing.Write, `{Values}`, `(buffer)`, true)

	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> Overwrite buffer
	Read:Comment("Buffer overwrite")
	Write:Comment("Buffer overwrite")

	Read:Lines({
		"local PreviousCursor = RecieveCursor\n",
		"local PreviousBuffer = RecieveBuffer\n",
		"local PreviousInstanceCursor = RecieveInstanceCursor\n",
		"RecieveCursor = 0\n",
		"RecieveBuffer = Buffer\n",
	}, 1)

	Write:Lines({
		"local Previous = Save()\n",
		"Load()\n",
	}, 1)

	Read:Advance(#Read.Content - 1)
	Write:Advance(#Write.Content - 1)

	--> Write to buffer
	Read:Comment("Buffer read")
	Write:Comment("Buffer write")

	Generators.UserType(Declaration, Read, Write)

	--> The payload is complete, so any half-filled bitfield has to reach the buffer BEFORE the trim
	--> and the return below. Left to `End`, it would be emitted after the return.
	Read:FlushBits()
	Write:FlushBits()

	--> Restore buffer
	Read:Comment("Buffer restore")
	Write:Comment("Buffer restore")

	Read:Lines({
		"RecieveCursor = PreviousCursor\n",
		"RecieveBuffer = PreviousBuffer\n",
		"RecieveInstanceCursor = PreviousInstanceCursor\n",
	}, 1)

	--> Trim buffer
	Write:Line("local Result = buffer.create(SendCursor)")
	Write:Line("buffer.copy(Result, 0, SendBuffer, 0, SendCursor)")

	Write:Line(`Load(Previous)`)

	--> End export
	Read:Return(Returns)
	Write:Return("Result")

	Read:End():Wrap("", ",")
	Write:End()

	Body.PushLines(Read.Content, 0, Indent + 1)
	Body.PushLines(Write.Content, 0, Indent + 1)
	Body.Push(`\},`, 0, Indent)

	local BodyLines = Body.DumpLines()

	State.Noop.PushLines(table.clone(BodyLines), 0, 0)
	State.Return.PushLines(BodyLines, 0, 0)
end

function Generators.Event(
	Data: Type?,
	Index: number,
	Identifier: string,
	Function: ("Data" | "Return")?,
	Ordered: boolean?
): ({ string }, { string })
	local Type, Values, _, Returns = "nil", "Value: nil", nil, "nil"
	if Data then
		Type, Values, _, Returns = Generators.LuauType(Data, true)
	end

	local Arguments = `{Values}{Function and ", InvocationIdentifier: number" or ""}`
	local Read = Blocks.Function(Util.GetPath(Identifier, false, State.Scope), "", `({Type})`)
	local Write = Blocks.Function(Util.GetPath(Identifier, true, State.Scope), Arguments, "()")

	if not _G.RELEASE then
		Write:Comment(`{Identifier} ({Index})`)
	end

	--> The event index is a literal in the generated code; the writers take the text form.
	Types.u8.Write(tostring(Index), Write)

	--> An ordered event carries a per-event sequence number after its index. It wraps at 65536, and
	--> the receiver's comparison is written to tolerate that.
	if Ordered then
		Write:Line(`local OrderIdentifier = ((OrderOut[{Index}] or 0) + 1) % 65536`)
		Write:Line(`OrderOut[{Index}] = OrderIdentifier`)
		Types.u16.Write("OrderIdentifier", Write)
	end
	if Function then
		Types.u8.Write("InvocationIdentifier", Write)
		if Function == "Return" then
			Types.u8.Write("1", Write)
			Types.u8.Read("Success", Read)
			Read:Compare("Success", "1", "Not"):Line('error("Server encountered an error.")'):End()
		end
	end

	if Data then
		Generators.UserType(Data, Read, Write)
	end

	Read:FlushBits()
	Write:FlushBits()

	return Read:Return(Returns):End().Content, Write:End().Content
end

function Generators.Scope(Declaration: Parser.ScopeNode)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local Parent = State.Scope
	local NewScope = Value.Scope

	local Path = Util.GetScopePrefix(NewScope, true, State.Scope)
	local Indent = (#string.split(Path, ".") - 1)
	Path = string.sub(Path, 1, #Path - 1)

	State.Scope = NewScope
	State.Noop.Push(`{Name} = \{`, 0, Indent)
	State.Return.Push(`{Name} = \{`, 0, Indent)

	Generators.AbstractSyntaxTree(Value.Values)

	State.Noop.Push(`},`, 0, Indent)
	State.Return.Push(`},`, 0, Indent)
	State.Scope = Parent
end

function Generators.AbstractSyntaxTree(Tree: { Parser.Declaration })
	for _, Declaration in Tree do
		if State.Context == "Shared" and IGNORED_TYPES_IN_SHARED[Declaration.Type] then
			continue
		end

		if Declaration.Type == "Scope" then
			Generators.Scope(Declaration :: Parser.ScopeNode)
		elseif Declaration.Type == "Event" then
			Declarations.Event(Declaration :: Parser.Event)
		elseif Declaration.Type == "Function" then
			Declarations.Function(Declaration :: Parser.Function)
		else
			if Declaration.Value.Export then
				Generators.Export(Declaration :: Type)
			end

			Generators.Type(Declaration :: Type)
		end
	end
end

return Generators
