--!nocheck
-- This is a template. scripts/ocale/build.luau inserts the real generated Datatypes server module
-- at the marker below, producing one script that runs unchanged in LuneBlox and in Roblox OCALE.
local environment = getfenv()
local runningInRoblox = environment.game ~= nil
local api = {}

if runningInRoblox then
	for _, name in
		{
			"CFrame",
			"Color3",
			"ColorSequence",
			"ColorSequenceKeypoint",
			"Enum",
			"Instance",
			"NumberRange",
			"NumberSequence",
			"NumberSequenceKeypoint",
			"PhysicalProperties",
			"Ray",
			"Rect",
			"Region3",
			"TweenInfo",
			"UDim",
			"UDim2",
			"Vector2",
			"Vector3",
		}
	do
		api[name] = environment[name]
	end
	api.jsonEncode = function(value)
		return environment.game:GetService("HttpService"):JSONEncode(value)
	end
else
	local roblox = require("@lune/roblox")
	local serde = require("@lune/serde")
	for name, value in roblox do
		api[name] = value
	end
	api.jsonEncode = function(value)
		return serde.encode("json", value)
	end
end

-- The generated module has a supported edit-mode path: it returns all standalone serializers before
-- touching remotes when RunService is not running. That gives LuneBlox the real generated codec
-- without emulating replication. Roblox takes the ordinary running-server path instead.
local editModeServices = {
	Players = {},
	ReplicatedStorage = {},
	RunService = {
		IsRunning = function()
			return false
		end,
	},
}
local game = if runningInRoblox
	then environment.game
	else {
		GetService = function(_self, name)
			return assert(editModeServices[name], `Unexpected service {name}`)
		end,
	}

-- These locals deliberately become the generated module's lexical globals when it is inserted in
-- loadGeneratedCodec. Both runtimes therefore execute the same serializer with native datatypes.
local CFrame = api.CFrame
local Color3 = api.Color3
local ColorSequence = api.ColorSequence
local ColorSequenceKeypoint = api.ColorSequenceKeypoint
local Enum = api.Enum
local Instance = api.Instance
local NumberRange = api.NumberRange
local NumberSequence = api.NumberSequence
local NumberSequenceKeypoint = api.NumberSequenceKeypoint
local PhysicalProperties = api.PhysicalProperties
local Ray = api.Ray
local Rect = api.Rect
local Region3 = api.Region3
local TweenInfo = api.TweenInfo
local UDim = api.UDim
local UDim2 = api.UDim2
local Vector2 = api.Vector2
local Vector3 = api.Vector3

local function loadGeneratedCodec()
	-- @GENERATED_DATATYPES_SERVER@
end

local codec = loadGeneratedCodec()
local results = {}

local function record(name, value)
	table.insert(results, { name = name, value = value })
end

local function hex(bytes)
	local encoded = {}
	for offset = 0, buffer.len(bytes) - 1 do
		encoded[offset + 1] = string.format("%02x", buffer.readu8(bytes, offset))
	end
	return table.concat(encoded)
end

local function vector(value)
	return { value.X, value.Y, value.Z }
end

local function summarize(world)
	local custom = world.Custom
	local sequence = {}
	for _, keypoint in world.Size.Keypoints do
		table.insert(sequence, { keypoint.Time, keypoint.Value, keypoint.Envelope })
	end
	return {
		custom = if custom
			then {
				custom.Density,
				custom.Friction,
				custom.Elasticity,
				custom.FrictionWeight,
				custom.ElasticityWeight,
				custom.AcousticAbsorption,
			}
			else nil,
		sequence = sequence,
		clip = { world.Clip.Min.X, world.Clip.Min.Y, world.Clip.Max.X, world.Clip.Max.Y },
		zoneCenter = vector(world.Zone.CFrame.Position),
		zoneSize = vector(world.Zone.Size),
		rayOrigin = vector(world.Aim.Origin),
		rayDirection = vector(world.Aim.Direction),
	}
end

local function roundTrip(name, world)
	local bytes = codec.World.Write(world)
	local decoded = codec.World.Read(bytes)
	record(`{name}_length`, buffer.len(bytes))
	record(`{name}_hex`, hex(bytes))
	record(`{name}_decoded`, summarize(decoded))
	return bytes
end

local world = {
	Custom = PhysicalProperties.new(2, 0.5, 0.25, 1, 1, 0.5),
	Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0, 0),
		NumberSequenceKeypoint.new(0.5, 1.5, 0.25),
		NumberSequenceKeypoint.new(1, 4, 0.5),
	}),
	Clip = Rect.new(-1.5, 2, 30.25, 40),
	Zone = Region3.new(Vector3.new(-8, 0, -8), Vector3.new(8, 16, 8)),
	Aim = Ray.new(Vector3.new(0, 5, 0), Vector3.new(0, -50, 0)),
}

local fullBytes = roundTrip("world", world)
local bare = table.clone(world)
bare.Custom = nil
bare.Clip = Rect.new(0, 0, 100, 50)
bare.Aim = Ray.new(Vector3.new(1, -2.5, 3), Vector3.new(-4, 5.75, -6))
roundTrip("bare", bare)

-- A second write after a shorter one checks that the generated Save/Load state restoration does not
-- retain a previous buffer or cursor. Its bytes must be identical to the first write.
record("repeat_hex", hex(codec.World.Write(world)))
record("repeat_matches", hex(codec.World.Write(world)) == hex(fullBytes))

local truncated = buffer.create(4)
buffer.copy(truncated, 0, fullBytes, 0, 4)
record("truncated_rejected", not pcall(codec.World.Read, truncated))

print("BLINKBLOX_OCALE:" .. api.jsonEncode(results))
