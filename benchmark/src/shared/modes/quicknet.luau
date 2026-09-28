--> Definition.blink's benches as QuickNet events, each behind `Fire` and `On` as BlinkBlox's are.
--> QuickNet lets a player send an event 60 times a second by default, and the bench sends it 60,000
--> times; its own benchmark raises the limit on each event the same way.
local QuickNet = require("../../../packages/quicknet")
local Data = QuickNet.Data

local function Event(Name: string, Schema: any)
	local Object = QuickNet:register(Name, Schema):SetRateLimit(math.huge, 1)
	return {
		Fire = function(Value)
			Object:FireServer(Value)
		end,
		On = function(Callback)
			Object.OnServerEvent:Connect(Callback)
		end,
	}
end

--> A schema per event: QuickNet rewrites the tables it is given.
local function Booleans()
	return { Data.Boolean }
end

local function Entities()
	return {
		{
			id = Data.NumberU8,
			x = Data.NumberU8,
			y = Data.NumberU8,
			z = Data.NumberU8,
			orientation = Data.NumberU8,
			animation = Data.NumberU8,
		},
	}
end

return {
	Booleans = Event("Booleans", Booleans()),
	Entities = Event("Entities", Entities()),
	BooleansRandom = Event("BooleansRandom", Booleans()),
	EntitiesRandom = Event("EntitiesRandom", Entities()),
}
