--!strict
--!native
--!optimize 2

--- Integers, floats, half floats and booleans.
local AssertsModule = require("./Asserts")
local Common = require("./Common")

type Block = Common.Block
type Generate = Common.Generate
type TypePrefab = Common.TypePrefab

local Types = Common.Types
local Primitives = Common.Primitives
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab
local SEND_BUFFER = Common.SEND_BUFFER
local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local BYTE = Common.BYTE
local SHORT = Common.SHORT
local INTEGER = Common.INTEGER
local HALF_FLOAT = Common.HALF_FLOAT
local FLOAT = Common.FLOAT
local DOUBLE = Common.DOUBLE
local Asserts = AssertsModule.Asserts

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
		Block
			:Compare("MantissaExponent", "0b0_11111_0000000000 ", "Equals")
			:Compare("Encoded // 0x8000", "1", "Equals")
			:Line(`{Variable} = -math.huge`)
			:Branch("Default")
			:Line(`{Variable} = math.huge`)
			:End()
			--> Exponent all ones with any mantissa is NaN. This compared against the SIGNED pattern,
			--> which a value with the sign stripped can never equal, so a NaN fell through to the
			--> arithmetic below and came out as -65600.
			:Branch(
				"Conditional",
				"MantissaExponent",
				"0b0_11111_0000000000",
				"Greater"
			)
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
				--> Rounding can carry a mantissa into the exponent -- a subnormal just below the smallest
				--> normal rounds up to it. Adding the mantissa to the exponent field, rather than taking
				--> it modulo 0x400 first, lets the carry land; the modulo dropped it, and 6.102e-5 went
				--> out as zero.
				"local Scaled = math.round(if Exponent <= 0\n",
				"	then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent))\n",
				"	else Fraction * 0x800)\n",
				"local Result = (if Exponent <= 0 then Scaled else Scaled - 0x400 + Exponent * 0x400)\n",
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

return {}
