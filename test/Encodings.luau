--!strict
--- Specs for how individual primitives encode, where the question is not whether a value round-trips
--- but what comes out the other side when the value is one the encoding cannot hold exactly.
---
--- They live apart from Test.luau, like WireFormat.luau, but run as part of the same suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local roblox = require("@lune/roblox")

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

RunClosure("Quaternion CFrames round-trip within their precision", function()
	local CFrame = roblox.CFrame
	local Vector3 = roblox.Vector3

	--> The largest difference between two rotation matrices, entry by entry. A quaternion step of
	--> 1/46341 per component moves a matrix entry by at most a few times that.
	local function RotationError(Expected: CFrame, Got: CFrame): number
		local Want = { Expected:GetComponents() }
		local Have = { Got:GetComponents() }
		local Largest = 0
		for Index = 4, 12 do
			Largest = math.max(Largest, math.abs(Want[Index] - Have[Index]))
		end
		return Largest
	end

	local Cases: { CFrame } = {
		CFrame.new(1, 2, 3),
		CFrame.fromAxisAngle(Vector3.new(1, 0, 0), math.pi),
		CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi),
		CFrame.fromAxisAngle(Vector3.new(0, 0, 1), math.pi),
		CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi / 2),
		--> All four components equal, so every branch of the largest-component search ties.
		CFrame.fromAxisAngle(Vector3.new(1, 1, 1).Unit, 2 * math.pi / 3),
		--> A rotation whose largest component is negative once extracted, which the sign fold handles.
		--> Normalised here because Lune's `CFrame.new` does not, and an unnormalised quaternion is not a
		--> rotation matrix at all.
		CFrame.new(
			0,
			0,
			0,
			-0.1 / math.sqrt(0.95),
			0.2 / math.sqrt(0.95),
			-0.3 / math.sqrt(0.95),
			-0.9 / math.sqrt(0.95)
		),
	}

	--> Seeded, so a failure names a case that fails again on the next run.
	math.randomseed(27)
	local function Angle(): number
		return (math.random() * 2 - 1) * math.pi
	end

	for _ = 1, 1000 do
		local Rotation = CFrame.fromOrientation(Angle(), Angle(), Angle())
		local Position = Vector3.new(math.random(-5000, 5000), math.random(-5000, 5000), 0.5)
		table.insert(Cases, CFrame.new(Position) * Rotation)
	end

	for Index, Value in Cases do
		local Buffer = Server.QuatCFrame.Write(Value)
		if buffer.len(Buffer) ~= 19 then
			ErrorPrint(`Failed "Quaternion CFrames": case {Index} took {buffer.len(Buffer)} bytes, expected 19.`)
		end

		local Got = Server.QuatCFrame.Read(Buffer)
		local Error = RotationError(Value, Got)
		if not (Error < 2e-4) then
			ErrorPrint(`Failed "Quaternion CFrames": case {Index} came back rotated by {Error}, over 2e-4.`)
		end

		if Got.Position ~= Value.Position then
			ErrorPrint(`Failed "Quaternion CFrames": case {Index} moved from {Value.Position} to {Got.Position}.`)
		end
	end

	--> With the position as f16, in either slot. Six bytes of position and seven of rotation.
	local Sample = CFrame.new(10, -20, 30) * CFrame.fromOrientation(0.3, -1.2, 2.5)
	for _, Name in { "QuatHalfCFrame", "QuatFirstCFrame" } do
		local Buffer = Server[Name].Write(Sample)
		local Got = Server[Name].Read(Buffer)
		if buffer.len(Buffer) ~= 13 or RotationError(Sample, Got) >= 2e-4 or Got.Position ~= Sample.Position then
			ErrorPrint(`Failed "Quaternion CFrames": {Name} took {buffer.len(Buffer)} bytes or lost the value.`)
		end
	end

	--> An array of them, where each element's locals are declared again in the loop body.
	local List = { Cases[2], Cases[5], Cases[9] }
	local Got = Server.QuatCFrames.Read(Server.QuatCFrames.Write(List))
	for Index, Value in List do
		if RotationError(Value, Got[Index]) >= 2e-4 then
			ErrorPrint(`Failed "Quaternion CFrames": array element {Index} did not survive the round trip.`)
		end
	end

	--> The default encoding is untouched: three f32 and three Euler angles.
	local Plain = Server.PlainCFrame.Write(Sample)
	if buffer.len(Plain) ~= 24 or RotationError(Sample, Server.PlainCFrame.Read(Plain)) >= 1e-5 then
		ErrorPrint(`Failed "Quaternion CFrames": the default CFrame encoding changed.`)
	end
end)

RunClosure("An array of optionals keeps its holes where they were", function()
	--> The reader inserted each element, and inserting nil does nothing: `{1, nil, 3}` arrived as
	--> `{1, 3}`, every element after a hole one place early.
	local Read = Server.OptionalHoles.Read(Server.OptionalHoles.Write({ 1, nil, 3 } :: any)) :: { number? }
	if Read[1] ~= 1 or Read[2] ~= nil or Read[3] ~= 3 then
		ErrorPrint(
			`Failed "Optional holes": read back \{{tostring(Read[1])}, {tostring(Read[2])}, {tostring(Read[3])}\}, expected \{1, nil, 3\}.`
		)
	end
end)
