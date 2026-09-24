--!strict
--!native
--!optimize 2

--- The two variable-length primitives, `string` and `buffer`: a length prefix sized from the span the
--- schema allows, then the bytes.
local AssertsModule = require("./Asserts")
local Common = require("./Common")

type Block = Common.Block
type NumberRange = Common.NumberRange

local Types = Common.Types
local Primitives = Common.Primitives
local GetTypeToUse = Common.GetTypeToUse
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab
local SEND_BUFFER = Common.SEND_BUFFER
local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local SEND_POSITION = Common.SEND_POSITION
local Asserts = AssertsModule.Asserts
local EmitLengthGuard = AssertsModule.EmitLengthGuard
local GenerateSpaceGuard = AssertsModule.GenerateSpaceGuard

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
			EmitLengthGuard(Block, Lower, Upper)

			if Lower > 0 then
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
			EmitLengthGuard(Block, Lower, Upper)

			if Lower > 0 then
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

return {}
