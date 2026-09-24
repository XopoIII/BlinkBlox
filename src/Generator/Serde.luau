--!strict
--- How each kind of type is read from and written to a buffer. One function per node the parser can
--- produce, each emitting into a Read block and a Write block.
---
--- Split out of Generator/init.luau, which is on the size ratchet in scripts/check-file-size.sh.
--- These were the obvious piece to move: of everything in that file they reach for the least of its
--- state. Two things they do need are injected rather than required, because the dependency runs
--- both ways -- the generator dispatches into these, and a struct or an array has to dispatch back
--- out to whatever its fields are.
local Parser = require("../Parser")
local Size = require("../Modules/Size")

local Blocks = require("./Blocks")
local Prefabs = require("./Prefabs")
local Util = require("./Util")

local Types = Prefabs.Types
local Primitives = Prefabs.Primitives

local FormatIndex = Util.FormatIndex
local BitIndexToHex = Util.BitIndexToHex

type Type = Parser.TypeNode
--> One definition shared with Settings, Parser and Prefabs, not Roblox NumberRange userdata.
type NumberRange = Parser.NumberRange

local Serde = {}

--- The recursive entry point, set once by the generator to Generators.UserType. Requiring it here
--- instead would be a cycle: that function's whole job is to dispatch into this table.
Serde.Emit = (nil :: any) :: (Declaration: Type, Read: Blocks.Block, Write: Blocks.Block, Variable: string?) -> ()

--- The options the current generate is running under, set by the generator before it walks the tree.
--- Only WriteValidations is read here, but it is read per primitive, so it has to be the live table
--- rather than a value captured at load.
Serde.Options = (nil :: any) :: Parser.Options

--- The two the generator defines on this table rather than here. An event or a function is not a
--- type on the wire -- emitting one needs scopes, builders, casing and the channel counters, all of
--- which are that file's state. Declared so the table is not sealed against them.
Serde.Event = (nil :: any) :: (Declaration: Parser.Event) -> ()
Serde.Function = (nil :: any) :: (Declaration: Parser.Function) -> ()

