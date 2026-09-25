--!strict
--- Specs for a number's modifiers: scaled integers, `u16<0.1>`, and `saturate`.
---
--- Each schema here is compiled through GenerateShared, whose exported readers and writers run with
--- nothing mocked, once with WriteValidations and once without, and every check names the exact
--- bytes or the exact value -- a scale that is off by a step, or a clamp that stops one short of its
--- bound, has nowhere to hide in a tolerance.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Parser = require("@compiler/Parser")
local luau = require("@lune/luau")

local RunClosure = Assertions.RunClosure

type Serde = { Write: (any) -> buffer, Read: (buffer) -> any }
type Module = { [string]: Serde }

local SCALED = [[
export type Tenths = u16<0.1>
export type Ranged = u16<0.1>(0..100)
export type Quarter = i16<0.25>(-10..10)
export type Coarse = u8<2.5>
export type Whole = u16<1>
export type Wide = u32<0.001>
export type Signed24 = i24<0.5>
]]

local SATURATED = [[
export type Count = u8<saturate>(1..255)
export type Signed = i8<saturate>(-5..5)
export type Negative = i16<saturate>(-10..-5)
export type Tenths = u16<0.1, saturate>(0..100)
export type Half = f16<saturate>
export type Unit = f32<saturate>(0..1)
export type Plain = u16<saturate>
export type Big = f64<saturate>
]]

local function Compile(Schema: string, Validated: boolean): Module
	local Options = if Validated then "option WriteValidations = true\n" else ""
	local Source = Generator.GenerateShared(Parser.new():Parse(Options .. Schema))
	return (luau.load(Source) :: any)()
end

local function Bytes(...: number): string
	return string.char(...)
end

local function Hex(Value: buffer): string
	local Parts = {}
	for Index = 0, buffer.len(Value) - 1 do
		table.insert(Parts, string.format("%02x", buffer.readu8(Value, Index)))
	end
	return table.concat(Parts, " ")
end

--- `Sent` is written as exactly `Expected`, and reads back as exactly `Back` -- by bits, so -0 and 0
--- differ and NaN never passes.
local function Expect(Serde: Serde, Sent: number, Expected: string, Back: number)
	local Written = Serde.Write(Sent)
	assert(
		buffer.tostring(Written) == Expected,
		`{Sent} was written as {Hex(Written)}, expected {Hex(buffer.fromstring(Expected))}`
	)

	local Got = Serde.Read(Written)
	assert(
		Got == Back and (Got ~= 0 or 1 / Got == 1 / Back),
		`{Sent} read back as {Got} ({string.format("%.17g", Got)}), expected {Back}`
	)
end

--- Writing `Sent` fails, with a message containing `Message`.
local function Refused(Serde: Serde, Sent: any, Message: string)
	local Success, Failure = pcall(Serde.Write, Sent)
	assert(not Success, `{Sent} was written, expected it to be refused`)
	assert(
		string.find(tostring(Failure), Message, 1, true),
		`{Sent} was refused with "{Failure}", expected "{Message}"`
	)
end

--- Reading `Encoded` fails.
local function Unreadable(Serde: Serde, Encoded: string)
	local Success, Value = pcall(Serde.Read, buffer.fromstring(Encoded))
	assert(not Success, `{Hex(buffer.fromstring(Encoded))} was read as {Value}, expected a refusal`)
end

RunClosure("A scaled integer sends the nearest whole step and reads it back exactly", function()
	for _, Validated in { true, false } do
		local Module = Compile(SCALED, Validated)

		--> 12.34 is 123.4 tenths: 123 goes out, and it comes back as the double the literal 12.3 is.
		Expect(Module.Tenths, 12.34, Bytes(123, 0), 12.3)
		Expect(Module.Tenths, 12.35, Bytes(124, 0), 12.4)
		Expect(Module.Tenths, 0.04, Bytes(0, 0), 0)
		Expect(Module.Tenths, 0.05, Bytes(1, 0), 0.1)
		Expect(Module.Tenths, 6553.5, Bytes(255, 255), 6553.5)
		Expect(Module.Tenths, 6553.54, Bytes(255, 255), 6553.5)

		--> A tie rounds away from zero, on both sides of it.
		Expect(Module.Quarter, 2.375, Bytes(10, 0), 2.5)
		Expect(Module.Quarter, -2.375, Bytes(0xF6, 0xFF), -2.5)
		Expect(Module.Quarter, -10, Bytes(0xD8, 0xFF), -10)
		Expect(Module.Quarter, 10.1, Bytes(40, 0), 10)

		--> A step that is not a whole reciprocal multiplies and divides by the step.
		Expect(Module.Coarse, 5, Bytes(2), 5)
		Expect(Module.Coarse, 6.2, Bytes(2), 5)
		Expect(Module.Coarse, 637.5, Bytes(255), 637.5)

		--> A step of 1 rounds to nearest where a bare integer truncates.
		Expect(Module.Whole, 2.5, Bytes(3, 0), 3)
		Expect(Module.Whole, 2.4999, Bytes(2, 0), 2)

		Expect(Module.Wide, 4294967.295, Bytes(255, 255, 255, 255), 4294967.295)
		Expect(Module.Signed24, -4194304, Bytes(0, 0, 0x80), -4194304)
		Expect(Module.Signed24, 4194303.5, Bytes(255, 255, 0x7F), 4194303.5)
	end
end)

