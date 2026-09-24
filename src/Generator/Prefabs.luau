--!strict
--!native
--!optimize 2

local Blocks = require("./Blocks")
local Parser = require("../Parser")
local Size = require("../Modules/Size")

type Block = Blocks.Block
--> The compiler's range table, not Roblox's NumberRange userdata (which does not exist on Lune).
type NumberRange = Parser.NumberRange
type Writer = (Value: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Reader = (Variable: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Generate = (
	Declaration: Parser.Primitive,
	Variable: string?,
	Read: Block,
	Write: Block,
	WriteValidations: boolean?
) -> ()

type TypePrefab = {
	Read: Reader,
	Write: Writer,
	--> Set when the reader checks the decoded length itself, before the read. The generic post-read
	--> assert in `GenerateValidation` would then be a second copy of a check that has already passed.
	ValidatesOnRead: boolean?,
}

type AssertPrefab = {
	Lower: string,
	Upper: string,
	Exact: string?,
}

type AssertGenerator = (Variable: string, ...any) -> AssertPrefab

local SEND_BUFFER = "SendBuffer"
local RECIEVE_BUFFER = "RecieveBuffer"
local RECIEVE_CURSOR = "RecieveCursor"
local SEND_POSITION = "SendOffset"

local BYTE = 1
local SHORT = 2
local INTEGER = 4
local HALF_FLOAT = 2
local FLOAT = 4
local DOUBLE = 8

local Types = {}
local Asserts = {
	--> Written as `not (x >= Min)` rather than `x < Min`, here and for vectors: NaN compares false
	--> against everything, so `x < Min` and `x > Max` both let it through, and a client could hand a
	--> ranged float listener a NaN that every check downstream had been told was impossible.
	number = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min}) then error(\`Expected "{Variable}" to be larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max}) then error(\`Expected "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if {Variable} ~= {Max} then error(\`Expected "{Variable}" to be equal to {Max}, got \{{Variable}\} instead.\`) end`,
		}
	end,

	string = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		--> `Measure` names the expression to compare. The read path passes the decoded length so the
		--> bound is checked before the string is read; the write path omits it and measures the value.
		local Length = Measure or `#{Variable}`
		return {
			Lower = `if {Length} < {Min} then error(\`Expected length of "{Variable}" to be larger than or equal to {Min}, got \{{Length}} instead.\`) end`,
			Upper = `if {Length} > {Max} then error(\`Expected length of "{Variable}" to be smaller than or equal to {Max}, got \{{Length}} instead.\`) end`,
			Exact = `if {Length} ~= {Max} then error(\`Expected length of "{Variable}" to equal to {Max}, got \{{Length}} instead.\`) end`,
		}
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable}.Magnitude >= {Min}) then error(\`Expected magnitude of "{Variable}" to be larger than or equal to {Min}, got \{{Variable}.Magnitude} instead.\`) end`,
			Upper = `if not ({Variable}.Magnitude <= {Max}) then error(\`Expected magnitude of "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			Exact = `if {Variable}.Magnitude ~= {Max} then error(\`Expected magnitude of "{Variable}" to equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
		}
	end,

	buffer = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		--> See the note on `Asserts.string` for what `Measure` is for.
		local Length = Measure or `buffer.len({Variable})`
		return {
			Lower = `if {Length} < {Min} then error(\`Expected size of "{Variable}" to be larger than or equal to {Min}, got \{{Length}} instead.\`) end`,
			Upper = `if {Length} > {Max} then error(\`Expected size of "{Variable}" to be smaller than or equal to {Max}, got \{{Length}} instead.\`) end`,
			Exact = `if {Length} ~= {Max} then error(\`Expected size of "{Variable}" to equal to {Max}, got \{{Length}} instead.\`) end`,
		}
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Something has gone wrong")`,
			Upper = `error("Something has gone wrong")`,
			Exact = if Class == "Instance"
				then TypeAssertion
				else `{TypeAssertion}\nif not {Variable}:IsA("{Class}") then error(\`Expected an Instance of type "{Class}", got "\{{Variable}.ClassName}" instead.\`) end`,
		}
	end,
}
local Structures = {
	Array = nil :: any,
}
local Primitives: { [string]: {
	Type: string | (Declaration: Parser.Primitive) -> string,
	Generate: Generate,
} } = {}

