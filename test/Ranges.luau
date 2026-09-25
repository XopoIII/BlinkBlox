--!strict
--- Specs for ranges -- on numbers, vectors, arrays and strings, including NaN -- and for arrays
--- nested inside arrays.
---
--- They live apart from Test.luau but run as part of the same suite, in the place they held there.
local Assertions = require("./Assertions")
local Format = require("../src/Modules/Format")
local Harness = require("./Harness")
local Modules = require("./Modules")
local roblox = require("@lune/roblox")

local ErrorPrint = Harness.ErrorPrint
local Client = Modules.Client
local Server = Modules.Server
local Equals = Assertions.Equals
local FireAndExpectTuple = Assertions.FireAndExpectTuple
local RunClosure = Assertions.RunClosure

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			Client.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			Client.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			Client.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	--> An open side is unbounded, not bounded by the range of exact integers: it used to be filled
	--> with 2^24 for `f32`, so `f32(0..)` refused 2e7 at runtime. The closed side still holds, and
	--> NaN is still refused, by the side that remains.
	do
		local OpenSuccess = pcall(function()
			Client.UnboundUpper.Write(2 ^ 53 + 1)
			Client.UnboundUpper.Write(math.huge)
		end)

		local ClosedSuccess = pcall(function()
			Client.UnboundUpper.Write(-1)
		end)

		local NanSuccess = pcall(function()
			Client.UnboundUpper.Write(0 / 0)
		end)

		if not OpenSuccess or ClosedSuccess or NanSuccess then
			ErrorPrint("Expected unbound upper range to be enforced on its closed side only.")
		end
	end

	do
		local OpenSuccess = pcall(function()
			Client.UnboundLower.Write(-(2 ^ 53 + 1))
			Client.UnboundLower.Write(-math.huge)
		end)

		local ClosedSuccess = pcall(function()
			Client.UnboundLower.Write(1)
		end)

		local NanSuccess = pcall(function()
			Client.UnboundLower.Write(0 / 0)
		end)

		if not OpenSuccess or ClosedSuccess or NanSuccess then
			ErrorPrint("Expected unbound lower range to be enforced on its closed side only.")
		end
	end

	--> NaN compares false against everything, so a check written as `x < Min` or `x > Max` let it
	--> through on both sides -- including from a client, into a listener told the value was ranged.
	do
		local WriteSuccess = pcall(function()
			Client.DecimalRange.Write(0 / 0)
		end)

		local NaN = buffer.create(4)
		buffer.writef32(NaN, 0, 0 / 0)
		local ReadSuccess = pcall(function()
			Server.DecimalRange.Read(NaN)
		end)

		if WriteSuccess or ReadSuccess then
			ErrorPrint("Expected a range to refuse NaN.")
		end
	end

	--> The same for a vector's magnitude: a NaN component makes the magnitude NaN.
	do
		local WriteSuccess = pcall(function()
			Client.RangedVectorFromClient.Fire(roblox.Vector3.new(0 / 0, 0, 0))
		end)

		if WriteSuccess then
			ErrorPrint("Expected a vector range to refuse NaN on write.")
		end
	end

	Client.ExactRange.Write(0)

	Client.DecimalRange.Write(-5.5)
	Client.DecimalRange.Write(10)

	Client.NegativeRange.Write(-5)
	Client.NegativeRange.Write(10)

	Client.UnboundUpper.Write(0)
	Client.UnboundUpper.Write(16777216)

	Client.UnboundLower.Write(-16777216)
	Client.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Nested = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = Client.MultiDimensionalArray.Write(Nested)
	local Deserialized = Client.MultiDimensionalArray.Read(Serialized)

	if not Equals(Nested, Deserialized) then
		ErrorPrint(`Expected: {Format(Nested)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		Server.Issue33.Event,
		Client.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("A float range accepts the values it names once they are narrowed", function()
	--> The receiver checked a decoded f32 or f16 against the bounds as written, but decoded values
	--> are narrowed: 0.3 arrives as 0.30000001192092896, above `f32(0..0.3)`, and 0.1 as an f16
	--> arrives as 0.0999755859375, below `f16(0.1..1)`. Each range refused its own bound.
	local task = require("@lune/task")
	local Seen32, Seen16, Seen24 = 0, 0, 0
	local Disconnect32 = Server.RangedFloat32.On(function()
		Seen32 += 1
	end)
	local Disconnect16 = Server.RangedFloat16.On(function()
		Seen16 += 1
	end)
	--> f24 rounds to nearest, so of `f24(0.1..0.7)` the lower bound arrives below itself and the
	--> upper one above.
	local Disconnect24 = Server.RangedFloat24.On(function()
		Seen24 += 1
	end)

	--> One per frame: a refused value drops the rest of its packet. The out-of-range ones may be refused
	--> by either side -- this schema validates writes as well -- and only the in-range ones may land.
	for _, Send in
		{
			function()
				Client.RangedFloat32.Fire(0.3)
			end,
			function()
				pcall(Client.RangedFloat32.Fire, 0.4)
			end,
			function()
				Client.RangedFloat16.Fire(0.1)
			end,
			function()
				pcall(Client.RangedFloat16.Fire, 1.5)
			end,
			function()
				Client.RangedFloat24.Fire(0.1)
			end,
			function()
				Client.RangedFloat24.Fire(0.7)
			end,
			function()
				pcall(Client.RangedFloat24.Fire, 0.75)
			end,
		}
	do
		Send()
		task.wait(1 / 30)
	end

	Disconnect32()
	Disconnect16()
	Disconnect24()

	assert(Seen32 == 1, `f32(0..0.3) accepted {Seen32} of 0.3 and 0.4, expected only 0.3`)
	assert(Seen16 == 1, `f16(0.1..1) accepted {Seen16} of 0.1 and 1.5, expected only 0.1`)
	assert(Seen24 == 2, `f24(0.1..0.7) accepted {Seen24} of 0.1, 0.7 and 0.75, expected 0.1 and 0.7`)
end)
