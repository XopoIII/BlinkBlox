--> Scenarios.blink's events as Satset packets, each behind BlinkBlox's API -- `Fire`, `FireAll`, `On`
--> -- so Rivals.luau drives them as it does BlinkBlox; see benchmark/Rivals.luau. Satset batches each
--> player's packets a frame on its PostSimulation, one remote call a stream, and sends a reliable
--> FireAll as one broadcast. Its token bucket, a token a remote call, is lifted as in
--> src/shared/modes/satset.luau. It has no Instance type, so Touch is not declared and the Instances
--> scenario leaves Satset out, as the unreliable ones leave out Packet.
local Satset = require("../../../packages/satset")
local Types = Satset.Types

local IsServer = game:GetService("RunService"):IsServer()

Satset.start({
	guard = { maxTokens = math.huge, refillRate = math.huge, studioBypass = true },
	batching = { reliableThreshold = 0, maxPacketsPerFrame = 0 },
})

local UNIT = {
	id = Types.u16,
	x = Types.f32,
	y = Types.f32,
	z = Types.f32,
	health = Types.u8,
	moving = Types.bool,
	crouched = Types.bool,
}

--> `Wrapped` events carry their value in a field, as a packet's schema is always a struct.
local function Event(Name: string, Schema: any, Reliable: boolean, Wrapped: boolean)
	local Packet = Satset.definePacket({ name = Name, schema = Schema, reliable = Reliable })
	local Wrapper = { value = nil :: any }
	local function Payload(Value)
		if Wrapped then
			Wrapper.value = Value
			return Wrapper
		end
		return Value
	end

	if IsServer then
		return {
			Fire = function(Player, Value)
				Packet:fireClient(Player, Payload(Value))
			end,
			FireAll = function(Value)
				Packet:fireAllClients(Payload(Value))
			end,
			On = function(Callback)
				Packet:listenServer(function(Player, Data)
					Callback(Player, if Wrapped then Data.value else Data)
				end)
			end,
		}
	end
	return {
		Fire = function(Value)
			Packet:fireServer(Payload(Value))
		end,
		On = function(Callback)
			Packet:listen(function(Data)
				Callback(if Wrapped then Data.value else Data)
			end)
		end,
	}
end

return {
	Snapshot = Event("Snapshot", UNIT, true, false),
	Input = Event("Input", { move = Types.u8, turn = Types.i16, jump = Types.bool, sprint = Types.bool }, false, false),
	WorldState = Event("WorldState", { value = Types.array(Satset.struct(UNIT)) }, false, true),
	SelfState = Event("SelfState", UNIT, false, false),
}
