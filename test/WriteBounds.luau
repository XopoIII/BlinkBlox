--!strict
--- Specs for the send-side bounds on a length prefix, which hold whether or not WriteValidations is
--- set: without them a value too long for its prefix is not refused but corrupted.
---
--- They compile a schema of their own through GenerateShared, whose output is plain Luau with no
--- remotes, so its exported readers and writers run here with nothing mocked. They run as part of
--- the suite from Test.luau.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")
local luau = require("@lune/luau")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--> No `option WriteValidations`: the default is off, and off is where the prefix used to wrap.
local SCHEMA = [[
export type Short = string(0..64)
export type Ranged = string(10..20)
export type Wide = string
export type Bytes = buffer(0..64)
export type List = u8[0..64]
export map Counts = {[u32]: u8}
]]

local function Load(): { [string]: { Write: (any) -> buffer, Read: (buffer) -> any } }
	local Source = Generator.GenerateShared(Parser.new():Parse(SCHEMA))
	return (luau.load(Source) :: any)()
end

local function LengthOf(Value: any): number
	if type(Value) == "string" then
		return #Value
	elseif type(Value) == "buffer" then
		return buffer.len(Value)
	end

	local Count = 0
	for _ in Value do
		Count += 1
	end
	return Count
end

RunClosure("A length its prefix cannot hold is refused on send, not wrapped", function()
	local Module = Load()

	local function Map(Size: number): { [number]: number }
		local Result = {}
		for Index = 1, Size do
			Result[Index] = 1
		end
		return Result
	end

	local TooLong: { { Name: string, Value: any } } = {
		--> A u8 prefix: 300 used to go out as 44 with all 300 bytes behind it.
		{ Name = "Short", Value = string.rep("a", 300) },
		{ Name = "Bytes", Value = buffer.create(300) },
		{ Name = "List", Value = table.create(300, 1) },
		--> Past the bound but inside the numeral: not corrupt, but refused only by the receiver.
		{ Name = "Short", Value = string.rep("a", 65) },
		{ Name = "Ranged", Value = string.rep("a", 21) },
		{ Name = "Ranged", Value = string.rep("a", 9) },
		--> The u16 an unbounded string and a map's count are written in.
		{ Name = "Wide", Value = string.rep("a", 65536) },
		{ Name = "Counts", Value = Map(65536) },
	}

	for _, Case in TooLong do
		local Written, Result = pcall(Module[Case.Name].Write, Case.Value)
		if Written then
			local Read, Value = pcall(Module[Case.Name].Read, Result)
			ErrorPrint(
				`Failed "Send-side bounds": {Case.Name} of length {LengthOf(Case.Value)} was written, and read `
					.. `back as {if Read then `length {LengthOf(Value)}` else "an error"}.`
			)
		end
	end

	--> The bounds themselves are still accepted, and come back whole.
	local Fits: { { Name: string, Value: any } } = {
		{ Name = "Short", Value = string.rep("a", 64) },
		{ Name = "Short", Value = "" },
		{ Name = "Ranged", Value = string.rep("a", 10) },
		{ Name = "Ranged", Value = string.rep("a", 20) },
		{ Name = "Wide", Value = string.rep("a", 65535) },
		{ Name = "Bytes", Value = buffer.create(64) },
		{ Name = "List", Value = table.create(64, 7) },
		{ Name = "Counts", Value = Map(65535) },
	}

	for _, Case in Fits do
		local Written, Result = pcall(Module[Case.Name].Write, Case.Value)
		local Length = LengthOf(Case.Value)
		if not Written then
			ErrorPrint(`Failed "Send-side bounds": {Case.Name} of length {Length} was refused: {Result}`)
			continue
		end

		local Back = LengthOf(Module[Case.Name].Read(Result))
		if Back ~= Length then
			ErrorPrint(`Failed "Send-side bounds": {Case.Name} of length {Length} came back as {Back}.`)
		end
	end
end)
