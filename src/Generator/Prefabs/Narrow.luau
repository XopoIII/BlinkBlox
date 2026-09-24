--!strict
--- What a float becomes on the wire, worked out at compile time.
---
--- A range is checked on the RECEIVER against the value it decoded, and a decoded f32 or f16 is the
--- declared number narrowed to that precision -- `f32(0..0.3)` receives 0.3 as 0.30000001192092896,
--- above its own bound, and `f16(0.1..1)` receives 0.1 as 0.0999755859375, below it. So the receiver
--- checks against the bounds narrowed the same way. Both encodings are monotonic, so a value inside
--- the declared range always decodes inside the narrowed one, and a value outside it never does.

local Narrow = {}

function Narrow.f32(Value: number): number
	if Value ~= Value or Value == math.huge or Value == -math.huge then
		return Value
	end

	local Scratch = buffer.create(4)
	buffer.writef32(Scratch, 0, Value)
	return buffer.readf32(Scratch, 0)
end

--- The f16 writer and reader in Prefabs/Numbers.luau, run on one number.
function Narrow.f16(Value: number): number
	if Value > 65504 then
		return math.huge
	elseif Value < -65504 then
		return -math.huge
	elseif Value ~= Value or Value == 0 then
		return Value
	end

	local Absolute = math.abs(Value)
	local Interval = math.ldexp(1, math.floor(math.log(Absolute, 2)) - 10)
	local Rounded = (Absolute // Interval) * Interval
	local Fraction, Exponent = math.frexp(Rounded)
	Exponent += 14

	local Scaled =
		math.round(if Exponent <= 0 then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent)) else Fraction * 0x800)
	local Encoded = if Exponent <= 0 then Scaled else Scaled - 0x400 + Exponent * 0x400

	local Field = Encoded // 0x400
	local Mantissa = Encoded % 0x400
	local Result = if Field >= 31
		then math.huge
		else math.ldexp(if Field == 0 then Mantissa / 0x400 else Mantissa / 0x800 + 0.5, Field - 14)

	return if Value < 0 then -Result else Result
end

--- The bounds a receiver checks for a range declared on `Primitive`: narrowed for the float types,
--- unchanged for everything else.
function Narrow.Bounds(Primitive: string, Min: number, Max: number): (number, number)
	if Primitive == "f32" then
		return Narrow.f32(Min), Narrow.f32(Max)
	elseif Primitive == "f16" then
		return Narrow.f16(Min), Narrow.f16(Max)
	end

	return Min, Max
end

return Narrow
