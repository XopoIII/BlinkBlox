--!strict
--- Frozen byte-level captures of the wire format, one per exported type of Test.blink.
---
--- The source goldens in test/Golden freeze what the EMITTER writes, and a wire change shows up
--- there as a reviewable diff -- but only a reader who knows the generator can tell a diff that
--- reorders locals from one that changes a byte on the wire. These captures cut out the reading:
--- every serialiser is run on a fixed fixture and its exact output bytes are compared against a
--- committed golden, so ANY wire change fails the suite, intended or not, and a change that only
--- reshuffles generated source passes silently the way it should.
---
--- A deliberate format change reruns `luneblox run Test --yes --update-goldens` from test/, like
--- any other golden, and the diff of the hex IS the format change -- release notes can quote it.
---
--- The fixtures are chosen to touch each encoding branch: every bit-packing boundary (one, seven,
--- eight, nine, seventeen booleans), a sparse and a dense mixed bitfield, packed boolean arrays
--- beside plain fields, offset-encoded lengths at both ends of their span, quantized and scaled
--- integers, saturation, every CFrame encoding, and optionals present and absent.
---
--- Satset's wire goldens are the precedent (its 0.6.0, tests/wire-golden.luau).
---
--- They live apart from Test.luau, like Decoding.luau, but run as part of the same suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local roblox = require("@lune/roblox")

local Client = Modules.Client

local RunClosure = Assertions.RunClosure

local Environment = Shared.GetEnvironment()
local DateTime = Environment.DateTime
local BrickColor = Environment.BrickColor
local Color3 = Environment.Color3

local Vector3 = roblox.Vector3

local Rotation = roblox.CFrame.fromAxisAngle(Vector3.new(0, 1, 0), 0.7)
local Turned = roblox.CFrame.new(1.5, -2, 3.25) * Rotation

local function Text(Count: number, Character: string): string
	return string.rep(Character, Count)
end

