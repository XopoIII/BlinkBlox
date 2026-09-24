--!strict
--- Every f16 there is, read and written.
---
--- f16 is the one number type the buffer library does not implement, so its reader and writer are
--- the compiler's own arithmetic, and two recent releases fixed three bugs in them: NaN decoded as
--- -65600 (0.29), a subnormal lost its carry into the exponent (0.29), and -0 arrived as +0 (0.31).
--- Random draws found the last; this finds bugs of that kind by construction -- the carry and the
--- signed zero, put back into the compiler, each fail it. There are only 65536 bit patterns, so every one is checked against an IEEE decoder written without the compiler's code
--- (Generate.HalfFromBits), and every midpoint between two neighbours is checked to land on one of
--- them. The idea is from treating a small domain as something to exhaust rather than to sample.
local Assertions = require("./Assertions")
local Generate = require("./Generate")
local Harness = require("./Harness")
local Modules = require("./Modules")

local Server = Modules.Server :: any
local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local function Bits(Encoded: buffer): number
	return buffer.readu16(Encoded, 0)
end

local function Pattern(Value: number): buffer
	local Encoded = buffer.create(2)
	buffer.writeu16(Encoded, 0, Value)
	return Encoded
end

--- The same number, sign of zero included; any NaN matches any NaN.
local function Same(Left: number, Right: number): boolean
	if Left ~= Left then
		return Right ~= Right
	end

	return Left == Right and (Left ~= 0 or 1 / Left == 1 / Right)
end

RunClosure("Every f16 bit pattern reads as IEEE says, and writes back to itself", function()
	for Pattern16 = 0, 0xFFFF do
		local Expected = Generate.HalfFromBits(Pattern16)
		local Got = Server.HalfFloat.Read(Pattern(Pattern16))
		if not Same(Expected, Got) then
			ErrorPrint(`Failed "f16 read": 0x{string.format("%04X", Pattern16)} read as {Got}, IEEE says {Expected}.`)
		end

		--> NaN has many patterns and the writer picks one; every other value has exactly one.
		local Written = Bits(Server.HalfFloat.Write(Got))
		if Expected == Expected and Written ~= Pattern16 then
			ErrorPrint(
				`Failed "f16 write": {Got} (0x{string.format("%04X", Pattern16)}) wrote back as 0x{string.format(
					"%04X",
					Written
				)}.`
			)
		elseif Expected ~= Expected and Generate.HalfFromBits(Written) == Generate.HalfFromBits(Written) then
			ErrorPrint(`Failed "f16 write": NaN wrote back as 0x{string.format("%04X", Written)}, which is not a NaN.`)
		end
	end
end)

RunClosure("A value between two f16 neighbours is written as one of them", function()
	--> Walks each sign's finite values in order, so each step is a pair of neighbours. The writer
	--> truncates rather than rounding to nearest; either neighbour is a correct narrowing, and
	--> anything else -- zero for a subnormal, the next binade -- is the carry bug.
	for _, Sign in { 0, 0x8000 } do
		for Magnitude = 0, 0x7BFE do
			local Low = Generate.HalfFromBits(Sign + Magnitude)
			local High = Generate.HalfFromBits(Sign + Magnitude + 1)
			local Between = (Low + High) / 2
			local Got = Server.HalfFloat.Read(Server.HalfFloat.Write(Between))
			if not (Same(Got, Low) or Same(Got, High)) then
				ErrorPrint(`Failed "f16 narrowing": {Between}, between {Low} and {High}, arrived as {Got}.`)
			end
		end
	end
end)
