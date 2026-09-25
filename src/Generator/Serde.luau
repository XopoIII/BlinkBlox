--!strict
--- How each kind of type is read from and written to a buffer. One function per node the parser can
--- produce, each emitting into a Read block and a Write block.
---
--- Split out of Generator/init.luau when that file was over its size limit.
--- These were the obvious piece to move: of everything in that file they reach for the least of its
--- state. Two things they do need are injected rather than required, because the dependency runs
--- both ways -- the generator dispatches into these, and a struct or an array has to dispatch back
--- out to whatever its fields are. The options the run is under are read from State.luau.
local Parser = require("../Parser")
local Size = require("../Modules/Size")

local Blocks = require("./Blocks")
local Prefabs = require("./Prefabs")
local Scope = require("./Scope")
local State = require("./State")
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

--- The two the generator defines on this table rather than here. An event or a function is not a
--- type on the wire -- emitting one needs scopes, builders, casing and the channel counters, all of
--- which are that file's state. Declared so the table is not sealed against them.
Serde.Event = (nil :: any) :: (Declaration: Parser.Event) -> ()
Serde.Function = (nil :: any) :: (Declaration: Parser.Function) -> ()

function Serde.Primitive(Declaration: Parser.Primitive, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Tokens = Declaration.Tokens
	local Primitive = Tokens.Primitive.Value
	local Generator = Primitives[Primitive]
	Generator.Generate(Declaration, Variable, Read, Write, State.Options.WriteValidations)
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

				--> A flag is a table field, never a local, so nothing is declared for it. It used to be
				--> recorded as a declared variable, and a reader after it that declares a local of the
				--> same name -- a string's `Length`, an enum's `Index` -- then assigned a global instead.
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

	--> The count is a u16 and nothing bounds a map in the schema, so one past 65535 entries would go
	--> out as its low sixteen bits in front of every entry. See Prefabs.EmitLengthGuard.
	Prefabs.EmitLengthGuard(Write, 0, Size.MapLength, ElementsVariable)
	Write:Line(`buffer.writeu16(SendBuffer, {ElementsAllocation}, {ElementsVariable})`)
end

--- A decoded struct is created with a slot for every field its reader always assigns, rather than
--- empty: a table built as `{}` and then given six fields rehashed four times on the way, 0 to 1 to
--- 2 to 4 to 8, and that measured five times the cost of one made at its size -- the most expensive
--- line of the server's decode loop for an array of structs. The placeholders are written over at
--- once. An optional field gets none, because its reader assigns nothing when the value is absent
--- and a placeholder would then be decoded as a value.
function Serde.Struct(Declaration: Parser.Struct, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value

	local Slots = {}
	for _, Field in Value.Values do
		if Field.Type ~= "Optional" then
			local Name = Field.Name
			table.insert(Slots, if Util.IsValidIdentifier(Name) then `{Name} = false` else `["{Name}"] = false`)
		end
	end

	Read:Line(`{Read:Declare(Variable)} = \{{table.concat(Slots, ", ")}\} :: any`)

	--> Each field in a scope of its own, so that its locals end with it; see Scope.luau.
	for _, Field in Value.Values do
		local Name = Field.Name
		local FieldVariable = `{Variable}{FormatIndex(Name)}`
		Scope(Read, function()
			Scope(Write, function()
				Serde.Emit(Field :: Type, Read, Write, FieldVariable)
			end)
		end)
	end
end

--- A pack's elements are serialised under positional names, never the ones the schema gave them; see
--- `Generators.LuauType`.
function Serde.Tuple(Declaration: Parser.Tuple, Read: Blocks.Block, Write: Blocks.Block)
	for Index, Value in Declaration.Value.Values do
		Serde.Emit(Value :: Type, Read, Write, `Value{Index}`)
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
---
--- Both sides go a byte at a time, eight elements unrolled against constant masks, and finish the
--- last partial byte with a short loop. The loop they replace went an element at a time and paid a
--- modulo, a shift and a branch for every boolean -- a million of them a frame at the benchmark's
--- load -- and the reader appended each one with `table.insert`.
---
--- The writer loads a byte's eight elements into locals before it branches on any of them, and
--- under WriteValidations checks their types in the same pass rather than in a loop of its own.
--- Branching straight on `Value[i]` cost 13.5 ms a frame on random data against 3.8 on constant,
--- natively; through locals it is 7.8, and the validated writer went from 17.4 to 9.7. Truly
--- branchless forms (`v and k or 0`, a `{ [true] = 1 }` lookup) measured no better or worse.
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
	Read:Line("\tlocal PACKED_WHOLE = Length // 8")
	Read:Line("\tfor PACKED_BYTE = 0, PACKED_WHOLE - 1 do")
	Read:Line("\t\tlocal PACKED_BITS = buffer.readu8(RecieveBuffer, PACKED_OFFSET + PACKED_BYTE)")
	Read:Line("\t\tlocal PACKED_BASE = PACKED_BYTE * 8")
	for Bit = 0, 7 do
		Read:Line(`\t\t{Variable}[PACKED_BASE + {Bit + 1}] = bit32.btest(PACKED_BITS, {bit32.lshift(1, Bit)})`)
	end
	Read:Line("\tend")
	Read:Line("\tif Length % 8 ~= 0 then")
	Read:Line("\t\tlocal PACKED_BITS = buffer.readu8(RecieveBuffer, PACKED_OFFSET + PACKED_WHOLE)")
	Read:Line("\t\tlocal PACKED_BASE = PACKED_WHOLE * 8")
	Read:Line("\t\tfor PACKED_BIT = 0, Length % 8 - 1 do")
	Read:Line(`\t\t\t{Variable}[PACKED_BASE + PACKED_BIT + 1] = bit32.btest(PACKED_BITS, bit32.lshift(1, PACKED_BIT))`)
	Read:Line("\t\tend")
	Read:Line("\tend")
	Read:Line("end")

	local Validate = State.Options.WriteValidations
	local function Refuse(Indent: string, Index: string)
		Write:Line(
			`{Indent}if typeof(PACKED_ITEM) ~= "boolean" then error(\`Expected {Variable}[\{{Index}}] to be of type boolean, got \{type(PACKED_ITEM)} instead.\`) end`
		)
	end

	Write:Line("do")
	Write:Line(`\tlocal PACKED_LENGTH = {Fixed or `#{Variable}`}`)
	Write:Line(`\tlocal PACKED_OFFSET = {WriteOffset}`)
	Write:Line("\tlocal PACKED_WHOLE = PACKED_LENGTH // 8")
	Write:Line("\tfor PACKED_BYTE = 0, PACKED_WHOLE - 1 do")
	Write:Line("\t\tlocal PACKED_BASE = PACKED_BYTE * 8")
	local Items = {}
	for Bit = 1, 8 do
		Items[Bit] = `PACKED_{Bit}`
	end
	for Half = 0, 4, 4 do
		local Names = table.concat(Items, ", ", Half + 1, Half + 4)
		local Reads = {}
		for Bit = Half + 1, Half + 4 do
			table.insert(Reads, `{Variable}[PACKED_BASE + {Bit}]`)
		end
		Write:Line(`\t\tlocal {Names} = {table.concat(Reads, ", ")}`)
	end
	if Validate then
		--> One test for the byte on the hot path; which element failed is worked out only once one has.
		local Tests = {}
		for _, Item in Items do
			table.insert(Tests, `typeof({Item}) ~= "boolean"`)
		end
		Write:Line(`\t\tif {table.concat(Tests, " or ")} then`)
		Write:Line("\t\t\tfor PACKED_INDEX = PACKED_BASE + 1, PACKED_BASE + 8 do")
		Write:Line(`\t\t\t\tlocal PACKED_ITEM = {Variable}[PACKED_INDEX]`)
		Refuse("\t\t\t\t", "PACKED_INDEX")
		Write:Line("\t\t\tend")
		Write:Line("\t\tend")
	end
	Write:Line("\t\tlocal PACKED_BITS = 0")
	for Bit, Item in Items do
		Write:Line(`\t\tif {Item} then PACKED_BITS += {bit32.lshift(1, Bit - 1)} end`)
	end
	Write:Line("\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + PACKED_BYTE, PACKED_BITS)")
	Write:Line("\tend")
	Write:Line("\tif PACKED_LENGTH % 8 ~= 0 then")
	Write:Line("\t\tlocal PACKED_BASE = PACKED_WHOLE * 8")
	Write:Line("\t\tlocal PACKED_BITS = 0")
	Write:Line("\t\tfor PACKED_BIT = 0, PACKED_LENGTH % 8 - 1 do")
	Write:Line(`\t\t\tlocal PACKED_ITEM = {Variable}[PACKED_BASE + PACKED_BIT + 1]`)
	if Validate then
		Refuse("\t\t\t", "PACKED_BASE + PACKED_BIT + 1")
	end
	Write:Line("\t\t\tif PACKED_ITEM then PACKED_BITS += bit32.lshift(1, PACKED_BIT) end")
	Write:Line("\t\tend")
	Write:Line("\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + PACKED_WHOLE, PACKED_BITS)")
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

		--> Checked on the SEND side too, and unconditionally; see Prefabs.EmitLengthGuard.
		Prefabs.EmitLengthGuard(Write, Lower, Upper, `#{Variable}`)

		if Lower > 0 then
			Write:Line(`local LengthOffset = #{Variable} - {Lower}`)
			LengthType.Write("LengthOffset", Write)
		else
			LengthType.Write(`#{Variable}`, Write)
		end
	else
		Read:Line(`local Length = {Upper}`)

		--> A fixed length sends no prefix, so a longer array cannot corrupt the packet -- it is cut
		--> to its first elements, silently. Under WriteValidations that is refused instead. `#` is
		--> meaningless across an optional's holes, so there every index is checked.
		if State.Options.WriteValidations then
			if Of.Type == "Optional" then
				Write:Line(
					`for Key in {Variable} do if type(Key) == "number" and Key > {Upper} then error(\`Expected "{Variable}" to hold at most {Upper} elements, got one at index \{Key} instead.\`) end end`
				)
			else
				Write:Line(Prefabs.Asserts.string(Variable, Upper, Upper).Exact :: string)
			end
		end
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
	--> The reader's counter is named for its depth: an element's own reader may declare an `Index` of
	--> its own -- an enum does -- which would shadow a counter of that name before it is used below.
	local Slot = `Slot_{Read.Indent}`
	Read = Read:Loop(`{Slot} = 1`, "Length")
	Write = Write:Loop("Index = 1", IsVariableSize and `#{Variable}` or Upper)

	Write:Line(`local {Iterator} = {Variable}[Index]`)
	Serde.Emit(Of, Read, Write, Iterator)

	--> By index, not `table.insert`: an absent optional element is nil, and inserting nil does nothing,
	--> so every element after a hole used to arrive one place early.
	Read:Line(`{Variable}[{Slot}] = {Iterator}`)

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
