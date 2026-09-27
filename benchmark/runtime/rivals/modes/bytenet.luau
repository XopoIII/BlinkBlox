--> Scenarios.blink's events as ByteNet packets; see benchmark/Rivals.luau. ByteNet batches both of
--> its channels per frame and sends to everyone through one FireAllClients.
local ByteNet = require("../../../packages/bytenet")

local function Unit()
	return ByteNet.struct({
		id = ByteNet.uint16,
		x = ByteNet.float32,
		y = ByteNet.float32,
		z = ByteNet.float32,
		health = ByteNet.uint8,
		moving = ByteNet.bool,
		crouched = ByteNet.bool,
	})
end

return ByteNet.defineNamespace("Scenarios", function()
	return {
		Snapshot = ByteNet.definePacket({ value = Unit() }),
		Input = ByteNet.definePacket({
			value = ByteNet.struct({
				move = ByteNet.uint8,
				turn = ByteNet.int16,
				jump = ByteNet.bool,
				sprint = ByteNet.bool,
			}),
			reliabilityType = "unreliable",
		}),
		Touch = ByteNet.definePacket({
			value = ByteNet.struct({ part = ByteNet.inst, force = ByteNet.uint8 }),
		}),
		WorldState = ByteNet.definePacket({ value = ByteNet.array(Unit()), reliabilityType = "unreliable" }),
		SelfState = ByteNet.definePacket({ value = Unit(), reliabilityType = "unreliable" }),
	}
end)