local NumberTypeBounds = {
	{ Bits = 8, Maximum = 255, Type = "u8" },
	{ Bits = 16, Maximum = 65535, Type = "u16" },
	{ Bits = 32, Maximum = 4294967295, Type = "u32" },
}

local function GetTypeToUse(UpperSize: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Maximum >= UpperSize then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

--> A length read out of a hostile packet may name more bytes than the packet still holds. Reading
--> that far throws inside `buffer.read*` and the decode loop's pcall turns it into a dropped packet,
--> but `buffer` would have allocated the whole span first. Checking the remaining space keeps a
--> length prefix from buying an allocation, and it is exact rather than conservative: block reads
--> reserve their fixed bytes up front, so at this point the cursor sits where the payload begins.
local function GenerateSpaceGuard(Length: string, Variable: string): string
	return `if {Length} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
end

--- Emits a guard on a decoded element count, before the array behind it is allocated.
---
--- `table.create(Length)` reserves every slot up front, so a count the packet cannot possibly back
--- still buys that allocation even though the loop fails on its first iteration: two bytes reserve
--- 65535 slots, and `u8[]` is enough to ask for them. Comparing the count against what is left of
--- whatever its elements read closes that.
---
--- The comparison uses the MINIMUM an element costs, which is the most that can be assumed about
--- it, so the guard errs towards letting a packet through rather than refusing an honest one. An
--- element that costs nothing either way is refused at compile time instead -- there is no resource
--- left to measure it against.
local function EmitCapacityGuard(Block: Block, Length: string, Variable: string, Of: Parser.TypeNode)
	--> A packed boolean costs an eighth of a byte, which the per-element minimum below would round up
	--> to one -- and then refuse an honest 800-element array for not fitting in its 100 bytes.
	if Size.PacksBooleans(Of :: any) then
		Block:Line(
			`if ({Length} + 7) // 8 > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	local Element = Size.Sealed(Of :: any)

	if Element.Min > 0 then
		local Needed = if Element.Min == 1 then Length else `{Length} * {Element.Min}`
		Block:Line(
			`if {Needed} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	if Element.Refs > 0 then
		local Needed = if Element.Refs == 1 then Length else `{Length} * {Element.Refs}`
		Block:Line(
			`if {Needed} > #RecieveInstances - RecieveInstanceCursor then error(\`Expected "{Variable}" to fit in the \{#RecieveInstances - RecieveInstanceCursor} values left beside the packet, got a length of \{{Length}} instead.\`) end`
		)
	end
end

local function GetTypeToUseByBits(UpperBits: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Bits >= UpperBits then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GeneratePrimitivePrefab(Type: string, Prefab: TypePrefab, AssertGenerator: AssertGenerator?): Generate
	return function(
		Declaration: Parser.Primitive,
		Variable: string?,
		Read: Block,
		Write: Block,
		WriteValidations: boolean?
	)
		local Value = Declaration.Value
		local Tokens = Declaration.Tokens
		local Target = Variable or "Value"

		local Range = Value.Range
		local Class = Value.Class
		local Components = Value.Components
		local Primitive = Tokens.Primitive.Value
		local IsVariableSize = (Range and Range.Max ~= Range.Min)

		local function GenerateValidation(Block: Block, TargetVariable: string)
			if Block == Write and WriteValidations ~= true then
				return
			end

			--> The reader has already asserted the decoded length, and a read of `Length` bytes
			--> yields exactly `Length` bytes, so measuring the value again tests an identity.
			if Block == Read and Prefab.ValidatesOnRead and Range and IsVariableSize then
				return
			end

			if Block == Write and Type ~= "any" then
				Block:Compare(`typeof({TargetVariable})`, `"{Type}"`, "Not")
					:Line(
						`error(\`Expected {TargetVariable} to be of type {Type}, got \{type({TargetVariable})} instead.\`)`
					)
					:End()
			end

			if not AssertGenerator then
				return
			end

			if Range then
				local Assert = AssertGenerator(TargetVariable, Range.Min, Range.Max)
				if not IsVariableSize and Assert.Exact then
					Block:Line(Assert.Exact)
				else
					--> An open side of a float range is infinite, and every value passes it. Its line is
					--> left out rather than emitted, since `inf` would read as a nil global. NaN is still
					--> refused, because the side that remains is written `not (x >= Min)`.
					if Range.Min ~= -math.huge then
						Block:Line(Assert.Lower)
					end
					if Range.Max ~= math.huge then
						Block:Line(Assert.Upper)
					end
				end
			elseif Primitive == "Instance" and Class then
				local Assert = AssertGenerator(TargetVariable, Class)
				--> `Exact` is optional on AssertPrefab because range asserts may omit it; the Instance
				--> generator always sets it. Reading it into a local narrows the type without a cast.
				local Exact = Assert.Exact
				if Exact then
					if Block == Write then
						Block:Compare(TargetVariable, "nil", "Not"):Multiline(Exact, Block.Indent + 1):End()
					else
						Block:Multiline(Exact, Block.Indent)
					end
				end
			end
		end

		GenerateValidation(Write, Target)
		Prefab.Read(Target, Read, Range, Components)
		Prefab.Write(Target, Write, Range, Components)
		GenerateValidation(Read, Target)
	end
end

local function GenerateNumberGenerator(Type: string, Bytes: number): (TypePrefab, { Type: string, Generate: Generate })
	local Prefab = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`{Block:Declare(Variable)} = buffer.read{Type}({RECIEVE_BUFFER}, {Block:Read(Bytes)})`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`buffer.write{Type}({SEND_BUFFER}, {Block:Allocate(Bytes)}, {Value})`)
		end,
	}

	local Primitive = {
		Type = "number",
		Generate = GeneratePrimitivePrefab("number", Prefab, Asserts.number),
	}

	return Prefab, Primitive
