--> Definition.blink's benches as Warp events with schemas, each behind `Fire` and `On` as BlinkBlox's
--> are. Warp names an event by string on every call, and its client learns the ids from the server:
--> the server registers every schema as it loads, and a client's event is built on first use, once
--> the ids have arrived.
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

return setmetatable({}, {
	__index = function(Self, Name: string)
		local Definition = SCHEMAS[Name]
		if not Definition then
			return nil
		end
		if not IsServer then
			Side.awaitReady()
			Side.useSchema(Name, Definition)
		end

		local Event = {
			Fire = function(Value)
				Side.Fire(Name, true, Value)
			end,
			On = function(Callback)
				Side.Connect(Name, Callback)
			end,
		}
		rawset(Self, Name, Event)
		return Event
	end,
})
