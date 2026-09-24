--!strict
--!native
--!optimize 2

--- What every prefab file shares: the registries each one adds to, the wire constants, the
--- numeral picked for a length, and the wrapper that turns a read/write pair into a primitive's
--- generator with its validation.
---
--- The registries are filled at load, in the order Prefabs/init.luau requires the files, and a later
--- prefab may build on an earlier one: f16 reads through u16, CFrame through vector.
local Blocks = require("../Blocks")
local Narrow = require("./Narrow")
local Parser = require("../../Parser")

export type Block = Blocks.Block
--> The compiler's range table, not Roblox's NumberRange userdata (which does not exist on Lune).
export type NumberRange = Parser.NumberRange
export type Writer = (Value: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
export type Reader = (Variable: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
export type Generate = (
	Declaration: Parser.Primitive,
	Variable: string?,
	Read: Block,
	Write: Block,
	WriteValidations: boolean?
) -> ()

export type TypePrefab = {
	Read: Reader,
	Write: Writer,
	--> Set when the reader checks the decoded length itself, before the read. The generic post-read
	--> assert in `GenerateValidation` would then be a second copy of a check that has already passed.
	ValidatesOnRead: boolean?,
}

export type AssertPrefab = {
	Lower: string,
	Upper: string,
	Exact: string?,
}

export type AssertGenerator = (Variable: string, ...any) -> AssertPrefab

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

local Types: { [string]: TypePrefab } = {}

--- Runtime helpers the emitted code has called during the current generate, so the generator splices
--- in only those. Cleared by `Generator.Reset`; `Rotation` is `Fragments.ROTATION_HELPERS`.
local Required: { Rotation: boolean? } = {}

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
				local Min, Max = Range.Min, Range.Max
				if Block == Read then
					Min, Max = Narrow.Bounds(Primitive, Min, Max)
				end

				local Assert = AssertGenerator(TargetVariable, Min, Max)
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
						--> Nil passes on send: an Instance the other side cannot see arrives as nil anyway,
						--> and the receiver is the one that refuses it. The value is typed as a
						--> non-optional Instance, which strict mode will not compare with nil, hence the
						--> cast.
						Block:Compare(`({TargetVariable} :: any)`, "nil", "Not")
							:Multiline(Exact, Block.Indent + 1)
							:End()
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

return {
	Types = Types,
	Required = Required,
	Primitives = Primitives,
	GetTypeToUse = GetTypeToUse,
	GetTypeToUseByBits = GetTypeToUseByBits,
	GeneratePrimitivePrefab = GeneratePrimitivePrefab,
	SEND_BUFFER = SEND_BUFFER,
	RECIEVE_BUFFER = RECIEVE_BUFFER,
	RECIEVE_CURSOR = RECIEVE_CURSOR,
	SEND_POSITION = SEND_POSITION,
	BYTE = BYTE,
	SHORT = SHORT,
	INTEGER = INTEGER,
	HALF_FLOAT = HALF_FLOAT,
	FLOAT = FLOAT,
	DOUBLE = DOUBLE,
}