end

--> Numbers
Types.u8, Primitives.u8 = GenerateNumberGenerator("u8", BYTE)
Types.u16, Primitives.u16 = GenerateNumberGenerator("u16", SHORT)
Types.u32, Primitives.u32 = GenerateNumberGenerator("u32", INTEGER)

Types.i8, Primitives.i8 = GenerateNumberGenerator("i8", BYTE)
Types.i16, Primitives.i16 = GenerateNumberGenerator("i16", SHORT)
Types.i32, Primitives.i32 = GenerateNumberGenerator("i32", INTEGER)

Types.f32, Primitives.f32 = GenerateNumberGenerator("f32", FLOAT)
Types.f64, Primitives.f64 = GenerateNumberGenerator("f64", DOUBLE)

Types.f16 = {
	Read = function(Variable: string, Block: Block)
		Types.u16.Read("Encoded", Block)
		Block:Declare(Variable, true)
		Block:Line(`local MantissaExponent = Encoded % 0x8000`)
		Block:Compare("MantissaExponent", "0b0_11111_0000000000 ", "Equals")
			:Compare("Encoded // 0x8000", "1", "Equals")
			:Line(`{Variable} = -math.huge`)
			:Branch("Default")
			:Line(`{Variable} = math.huge`)
			:End()
			:Branch("Conditional", "MantissaExponent", "0b1_11111_0000000000  ", "Equals")
			:Line(`{Variable} = 0 / 0`)
			:Branch("Conditional", "MantissaExponent", "0b0_00000_0000000000  ", "Equals")
			:Line(`{Variable} = 0`)
			:Branch("Default")
			:Lines({
				"local Mantissa = MantissaExponent % 0x400\n",
				"local Exponent = MantissaExponent // 0x400\n",
				"local Fraction;\n",
				"if Exponent == 0 then\n",
				"	Fraction = Mantissa / 0x400\n",
				"else\n",
				"	Fraction = Mantissa / 0x800 + 0.5\n",
				"end\n",
				"local Result = math.ldexp(Fraction, Exponent - 14)\n",
			}, Block.Indent + 1)
			:Line(`{Variable} = if Encoded // 0x8000 == 1 then -Result else Result`)
			:End()
	end,
	Write = function(Value: string, Block: Block)
		local Allocation = Block:Allocate(HALF_FLOAT)
		Block:Compare(Value, "65504", "Greater")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b0_11111_0000000000)`)
			:Branch("Conditional", Value, "-65504", "Less")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000000)`)
			:Branch("Conditional", Value, Value, "Not")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000001)`)
			:Branch("Conditional", Value, "0", "Equals")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0)`)
			:Branch("Default")
			:Line(`local float = {Value}`)
			:Lines({
				"local Abosulte = math.abs(float)\n",
				"local Interval = math.ldexp(1, math.floor(math.log(Abosulte, 2)) - 10)\n",
				"local RoundedValue = (Abosulte // Interval) * Interval\n",
				"local Fraction, Exponent = math.frexp(RoundedValue)\n",
				"Exponent += 14\n",
				"local Mantissa = math.round(if Exponent <= 0\n",
				"	then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent))\n",
				"	else Fraction * 0x800) % 0x400\n",
				"local Result = Mantissa\n",
				"	+ math.max(Exponent, 0) * 0x400\n",
				"	+ if float < 0 then 0x8000 else 0\n",
			}, Block.Indent + 1)
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, Result)`)
			:End()
	end,
}

Primitives.f16 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f16, Asserts.number),
}

--> Boolean
do
	--> One BIT, not one byte. Eight booleans in the same block share a byte; see `Block.Bit`.
	Types.boolean = {
		Read = function(Variable: string, Block: Block)
			local Accumulator, Mask = Block:Bit("Read")
			Block:Line(`{Block:Declare(Variable)} = bit32.btest({Accumulator}, {Mask})`)
		end,
		Write = function(Value: string, Block: Block)
			local Accumulator, Mask = Block:Bit("Allocate")
			Block:Line(`if {Value} then {Accumulator} += {Mask} end`)
		end,
	}

	Primitives.boolean = {
		Type = "boolean",
		Generate = GeneratePrimitivePrefab("boolean", Types.boolean),
	}
end

--> String
do
	Types.string = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			--> Fixed size string
			if Range and Range.Min == Range.Max then
				Block:Line(
					`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, {Block:Read(Range.Min)}, {Range.Min})`
				)
				return
			end

			--> The length is encoded RELATIVE to the declared minimum, in the smallest numeral that
			--> holds the span: `string(300..400)` spends one byte on a hundred possible lengths rather
			--> than the two that 400 alone would need.
			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local Lower = Range and Range.Min or 0
			local LengthType = GetTypeToUse(Upper - Lower)

			if Lower > 0 then
				LengthType.Read("LengthOffset", Block)
				Block:Line(`local Length = LengthOffset + {Lower}`)
			else
				LengthType.Read("Length", Block)
			end

			--> Checked before the read, and against the reconstructed length rather than the raw
			--> numeral: the prefix is sized from the span, so `string(300..400)` fits a u8 whose 255
			--> decodes to 555. The bound named here is the one the schema author actually wrote.
			if Range then
				local Assert = Asserts.string(Variable, Lower, Upper, "Length")
				Block:Line(Assert.Lower)
				Block:Line(Assert.Upper)
			end

			Block:Line(GenerateSpaceGuard("Length", Variable))

			Block:Line(`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.writestring({SEND_BUFFER}, {Block:Allocate(Range.Min)}, {Value}, {Range.Min})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local Lower = Range and Range.Min or 0
			local LengthType = GetTypeToUse(Upper - Lower)

			Block:Line(`local Length = #{Value}`)

			if Lower > 0 then
				--> Checked on send, unconditionally: a string shorter than the minimum would encode as
				--> a negative offset, wrap to a large unsigned value, and fail on the receiver as a
				--> length violation that names neither the field nor the sender.
				local Assert = Asserts.number("Length", Lower, Upper)
				Block:Line(Assert.Lower)
				Block:Line(Assert.Upper)
				Block:Line(`local LengthOffset = Length - {Lower}`)
				LengthType.Write("LengthOffset", Block)
			else
				LengthType.Write("Length", Block)
			end

			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.writestring({SEND_BUFFER}, {SEND_POSITION}, {Value}, Length)`)
		end,

		ValidatesOnRead = true,
	}

	Primitives.string = {
		Type = "string",
		Generate = GeneratePrimitivePrefab("string", Types.string, Asserts.string),
	}
end

--> Vector
do
	Types.vector = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Read("X", Block)
			Prefab.Read("Y", Block)
			Prefab.Read("Z", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector3.new(X, Y, Z)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Block:Line(`local Vector = {Value}`)
			Prefab.Write("Vector.X", Block)
			Prefab.Write("Vector.Y", Block)
			Prefab.Write("Vector.Z", Block)
		end,
	}

	Primitives.vector = {
		Type = "Vector3",
		Generate = GeneratePrimitivePrefab("Vector3", Types.vector, Asserts.vector),
	}
end

--> Buffer
do
	Types.buffer = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				local Length = Range.Max
				Block:Line(`{Block:Declare(Variable)} = buffer.create({Length})`)
				Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, {Block:Read(Length)}, {Length})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local Lower = Range and Range.Min or 0
			local LengthType = GetTypeToUse(Upper - Lower)

			if Lower > 0 then
				LengthType.Read("LengthOffset", Block)
				Block:Line(`local Length = LengthOffset + {Lower}`)
			else
				LengthType.Read("Length", Block)
			end

			--> Checked before the read, and against the reconstructed length rather than the raw
			--> numeral: the prefix is sized from the span, so `string(300..400)` fits a u8 whose 255
			--> decodes to 555. The bound named here is the one the schema author actually wrote.
			if Range then
				local Assert = Asserts.buffer(Variable, Lower, Upper, "Length")
				Block:Line(Assert.Lower)
				Block:Line(Assert.Upper)
			end

			Block:Line(GenerateSpaceGuard("Length", Variable))

			Block:Line(`{Block:Declare(Variable)} = buffer.create(Length)`)
			Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.copy({SEND_BUFFER}, {Block:Allocate(Range.Max)}, {Value}, 0, {Range.Max})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local Lower = Range and Range.Min or 0
			local LengthType = GetTypeToUse(Upper - Lower)

			Block:Line(`local Length = buffer.len({Value})`)

			if Lower > 0 then
				local Assert = Asserts.number("Length", Lower, Upper)
				Block:Line(Assert.Lower)
				Block:Line(Assert.Upper)
				Block:Line(`local LengthOffset = Length - {Lower}`)
				LengthType.Write("LengthOffset", Block)
			else
				LengthType.Write("Length", Block)
			end

			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.copy({SEND_BUFFER}, {SEND_POSITION}, {Value}, 0, Length)`)
		end,

		ValidatesOnRead = true,
	}

	Primitives.buffer = {
		Type = "buffer",
		Generate = GeneratePrimitivePrefab("buffer", Types.buffer, Asserts.buffer),
	}