RunClosure("A scaled integer past its range is refused under WriteValidations", function()
	local Module = Compile(SCALED, true)

	Refused(Module.Tenths, 6553.56, `smaller than or equal to 6553.5 in steps of 0.1, got 6553.56`)
	Refused(Module.Tenths, -0.06, `larger than or equal to 0 in steps of 0.1, got -0.06`)
	Refused(Module.Tenths, 0 / 0, `larger than or equal to 0 in steps of 0.1`)
	Refused(Module.Tenths, "1", `Expected Value to be of type number, got string instead.`)
	Refused(Module.Ranged, 100.06, `smaller than or equal to 100 in steps of 0.1, got 100.06`)
	Refused(Module.Quarter, 10.2, `smaller than or equal to 10 in steps of 0.25, got 10.2`)
	Refused(Module.Quarter, -10.2, `larger than or equal to -10 in steps of 0.25, got -10.2`)

	--> The last value that rounds inside is still taken.
	Expect(Module.Ranged, 100.04, Bytes(0xE8, 0x03), 100)
end)

RunClosure("A scaled integer past its range wraps without WriteValidations, as an integer does", function()
	local Module = Compile(SCALED, false)

	--> 6553.6 is 65536 tenths, which a u16 keeps as 0.
	Expect(Module.Tenths, 6553.6, Bytes(0, 0), 0)
end)

RunClosure("A scaled range is checked on receipt in whole steps", function()
	local Module = Compile(SCALED, false)

	assert(Module.Ranged.Read(buffer.fromstring(Bytes(0xE8, 0x03))) == 100, "1000 tenths should read as 100")
	Unreadable(Module.Ranged, Bytes(0xE9, 0x03))
	Unreadable(Module.Quarter, Bytes(41, 0))
	Unreadable(Module.Quarter, Bytes(0xD7, 0xFF))
end)

RunClosure("A saturated number is clamped exactly to its bounds, with or without WriteValidations", function()
	for _, Validated in { true, false } do
		local Module = Compile(SATURATED, Validated)

		Expect(Module.Count, 0, Bytes(1), 1)
		Expect(Module.Count, 300, Bytes(255), 255)
		Expect(Module.Count, -1e9, Bytes(1), 1)
		Expect(Module.Count, math.huge, Bytes(255), 255)
		Expect(Module.Count, -math.huge, Bytes(1), 1)
		--> An integer is rounded to nearest before it is clamped.
		Expect(Module.Count, 254.4, Bytes(254), 254)
		Expect(Module.Count, 254.5, Bytes(255), 255)
		Expect(Module.Count, 255.4, Bytes(255), 255)

		Expect(Module.Signed, 6, Bytes(5), 5)
		Expect(Module.Signed, -math.huge, Bytes(0xFB), -5)
		Expect(Module.Signed, -2.5, Bytes(0xFD), -3)

		Expect(Module.Negative, 0, Bytes(0xFB, 0xFF), -5)
		Expect(Module.Negative, -100, Bytes(0xF6, 0xFF), -10)

		Expect(Module.Tenths, 7000, Bytes(0xE8, 0x03), 100)
		Expect(Module.Tenths, -3, Bytes(0, 0), 0)
		Expect(Module.Tenths, 12.34, Bytes(123, 0), 12.3)
		Expect(Module.Tenths, 100.04, Bytes(0xE8, 0x03), 100)

		--> An f16 would carry anything past 65504 as infinity; saturated, it stops at 65504.
		Expect(Module.Half, 1e6, Bytes(0xFF, 0x7B), 65504)
		Expect(Module.Half, -math.huge, Bytes(0xFF, 0xFB), -65504)

		Expect(Module.Unit, 2, Bytes(0, 0, 0x80, 0x3F), 1)
		Expect(Module.Unit, -1, Bytes(0, 0, 0, 0), 0)
		Expect(Module.Unit, 0.5, Bytes(0, 0, 0, 0x3F), 0.5)

		Expect(Module.Plain, 70000, Bytes(255, 255), 65535)
		Expect(Module.Plain, -1, Bytes(0, 0), 0)
		Expect(Module.Plain, 1.5, Bytes(2, 0), 2)

		--> An open side clamps nothing.
		Expect(Module.Big, math.huge, Bytes(0, 0, 0, 0, 0, 0, 0xF0, 0x7F), math.huge)
	end
end)

RunClosure("A saturated number sends NaN as the value in its range nearest zero", function()
	for _, Validated in { true, false } do
		local Module = Compile(SATURATED, Validated)
		local NaN = 0 / 0

		Expect(Module.Count, NaN, Bytes(1), 1)
		Expect(Module.Signed, NaN, Bytes(0), 0)
		Expect(Module.Negative, NaN, Bytes(0xFB, 0xFF), -5)
		Expect(Module.Tenths, NaN, Bytes(0, 0), 0)
		Expect(Module.Half, NaN, Bytes(0, 0), 0)
		Expect(Module.Unit, NaN, Bytes(0, 0, 0, 0), 0)
		Expect(Module.Big, NaN, Bytes(0, 0, 0, 0, 0, 0, 0, 0), 0)
	end
end)

RunClosure("Saturation changes what is sent, never what is accepted", function()
	local Module = Compile(SATURATED, true)

	--> A hostile sender does not saturate: the receiver still holds it to the range.
	Unreadable(Module.Count, Bytes(0))
	Unreadable(Module.Tenths, Bytes(0xE9, 0x03))
	Unreadable(Module.Negative, Bytes(0xFC, 0xFF))
	Unreadable(Module.Negative, Bytes(0xF5, 0xFF))
	Refused(Module.Count, "5", `Expected Value to be of type number, got string instead.`)
end)

return {}
