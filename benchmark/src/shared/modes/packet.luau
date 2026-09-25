local Packet = require("../../../packages/packet")

--> Packet has no packed boolean array: `Boolean1` is a group of exactly eight, so a thousand booleans
--> are an array of `Boolean8`, one byte each, as ByteNet's `array(bool)` is.
local function Booleans()
	return { Packet.Boolean8 }
end

local function Entities()
	return {
		{
			id = Packet.NumberU8,
			x = Packet.NumberU8,
			y = Packet.NumberU8,
			z = Packet.NumberU8,
			orientation = Packet.NumberU8,
			animation = Packet.NumberU8,
		},
	}
end

return {
	Booleans = Packet("Booleans", Booleans()),
	Entities = Packet("Entities", Entities()),
	BooleansRandom = Packet("BooleansRandom", Booleans()),
	EntitiesRandom = Packet("EntitiesRandom", Entities()),
}