end

--> CFrame
do
	Types.CFrame = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Read("Position", Block, nil, Components)
			Prefab.Read("rX", Block)
			Prefab.Read("rY", Block)
			Prefab.Read("rZ", Block)
			Block:Line(`{Block:Declare(Variable)} = CFrame.new(Position) * CFrame.fromOrientation(rX, rY, rZ)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Write(`{Value}.Position`, Block, nil, Components)
			Block:Line(`local rX, rY, rZ = {Value}:ToOrientation()`)
			Prefab.Write("rX", Block)
			Prefab.Write("rY", Block)
			Prefab.Write("rZ", Block)
		end,
	}

	Primitives.CFrame = {
		Type = "CFrame",
		Generate = GeneratePrimitivePrefab("CFrame", Types.CFrame),
	}
end

--> Color3
do
	Types.Color3 = {
		Read = function(Variable: string, Block: Block)
			local R = Block:Read(BYTE)
			local G = Block:Read(BYTE)
			local B = Block:Read(BYTE)
			Block:Line(
				`{Block:Declare(Variable)} = Color3.fromRGB(buffer.readu8({RECIEVE_BUFFER}, {R}), buffer.readu8({RECIEVE_BUFFER}, {G}), buffer.readu8({RECIEVE_BUFFER}, {B}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			--> Rounded, not truncated, and clamped: `writeu8` keeps the low byte, so an HDR channel of
			--> 2.0 -- which Highlight and neon colours use -- wrapped to 254, and a negative one to near
			--> 255. A channel written as 127.5 now reaches the other side as 128 rather than 127.
			Block:Line(`local Color = {Value}`)
			Types.u8.Write("math.clamp(math.round(Color.R * 255), 0, 255)", Block)
			Types.u8.Write("math.clamp(math.round(Color.G * 255), 0, 255)", Block)
			Types.u8.Write("math.clamp(math.round(Color.B * 255), 0, 255)", Block)
		end,
	}

	Primitives.Color3 = {
		Type = "Color3",
		Generate = GeneratePrimitivePrefab("Color3", Types.Color3),
	}
end

--> DateTime
do
	Types.DateTime = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestamp = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestamp(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestamp}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTime = {Value}`)
			Types.f64.Write(`DateTime.UnixTimestamp`, Block)
		end,
	}

	Primitives.DateTime = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTime),
	}
end

--> DateTimeMillis
do
	Types.DateTimeMillis = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestampMillis = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestampMillis(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestampMillis}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTimeMillis = {Value}`)
			Types.f64.Write(`DateTimeMillis.UnixTimestampMillis`, Block)
		end,
	}

	Primitives.DateTimeMillis = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTimeMillis),
	}