function Serde.Primitive(Declaration: Parser.Primitive, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Tokens = Declaration.Tokens
	local Primitive = Tokens.Primitive.Value
	local Generator = Primitives[Primitive]
	Generator.Generate(Declaration, Variable, Read, Write, Serde.Options.WriteValidations)
end

function Serde.Set(Declaration: Parser.Set, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Flags = Value.Values

	do
		--> Read Flags

		Read:Line(`{Read:Declare(Variable)} = \{\}`)

		local Remaining = #Flags
		local FlagIndex = 1

		while Remaining > 0 do
			local Partition = math.min(Remaining, 32)
			Prefabs.GetTypeToUseByBits(Partition).Read("SET_BITS", Read)

			for Index = 1, Partition do
				local Flag = Flags[FlagIndex]

				Read:EmptyDeclare(Flag)
				Read:Line(`{Variable}{FormatIndex(Flag)} = bit32.btest(SET_BITS, {BitIndexToHex(Index - 1)});`)

				FlagIndex += 1
			end

			Remaining -= Partition
		end
	end

	do
		--> Write body

		local Remaining = #Flags
		local FlagIndex = 1

		while Remaining > 0 do
			local Partition = math.min(Remaining, 32)
			Write:Line(`{Write:Declare("SET_BITS")} = 0`)

			for Index = 1, Partition do
				local Flag = Flags[FlagIndex]
				Write:Line(`if {Variable}{FormatIndex(Flag)} == true then SET_BITS += {BitIndexToHex(Index - 1)} end`)
				FlagIndex += 1
			end

			Prefabs.GetTypeToUseByBits(Partition).Write("SET_BITS", Write)

			Remaining -= Partition
		end
	end
end

function Serde.Enum(Declaration: Parser.Enum, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Enums = Value.Values
	local Literal = Util.GenerateEnumLiterals(Enums)
	Literal = string.gsub(Literal, "|", "or")

	--> Read body
	Read:Line(`{Read:Declare(Variable)} = true :: any`)
	Types.u8.Read(`Index`, Read)
	Read = Read:Compare("Index", "0", "Equals")
	for Index, EnumItem in Enums do
		if Index > 1 then
			Read = Read:Branch("Conditional", "Index", `{Index - 1}`, "Equals")
		end

		Read:Line(`{Variable} = "{EnumItem}"`)
	end
	Read:Branch("Default"):Line(`error(\`Unexpected enum: \{Index\}\`)`):End()

	--> Write body
	local Allocation = Write:Allocate(1)
	for Index, EnumItem in Enums do
		if Index == 1 then
			Write = Write:Compare(Variable, `"{EnumItem}"`, "Equals")
		else
			Write = Write:Branch("Conditional", Variable, `"{EnumItem}"`, "Equals")
		end

		Write:Line(`buffer.writeu8(SendBuffer, {Allocation}, {Index - 1})`)
	end
	Write:Branch("Default"):Line(`error(\`Unexpected enum: \{{Variable}\}, expected one of {Literal}.\`)`):End()
end

function Serde.Map(Declaration: Parser.Map, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local MapValue = Declaration.Value
	local Key = MapValue.Values[1]
	local Value = MapValue.Values[2]

	local KeyVariable = `Key_{Read.Indent}`
	local ElementVariable = `Element_{Write.Indent}`
	local ElementsVariable = `Elements_{Write.Indent}`
	local ElementsAllocation = Write:Allocate(2)

	Read:Line(`{Read:Declare(Variable)} = \{\}`)
	Write:Line(`local {ElementsVariable} = 0`)
	Types.u16.Read(ElementsVariable, Read)

	local ReadLoop = Read:Loop("_ = 1", ElementsVariable)
	local WriteLoop = Write:Iterator(KeyVariable, ElementVariable, Variable)

	--> Maps are unsafe
	ReadLoop:DisableOperationOptimisations()
	WriteLoop:DisableOperationOptimisations()

	--ReadLoop:Line(`local Key: {KeyType}, Element: {ValueType};`)
	WriteLoop:Line(`{ElementsVariable} += 1`)
	Serde.Emit(Key :: Type, ReadLoop, WriteLoop, KeyVariable)
	Serde.Emit(Value :: Type, ReadLoop, WriteLoop, ElementVariable)
	ReadLoop:Line(`{Variable}[{KeyVariable}] = {ElementVariable}`)

	WriteLoop:End()
	ReadLoop:End()

	Write:Line(`buffer.writeu16(SendBuffer, {ElementsAllocation}, {ElementsVariable})`)
end

function Serde.Struct(Declaration: Parser.Struct, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	Read:Line(`{Read:Declare(Variable)} = \{\} :: any`)

	for _, Field in Value.Values do
		local Name = Field.Name
		local FieldVariable = `{Variable}{FormatIndex(Name)}`
		Serde.Emit(Field :: Type, Read, Write, FieldVariable)
	end
end

function Serde.Tuple(Declaration: Parser.Tuple, Read: Blocks.Block, Write: Blocks.Block)
	local Names = Declaration.Value.Names
	for Index, Value in Declaration.Value.Values do
		local Variable = Names[Index] or `Value{Index}`
		Serde.Emit(Value :: Type, Read, Write, Variable)
	end
end

function Serde.TagEnum(Declaration: Parser.TagEnum, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Values = Value.Values

	--> Body
	local Tag = Value.Tag
	local Header = `"{Values[1].Name}"`
	local TagIndex = `{Variable}{FormatIndex(Tag)}`

	Types.u8.Read(`Tag`, Read)
	Read:Line(`{Read:Declare(Variable)} = true :: any`)

	local Allocation = Write:Allocate(1)

	Read = Read:Compare("Tag", "0", "Equals")
	Write = Write:Compare(TagIndex, Header, "Equals")

	for Index, Variant in Values do
		local Name = `"{Variant.Name}"`
		if Index > 1 then
			Read = Read:Branch("Conditional", "Tag", tostring(Index - 1), "Equals")
			Write = Write:Branch("Conditional", TagIndex, Name, "Equals")
		end

		Write:_lineFront(`buffer.writeu8(SendBuffer, {Allocation}, {Index - 1})`)
		Write:Advance(1)

		Serde.Emit(Variant, Read, Write, Variable)
		Read:Line(`{TagIndex} = {Name}`)
	end

	Read:Branch("Default"):Line(`error(\`Unexpected variant: \{Tag\}\`)`):End()

	Write:Branch("Default"):Line(`error(\`Unexpected variant: \{{TagIndex}\}\`)`):End()
end
--- An array of plain booleans, eight to a byte, least significant bit first like `Block.Bit`.
---
--- A loop body is a block of its own, so the generic path gave every element a bitfield of its own:
--- one byte per boolean. Here the whole array is one run of bytes. A variable length reserves its
--- run at runtime, after the block's fixed bytes, the way a string does; a fixed one reserves it in
--- the block. Each side runs in a `do` scope, so two such arrays in one struct do not redeclare.
function Serde.PackedBooleans(Read: Blocks.Block, Write: Blocks.Block, Variable: string, Fixed: number?)
	local Bytes = if Fixed then math.ceil(Fixed / 8) else nil
	if Bytes == 0 then
		return
	end

	--> Taken before the scopes open: in a loop body `_operation` emits the offset's declaration.
	local ReadOffset = if Bytes then Read:Read(Bytes) else "Read((Length + 7) // 8)"
	local WriteOffset = if Bytes then Write:Allocate(Bytes) else "Allocate((PACKED_LENGTH + 7) // 8)"

	Read:Line("do")
	Read:Line(`\tlocal PACKED_OFFSET = {ReadOffset}`)
	Read:Line("\tlocal PACKED_BITS = 0")
	Read:Line("\tfor Index = 0, Length - 1 do")
	Read:Line("\t\tif Index % 8 == 0 then")
	Read:Line("\t\t\tPACKED_BITS = buffer.readu8(RecieveBuffer, PACKED_OFFSET + Index // 8)")
	Read:Line("\t\tend")
	Read:Line(`\t\ttable.insert({Variable}, bit32.btest(PACKED_BITS, bit32.lshift(1, Index % 8)))`)
	Read:Line("\tend")
	Read:Line("end")

	Write:Line("do")
	Write:Line(`\tlocal PACKED_LENGTH = {Fixed or `#{Variable}`}`)
	Write:Line(`\tlocal PACKED_OFFSET = {WriteOffset}`)
	Write:Line("\tlocal PACKED_BITS = 0")
	Write:Line("\tfor Index = 0, PACKED_LENGTH - 1 do")
	Write:Line(`\t\tlocal PACKED_ITEM = {Variable}[Index + 1]`)
	if Serde.Options.WriteValidations then
		Write:Line(
			`\t\tif typeof(PACKED_ITEM) ~= "boolean" then error(\`Expected {Variable}[\{Index + 1}] to be of type boolean, got \{type(PACKED_ITEM)} instead.\`) end`
		)
	end
	Write:Line("\t\tif PACKED_ITEM then")
	Write:Line("\t\t\tPACKED_BITS += bit32.lshift(1, Index % 8)")
	Write:Line("\t\tend")
	Write:Line("\t\tif Index % 8 == 7 then")
	Write:Line("\t\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + Index // 8, PACKED_BITS)")
	Write:Line("\t\t\tPACKED_BITS = 0")
	Write:Line("\t\tend")
	Write:Line("\tend")
	Write:Line("\tif PACKED_LENGTH % 8 ~= 0 then")
	Write:Line("\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + PACKED_LENGTH // 8, PACKED_BITS)")
	Write:Line("\tend")
	Write:Line("end")
end

function Serde.Array(Declaration: Parser.Array, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Of = Value.Of
	local Range = Value.Range :: NumberRange

	Read:Comment("START ARRAY")
	Write:Comment("START ARRAY")

	local Lower = Range.Min
	local Upper = Range.Max

	local Iterator = `Item_{Read.Indent}`
	local IsVariableSize = (Lower ~= Upper)

	--> Length
	if IsVariableSize then
		--> Encoded RELATIVE to the declared minimum, in the smallest numeral that can hold the span.
		--> `u8[300..400]` needs one byte for a hundred possible lengths, not the two that 400 would
		--> otherwise demand -- and a length below the minimum can no longer be written at all.
		local Span = (Upper - Lower)
		local LengthType = Prefabs.GetTypeToUse(Span)
		local Assert = Prefabs.Asserts.number("Length", Lower, Upper)

		if Lower > 0 then
			LengthType.Read("LengthOffset", Read)
			Read:Line(`local Length = LengthOffset + {Lower}`)
		else
			LengthType.Read("Length", Read)
		end

		Read:Line(Assert.Lower)
		Read:Line(Assert.Upper)

		if Lower > 0 then
			--> Checked on the SEND side too, and unconditionally. An array shorter than the minimum
			--> would otherwise encode as a negative offset, wrap to a large unsigned value, and fail
			--> on the receiver as a length violation that names neither the array nor the sender.
			local WriteAssert = Prefabs.Asserts.number(`#{Variable}`, Lower, Upper)
			Write:Line(WriteAssert.Lower)
			Write:Line(WriteAssert.Upper)
			Write:Line(`local LengthOffset = #{Variable} - {Lower}`)
			LengthType.Write("LengthOffset", Write)
		else
			LengthType.Write(`#{Variable}`, Write)
		end
	else
		Read:Line(`local Length = {Upper}`)
	end

	--> Array
	if IsVariableSize then
		Prefabs.EmitCapacityGuard(Read, "Length", Variable, Of)
	end
	Read:Line(`{Read:Declare(Variable)} = table.create(Length)`)

	if Size.PacksBooleans(Of :: any) then
		Serde.PackedBooleans(Read, Write, Variable, if IsVariableSize then nil else Upper)
		Read:Comment("END ARRAY")
		Write:Comment("END ARRAY")
		return
	end

	--> Body
	Read = Read:Loop("Index = 1", "Length")
	Write = Write:Loop("Index = 1", IsVariableSize and `#{Variable}` or Upper)

	Write:Line(`local {Iterator} = {Variable}[Index]`)
	Serde.Emit(Of, Read, Write, Iterator)

	Read:Line(`table.insert({Variable}, {Iterator})`)

	--> End
	Read = Read:End()
	Write = Write:End()

	Read:Comment("END ARRAY")
	Write:Comment("END ARRAY")
end

function Serde.Optional(Declaration: Parser.Optional, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	Read:Declare(Variable, true)

	local Of = Declaration.Value.Of
	local IsInstance = if Of.Type == "Primitive" then Of.Tokens.Primitive.Value == "Instance" else false

	if IsInstance then
		Read:Line("RecieveInstanceCursor += 1")
		Read = Read:Compare("typeof(RecieveInstances[RecieveInstanceCursor])", '"Instance"', "Equals")
		Read:Line("RecieveInstanceCursor -= 1")
	else
		--> The presence flag is one BIT, sharing a byte with any other flags and booleans in the same
		--> block. It is claimed on both sides before the payload branch, so read and write reserve the
		--> same byte at the same offset.
		local WriteAccumulator, WriteMask = Write:Bit("Allocate")
		Write:Line(`if {Variable} ~= nil then {WriteAccumulator} += {WriteMask} end`)

		local ReadAccumulator, ReadMask = Read:Bit("Read")
		Read = Read:Compare(`bit32.btest({ReadAccumulator}, {ReadMask})`, "true", "Equals")
		Write = Write:Compare(Variable, "nil", "Not")
	end

	Serde.Emit(Declaration.Value.Of, Read, Write, Variable)
	Read:End()

	if not IsInstance then
		Write:End()
	end
end

return Serde
