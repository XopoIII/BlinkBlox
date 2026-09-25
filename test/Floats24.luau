--!strict
--- f24, read and written, on the pattern of HalfFloats.luau.
---
--- The format came from a Roblox networking library whose own f24 is wrong at both edges: a mantissa
--- that rounds up to 2^17 is taken modulo the field, so 1023.9999999 arrives as 512, and a value
--- below the smallest normal writes a negative exponent, so 1e-10 arrives as 1.8e9. This checks
--- both by construction, against a decoder written without the compiler's code
--- (Generate.Float24FromBits).
---
--- There are sixteen million patterns, too many to send through a generated module on every run, so
--- the binades where the bugs live -- the subnormals, the smallest normals, [1, 2) and the largest --
--- are exhausted, and every other binade is checked at its edges and at a sample drawn from the
--- suite's seed.
local Assertions = require("./Assertions")
local Generate = require("./Generate")
local Harness = require("./Harness")
local Modules = require("./Modules")
local process = require("@lune/process")

local Server = Modules.Server :: any
local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local EXHAUSTED = { 0, 1, 31, 62 }
local EDGES = { 0, 1, 2, 0x10000, 0x1FFFE, 0x1FFFF }
local SAMPLES = 64

local function Bits(Encoded: buffer): number
	return buffer.readu16(Encoded, 0) + buffer.readu8(Encoded, 2) * 0x10000
end

local function Pattern(Value: number): buffer
	local Encoded = buffer.create(3)
	buffer.writeu16(Encoded, 0, Value % 0x10000)
	buffer.writeu8(Encoded, 2, Value // 0x10000)
	return Encoded
end

local function Hex(Value: number): string
	return `0x{string.format("%06X", Value)}`
end

--- The same number, sign of zero included; any NaN matches any NaN.
local function Same(Left: number, Right: number): boolean
	if Left ~= Left then
		return Right ~= Right
	end

	return Left == Right and (Left ~= 0 or 1 / Left == 1 / Right)
end

--- Every mantissa of the exhausted binades, the edges and a sample of the rest, and the infinities
--- and NaNs above them, without sign. In ascending order within each binade.
local function Magnitudes(): { number }
	math.randomseed(tonumber(process.env.BLINKBLOX_SEED) or 24)
	local List = {}
	for Exponent = 0, 62 do
		local Base = Exponent * 0x20000
		if table.find(EXHAUSTED, Exponent) then
			for Mantissa = 0, 0x1FFFF do
				table.insert(List, Base + Mantissa)
			end
		else
			local Chosen = table.clone(EDGES)
			for _ = 1, SAMPLES do
				table.insert(Chosen, math.random(0, 0x1FFFF))
			end

			table.sort(Chosen)
			for _, Mantissa in Chosen do
				table.insert(List, Base + Mantissa)
			end
		end
	end

	for _, Mantissa in { 0, 1, 0x10000, 0x1FFFF } do
		table.insert(List, 0x7E0000 + Mantissa)
	end

	return List
end

local MAGNITUDES = Magnitudes()

RunClosure("Every f24 pattern checked reads as the format says, and writes back to itself", function()
	for _, Sign in { 0, 0x800000 } do
		for _, Magnitude in MAGNITUDES do
			local Encoded = Sign + Magnitude
			local Expected = Generate.Float24FromBits(Encoded)
			local Got = Server.Float24.Read(Pattern(Encoded))
			if not Same(Expected, Got) then
				ErrorPrint(`Failed "f24 read": {Hex(Encoded)} read as {Got}, the format says {Expected}.`)
				return
			end

			--> NaN has many patterns and the writer picks one; every other value has exactly one.
			local Written = Bits(Server.Float24.Write(Got))
			if Expected == Expected and Written ~= Encoded then
				ErrorPrint(`Failed "f24 write": {Got} ({Hex(Encoded)}) wrote back as {Hex(Written)}.`)
				return
			elseif Expected ~= Expected and Generate.Float24FromBits(Written) == Generate.Float24FromBits(Written) then
				ErrorPrint(`Failed "f24 write": NaN wrote back as {Hex(Written)}, which is not a NaN.`)
				return
			end
		end
	end
end)

RunClosure("A value between two f24 neighbours is written as the nearer one", function()
	--> Walks each sign's finite values in order, so consecutive magnitudes one apart are neighbours,
	--> the last mantissa of a binade and the first of the next included -- that step is the carry.
	--> f24 rounds to nearest: a quarter of the way along goes down, three quarters goes up.
	for _, Sign in { 0, 0x800000 } do
		for Index = 1, #MAGNITUDES - 1 do
			local Magnitude = MAGNITUDES[Index]
			if MAGNITUDES[Index + 1] ~= Magnitude + 1 or Magnitude + 1 >= 0x7E0000 then
				continue
			end

			local Low = Generate.Float24FromBits(Sign + Magnitude)
			local High = Generate.Float24FromBits(Sign + Magnitude + 1)
			for _, Case in { { 0.25, Low }, { 0.75, High } } do
				local Between = Low + (High - Low) * Case[1]
				local Got = Server.Float24.Read(Server.Float24.Write(Between))
				if not Same(Got, Case[2]) then
					ErrorPrint(`Failed "f24 rounding": {Between}, between {Low} and {High}, arrived as {Got}.`)
					return
				end
			end
		end
	end
end)

RunClosure("f24 overflows into infinity and underflows into a signed zero", function()
	local Largest = Generate.Float24FromBits(0x7DFFFF)
	local Cases = {
		{ Largest, Largest },
		--> Half a unit past the largest finite value is where rounding reaches infinity.
		{ 4294959103, Largest },
		{ 4294959104, math.huge },
		{ 1e300, math.huge },
		{ math.huge, math.huge },
		{ -4294959104, -math.huge },
		{ -math.huge, -math.huge },
		--> Below half the smallest subnormal, a value is zero and keeps its sign.
		{ math.ldexp(1, -49), 0 },
		{ -math.ldexp(1, -49), -0 },
		{ 5e-324, 0 },
		{ -0, -0 },
		--> Half the smallest subnormal rounds away from zero.
		{ math.ldexp(1, -48), math.ldexp(1, -47) },
		--> The values the library the format came from got wrong.
		{ 1023.9999999, 1024 },
		{ 1 - 1e-7, 1 },
		--> A subnormal: 1e-10 is 14073.75 units of 2^-47.
		{ 1e-10, math.ldexp(14074, -47) },
	}

	for _, Case in Cases do
		local Got = Server.Float24.Read(Server.Float24.Write(Case[1]))
		if not Same(Got, Case[2]) then
			ErrorPrint(`Failed "f24 edges": {Case[1]} arrived as {Got}, expected {Case[2]}.`)
		end
	end
end)

return {}
