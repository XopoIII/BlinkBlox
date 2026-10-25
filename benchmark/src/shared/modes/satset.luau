--> Definition.blink's benches as Satset packets, each behind `Fire` and `On` as BlinkBlox's are.
--> Satset's limits are lifted here as QuickNet's and Warp's are where they download: its server
--> charges a token a remote call, 1000 at most and 500 a second, and drops the call once they run
--> out; the bench makes a remote call a frame of up to 600 KB. Its batching is left as it ships --
--> no cap on batches a frame, and an unreliable batch split at 900 bytes, which no bench here uses.
local Satset = require("../../../packages/satset")
local Types = Satset.Types

Satset.start({
	guard = { maxTokens = math.huge, refillRate = math.huge, studioBypass = true },
	batching = { reliableThreshold = 0, maxPacketsPerFrame = 0 },
})

--> A packet's schema is a struct of named fields, so each value goes in a field of its own.
local function Event(Name: string, Value: any)
	local Packet = Satset.definePacket({
		name = Name,
		schema = { value = Value },
		reliable = true,
	})
	local Wrapper = { value = nil :: any }
	return {
		Fire = function(Value)
			Wrapper.value = Value
			Packet:fireServer(Wrapper)
		end,
		On = function(Callback)
			Packet:listenServer(function(Player, Data)
				Callback(Player, Data.value)
			end)
		end,
	}
end

local Entity = Satset.struct({
	id = Types.u8,
	x = Types.u8,
	y = Types.u8,
	z = Types.u8,
	orientation = Types.u8,
	animation = Types.u8,
})

return {
	Booleans = Event("Booleans", Types.array(Types.bool)),
	Entities = Event("Entities", Types.array(Entity)),
	BooleansRandom = Event("BooleansRandom", Types.array(Types.bool)),
	EntitiesRandom = Event("EntitiesRandom", Types.array(Entity)),
	--> Runtime.luau's alone, as BlinkBlox's Tiny is; Studio has no bench of this name.
	Tiny = Event("Tiny", Types.u8),
}
