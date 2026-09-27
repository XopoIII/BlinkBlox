--> Scenarios.blink's events as Packet packets; see benchmark/Rivals.luau. Packet has no unreliable
--> channel, so it runs only the reliable scenarios. A boolean is a Boolean8, a byte of its own.
local Packet = require("../../../packages/packet")

local UNIT = {
	id = Packet.NumberU16,
	x = Packet.NumberF32,
	y = Packet.NumberF32,
	z = Packet.NumberF32,
	health = Packet.NumberU8,
	moving = Packet.Boolean8,
	crouched = Packet.Boolean8,
}

return {
	Snapshot = Packet("Snapshot", UNIT),
	Touch = Packet("Touch", Packet.Instance, Packet.NumberU8),
}
