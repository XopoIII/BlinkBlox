--> Definition.blink's benches as Warp events with schemas, each behind `Fire` and `On` as BlinkBlox's
--> are. Warp names an event by string on every call, and its client learns the ids from the server:
--> the server registers every schema as it loads, and a client registers its own on first use, once
--> the ids have arrived. That wait yields, so it happens in `Fire` and `On` and not in an `__index`:
--> Studio's client reached the events before the ids came, and a metamethod cannot yield.
local Warp = require("../../../packages/warp")

local IsServer = game:GetService("RunService"):IsServer()
local Side = if IsServer then Warp.Server() else Warp.Client()
local Schema = Side.Schema

local function Entities()
	return Schema.array(Schema.struct({
		id = Schema.u8,
		x = Schema.u8,
		y = Schema.u8,
		z = Schema.u8,
		orientation = Schema.u8,
		animation = Schema.u8,
	}))
end

local SCHEMAS = {
	Booleans = Schema.array(Schema.boolean),
	Entities = Entities(),
	BooleansRandom = Schema.array(Schema.boolean),
	EntitiesRandom = Entities(),
}

if IsServer then
	for Name, Definition in SCHEMAS do
		Side.useSchema(Name, Definition)
	end
end

local Ready = IsServer
local function AwaitReady()
	Side.awaitReady()
	for Name, Definition in SCHEMAS do
		Side.useSchema(Name, Definition)
	end
	Ready = true
end

local Events = {}
for Name in SCHEMAS do
	Events[Name] = {
		Fire = function(Value)
			if not Ready then
				AwaitReady()
			end
			Side.Fire(Name, true, Value)
		end,
		On = function(Callback)
			if not Ready then
				AwaitReady()
			end
			Side.Connect(Name, Callback)
		end,
	}
end

return Events