local function Bytes(Fill: string): buffer
	local Built = buffer.create(#Fill)
	buffer.writestring(Built, 0, Fill)
	return Built
end

--> One fixture per line: the type it exercises, the value written, and why the pair is here.
local Samples: { { Name: string, Value: any } } = {
	{ Name = "Byte", Value = 200 },
	{ Name = "NegativeRange", Value = 7 },
	{ Name = "ExactRange", Value = 0 },
	{ Name = "DecimalRange", Value = 3.25 },
	{ Name = "UnboundUpper", Value = 12.5 },
	{ Name = "UnboundLower", Value = -2.75 },
	{ Name = "RangedVector", Value = Vector3.new(0.4, 0.5, 0.6) },

	--> Ranges inside a struct: each field's checks run where it is stored, and the encoding of a
	--> bounded integer differs from a plain one.
	{
		Name = "RangedFields",
		Value = { Health = 72, Angle = -90.5, Level = -2, Weight = 0.5, Seven = 7, Full = 40000 },
	},
	{ Name = "RangedList", Value = { -3, -1, 0, 1, 3, 2, -2, -2 } },

	--> Quantized floats: whole steps from the minimum in the narrowest integer the span fits.
	{ Name = "Quantized", Value = 0.37 },
	{ Name = "QuantizedWide", Value = 1024.5 },
	{ Name = "QuantizedSaturated", Value = 15 },
	{ Name = "QuantizedFields", Value = { Aim = 0.25, Height = 150 } },

	--> Buffers: raw bytes in, length-prefixed bytes out.
	{ Name = "Buffer", Value = Bytes("abcde") },
	{ Name = "ExactBuffer", Value = Bytes("123456789") },
	{ Name = "BoundedBuffer", Value = Bytes("goldwir") },

	--> Every CFrame encoding the schema names, identity and quaternion rotation alike.
	{ Name = "PlainCFrame", Value = roblox.CFrame.new(1.5, -2, 3.25) },
	{ Name = "QuatCFrame", Value = Turned },
	{ Name = "QuatHalfCFrame", Value = Turned },
	{ Name = "QuatFirstCFrame", Value = Turned },
	{ Name = "QuatCFrames", Value = { roblox.CFrame.new(0, 0, 0), Turned } },

	{ Name = "MultiDimensionalArray", Value = { { { 1, 2 }, { 3 } }, { { 4 } } } },

	--> The size-analysis fixtures double as wire fixtures: fixed, bounded, empty and absent.
	{ Name = "SizeFixedString", Value = "wiregold" },
	{ Name = "SizeBoundedString", Value = "ok" },
	{ Name = "SizeFixedArray", Value = { 1, 2, 3, 4 } },
	{ Name = "SizeBoundedArray", Value = { 5, 6 } },
	{ Name = "SizeOptionalByte", Value = nil },
	{ Name = "SizeOptionalByte", Value = 42 },
	{ Name = "SizeVector", Value = Vector3.new(1, 2, 3) },
	{ Name = "SizeStruct", Value = { A = 1, B = true, C = 65535 } },
	{ Name = "SizeEnum", Value = "C" },
	{ Name = "SizeFlags", Value = { F1 = true, F3 = true } },
	{ Name = "SizeMap", Value = { [1] = 500, [2] = 1000 } },

	--> Offset-encoded lengths: a span of 101 carried in one byte, at the low and high ends.
	{ Name = "OffsetArray", Value = table.create(305, 7) },
	{ Name = "OffsetArray", Value = table.create(400, 3) },
	{ Name = "OffsetString", Value = Text(321, "z") },
	{ Name = "OffsetBuffer", Value = buffer.create(350) },

	--> Bit packing around byte boundaries: one, seven, eight, nine and seventeen flags.
	{ Name = "BitsOne", Value = { A = true } },
	{
		Name = "BitsSeven",
		Value = { A = true, B = false, C = true, D = false, E = true, F = false, G = true },
	},
	{
		Name = "BitsEight",
		Value = { A = true, B = true, C = false, D = true, E = false, F = true, G = false, H = true },
	},
	{
		Name = "BitsNine",
		Value = { A = false, B = true, C = true, D = false, E = true, F = false, G = true, H = true, I = false },
	},
	{
		Name = "BitsSeventeen",
		Value = {
			A = true,
			B = false,
			C = true,
			D = true,
			E = false,
			F = false,
			G = true,
			H = true,
			I = true,
			J = false,
			K = false,
			L = true,
			M = true,
			N = false,
			O = true,
			P = true,
			Q = false,
		},
	},

	--> Booleans and optional presence flags share the bitfield: dense, then sparse.
	{ Name = "BitsMixed", Value = { A = true, B = 5, C = false, D = 1000 } },
	{ Name = "BitsMixed", Value = { A = false, B = nil, C = true, D = nil } },

	--> Packed boolean arrays: eight to a byte, after the length, beside plain fields.
	{ Name = "PackedBooleans", Value = { true, false, true } },
	{ Name = "PackedFixed", Value = { true, false, true, true, false, true, false, true, true, false } },
	{ Name = "PackedRanged", Value = { true, true, false, false, true, false, true, true, false } },
	{ Name = "PackedNested", Value = { { true }, { false, true } } },
	{ Name = "PackedThroughAlias", Value = { false, true } },
	{
		Name = "PackedBeside",
		Value = { A = true, List = { true }, B = true, Fixed = { true, false, true }, C = 1 },
	},
	{ Name = "PackedMap", Value = { a = { true, false, true } } },
	{ Name = "PackedOptional", Value = { true, nil, false } },

	--> A map of maps, and a struct holding a tagged enum.
	{ Name = "MapNested", Value = { Outer = { a = 1, b = 2 } } },
	{
		Name = "Standalone",
		Value = {
			One = 1,
			Two = 2,
			Three = 3,
			Event = { Type = "Join", Name = "gold", UserId = 123 },
			Nested = { Four = "aa", Five = "bb" },
		},
	},

	--> Narrow floats: a half, a 24-bit, and the 24-bit integer and vector forms of it.
	{ Name = "HalfFloat", Value = 1.5 },
	{ Name = "Float24", Value = 2.75 },
	{ Name = "Unsigned24", Value = 12345678 },
	{ Name = "Signed24", Value = -123456 },
	{ Name = "Vector24", Value = Vector3.new(0.5, -0.25, 0.125) },
	{ Name = "QuatCFrame24", Value = Turned },

	--> Roblox datatypes a client never chooses: colour, colour list, clock and brick palette.
	{ Name = "Color", Value = Color3.fromRGB(10, 20, 30) },
	{ Name = "ColorArray", Value = { Color3.new(0.25, 0.5, 0.75), Color3.new(0, 1, 0.5) } },
	{ Name = "DateSeconds", Value = DateTime.fromUnixTimestamp(1700000000) },
	{ Name = "DateMilliseconds", Value = DateTime.fromUnixTimestampMillis(1700000000123) },
	{ Name = "BrickkColor", Value = BrickColor.new(23) },

	--> An array with a hole in it: the absent element must cost its presence bit and nothing else.
	{ Name = "OptionalHoles", Value = { 1, nil, 3 } },

	--> Scaled integers, in range and saturating past it on every side.
	{ Name = "FixedTenths", Value = 123.4 },
	{ Name = "FixedRanged", Value = 3216.75 },
	{ Name = "FixedSigned", Value = -12.25 },
	{ Name = "FixedCoarse", Value = 7.5 },
	{ Name = "FixedTriple", Value = -1234.567 },
	{ Name = "FixedWide", Value = 999.99 },
	{ Name = "FixedWhole", Value = 1000 },
	{ Name = "SaturatedCount", Value = 300 },
	{ Name = "SaturatedSigned", Value = -9 },
	{ Name = "SaturatedNegative", Value = 0 },
	{ Name = "SaturatedTenths", Value = 150 },
	{ Name = "SaturatedHalf", Value = 1e9 },
	{ Name = "SaturatedUnit", Value = 2 },
	{ Name = "FixedStruct", Value = { A = 5.5, B = -2.5, C = { 1, 2 } } },
}

local function Hex(Written: buffer): string
	local Length = buffer.len(Written)
	local Parts = table.create(Length)
	for Index = 0, Length - 1 do
		Parts[Index + 1] = string.format("%02x", buffer.readu8(Written, Index))
	end
	return table.concat(Parts, " ")
end

RunClosure("Frozen wire captures", function()
	--> Every fixture is written and hexed in a fixed order; the golden holds one line per fixture
	--> as `Name length hex`. A serialiser that throws fails the capture outright -- an encoding
	--> change that no longer accepts its own fixture is a wire change too.
	local Lines = table.create(#Samples)

	for Index, Sample in Samples do
		local Serialiser = (Client :: any)[Sample.Name]
		if not Serialiser then
			Harness.ErrorPrint(`Failed "Wire goldens": Test.blink has no exported type "{Sample.Name}".`)
			continue
		end

		local Success, Result = pcall(function(): buffer
			return Serialiser.Write(Sample.Value)
		end)

		if not Success then
			Harness.ErrorPrint(`Failed "Wire goldens": writing "{Sample.Name}" threw: {Result}`)
			Lines[Index] = `{Sample.Name} ERROR`
			continue
		end

		--> The length sits beside the hex so a size change reads without counting bytes.
		Lines[Index] = `{Sample.Name} {buffer.len(Result)} {Hex(Result)}`
	end

	Harness.Golden("./Golden/Wire/Bytes.txt", table.concat(Lines, "\n") .. "\n")
end)
