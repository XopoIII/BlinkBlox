--!strict
--- Specs for how individual primitives encode, where the question is not whether a value round-trips
--- but what comes out the other side when the value is one the encoding cannot hold exactly.
---
--- They live apart from Test.luau, like WireFormat.luau, but run as part of the same suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")

local Server = Modules.Server
local BaseEnvironment = Shared.GetEnvironment()

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

RunClosure("Color3 channels are rounded and clamped, not truncated and wrapped", function()
	--> Every colour `fromRGB` can make has to come back as itself: rounding must not move one.
	for Channel = 0, 255 do
		local Color = BaseEnvironment.Color3.fromRGB(Channel, Channel, Channel)
		local Got = Server.Color.Read(Server.Color.Write(Color))
		if math.round(Got.R * 255) ~= Channel or Got.R ~= Color.R then
			ErrorPrint(`Failed "Color3 rounding": fromRGB({Channel}) came back as {Got.R * 255}.`)
		end
	end

	--> HDR and negative channels are legal Color3 values. `writeu8` keeps the low byte, so 1.5
	--> wrapped to 126 and -0.2 to 205; 0.999 truncated to 254 where it rounds to 255.
	local Got = Server.Color.Read(Server.Color.Write(BaseEnvironment.Color3.new(1.5, -0.2, 0.999)))
	if Got.R ~= 1 or Got.G ~= 0 or Got.B ~= 1 then
		ErrorPrint(`Failed "Color3 clamping": expected (1, 0, 1), got ({Got.R}, {Got.G}, {Got.B}).`)
	end
end)