end

--> BrickColor
do
	Types.BrickColor = {
		Read = function(Variable: string, Block: Block)
			local Number = Block:Read(SHORT)
			Block:Line(`{Block:Declare(Variable)} = BrickColor.new(buffer.readu16({RECIEVE_BUFFER}, {Number}))`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local BrickColor = {Value}`)
			Types.u16.Write("BrickColor.Number", Block)
		end,
	}

	Primitives.BrickColor = {
		Type = "BrickColor",
		Generate = GeneratePrimitivePrefab("BrickColor", Types.BrickColor),
	}
end

--> Instance
do
	Types.Instance = {
		Read = function(Variable: string, Block: Block)
			--Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, {Value} or Null)`)
		end,
	}

	Primitives.Instance = {
		Type = function(Declaration)
			--> The parser defaults an Instance without an explicit class to "Instance", so this is never
			--> nil in practice; the fallback states that instead of asserting it.
			return Declaration.Value.Class or "Instance"
		end,
		Generate = GeneratePrimitivePrefab("any", Types.Instance, Asserts.Instance),
	}
end

--> unknown
do
	Types.unknown = {
		Read = function(Variable: string, Block: Block)
			Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
			--> The sender substitutes `Null` for a nil, so a nil here is never a value the client
			--> meant to send -- it means the packet claimed more of them than it carried. Unlike an
			--> `Instance`, whose class check fails on the same condition, `unknown` accepts anything
			--> and would otherwise let a decode loop run on a table that ran out long ago.
			Block:Line(
				`if {Variable} == nil then error(\`Expected a value for "{Variable}", the packet carried only \{#RecieveInstances} of them.\`) end`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, if {Value} == nil then Null else {Value})`)
		end,
	}

	Primitives.unknown = {
		Type = "any",
		Generate = GeneratePrimitivePrefab("any", Types.unknown),
	}
end

return {
	Types = Types,
	Asserts = Asserts,
	EmitCapacityGuard = EmitCapacityGuard,
	Primitives = Primitives,
	Structures = Structures,
	GetTypeToUse = GetTypeToUse,
	GetTypeToUseByBits = GetTypeToUseByBits,
}
