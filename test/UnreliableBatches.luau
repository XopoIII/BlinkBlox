--!strict
--- Specs for unreliable batches (Generator/Batches.luau): a frame's unreliable events gathered into as
--- few packets as the unreliable limit allows and sent at the flush, rather than one remote call each.
--- Streams are always batched; ordinary events under `option BatchUnreliable`.
local Assertions = require("./Assertions")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local Support = require("./StreamSupport")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure
local Expect = Support.Expect

local Built = 0
local function Build(Schema: string): Isolated.Pair
	Built += 1
	return Isolated.Build(Isolated.Parse(Schema), `BATCHES{Built}`)
end

RunClosure("Streams due in the same frame go out in one packet", function()
	local Pair = Build([[
event Speed { From: Server, Type: OrderedUnreliable, Call: SingleSync, Stream: { Rate: 10 }, Data: f64 }
event Heat { From: Server, Type: OrderedUnreliable, Call: SingleSync, Stream: { Rate: 10 }, Data: u8 }
]])
	Pair.Server.StepReplication()

	local Heard: { string } = {}
	Pair.Client.Speed.On(function(Value)
		table.insert(Heard, `Speed {Value}`)
	end)
	Pair.Client.Heat.On(function(Value)
		table.insert(Heard, `Heat {Value}`)
	end)

	Pair.Server.Speed.Set(1.5)
	Pair.Server.Heat.Set(7)
	Shared.AdvanceClock(1 / 60)
	Pair.Server.StepReplication()

	assert(#Pair.Outbound == 1, `the two streams went out in {#Pair.Outbound} packets, expected one`)
	assert(Pair.Outbound[1].Player == nil, "the streams' packet was not sent to everyone at once")
	Pair.Deliver(Pair.Outbound[1])
	Expect("heard", Heard, { "Speed 1.5", "Heat 7" })
end)

local BATCHED = [[
option BatchUnreliable = true
option MaxEventsPerPacket = 4

event Move { From: Client, Type: Unreliable, Call: ManySync, Data: u8 }
event Note { From: Client, Type: Unreliable, Call: ManySync, Data: string(..400) }
event Tick { From: Server, Type: Unreliable, Call: ManySync, Data: u8 }
event Aim { From: Server, Type: OrderedUnreliable, Call: ManySync, Data: u8 }
]]

--- Every packet the client sent, handed to the server; what the server heard, in order.
local function FeedAll(Pair: Isolated.Pair): { string }
	local Heard: { string } = {}
	Pair.Server.Move.On(function(_Player, Value)
		table.insert(Heard, `Move {Value}`)
	end)
	Pair.Server.Note.On(function(_Player, Value)
		table.insert(Heard, `Note {#Value}`)
	end)
	for _, Packet in Pair.SentUnreliable do
		Pair.Feed(false, Packet.Buffer, Packet.Instances)
	end
	task.wait(0.2)
	return Heard
end

RunClosure("A client's unreliable events wait for the flush and go out together", function()
	local Pair = Build(BATCHED)
	for Value = 1, 3 do
		Pair.Client.Move.Fire(Value)
	end
	assert(#Pair.SentUnreliable == 0, "an unreliable event went out before the flush")

	Pair.Client.StepReplication()
	assert(#Pair.SentUnreliable == 1, `sent {#Pair.SentUnreliable} packets, expected one`)
	Expect("heard", FeedAll(Pair), { "Move 1", "Move 2", "Move 3" })
end)

RunClosure("A client's unreliable batch is cut at the server's event cap", function()
	local Pair = Build(BATCHED)
	for Value = 1, 10 do
		Pair.Client.Move.Fire(Value)
	end
	Pair.Client.StepReplication()

	local Sizes = {}
	for _, Packet in Pair.SentUnreliable do
		table.insert(Sizes, buffer.len(Packet.Buffer))
	end
	--> Two bytes an event, four events a packet.
	Expect("packet sizes", Sizes, { 8, 8, 4 })
	assert(#FeedAll(Pair) == 10, "the server did not hear every event")
end)

RunClosure("A client's unreliable batch is cut before an event that would take it past the limit", function()
	local Pair = Build(BATCHED)
	for _ = 1, 3 do
		Pair.Client.Note.Fire(string.rep("x", 400))
	end
	Pair.Client.StepReplication()

	--> An index, a two-byte varint length and 400 bytes: two fit under 980, three do not.
	local Sizes = {}
	for _, Packet in Pair.SentUnreliable do
		table.insert(Sizes, buffer.len(Packet.Buffer))
		assert(buffer.len(Packet.Buffer) <= 980, `a packet of {buffer.len(Packet.Buffer)} bytes went out`)
	end
	Expect("packet sizes", Sizes, { 806, 403 })
	Expect("heard", FeedAll(Pair), { "Note 400", "Note 400", "Note 400" })
end)

RunClosure("A server's unreliable events to everyone go out in one FireAllClients a frame", function()
	local Pair = Build(BATCHED)
	local Heard: { number } = {}
	Pair.Client.Tick.On(function(Value)
		table.insert(Heard, Value)
	end)

	for Value = 1, 3 do
		Pair.Server.Tick.FireAll(Value)
	end
	assert(#Pair.Outbound == 0, "an unreliable event went out before the flush")
	Pair.Server.StepReplication()

	assert(#Pair.Outbound == 1 and Pair.Outbound[1].Player == nil, "the events did not go out in one FireAllClients")
	Pair.Deliver(Pair.Outbound[1])
	Expect("heard", Heard, { 1, 2, 3 })
end)

RunClosure("An ordered event in a batch carries the player's own sequence", function()
	local Pair = Build(BATCHED)
	local Heard: { number } = {}
	Pair.Client.Aim.On(function(Value)
		table.insert(Heard, Value)
	end)

	Pair.Server.Aim.FireAll(1)
	Pair.Server.Aim.Fire(Shared.Player, 2)
	Pair.Server.StepReplication()
	Pair.Server.Aim.FireAll(3)
	Pair.Server.StepReplication()

	assert(#Pair.Outbound == 2, `sent {#Pair.Outbound} packets over two frames, expected two`)
	for _, Packet in Pair.Outbound do
		assert(Packet.Player == Shared.Player, "an ordered event went to everyone at once")
	end

	--> The second frame's packet first: the first frame's then arrives stale, and both its events go.
	Pair.Deliver(Pair.Outbound[2])
	Pair.Deliver(Pair.Outbound[1])
	Expect("heard", Heard, { 3 })
end)

--> A mock Instance the generated code accepts: `typeof` reads `__typeof` in the test environment.
local function MockInstance(Name: string): any
	return {
		__typeof = "Instance",
		Name = Name,
		IsA = function()
			return true
		end,
	}
end

local DIRECT = [[
option BatchUnreliable = true

event Big { From: Server, Type: Unreliable, Call: ManySync, Data: string(..600) }
event Touch { From: Server, Type: Unreliable, Call: ManySync, Data: (Instance, string(..4)) }
]]

RunClosure("An event that would overflow its player's batch sends what came before it first", function()
	local Pair = Build(DIRECT)
	local Heard: { number } = {}
	Pair.Client.Big.On(function(Value)
		table.insert(Heard, #Value)
	end)

	--> An index, a two-byte varint length and 500 bytes: 503 each, and two do not fit under 980.
	Pair.Server.Big.Fire(Shared.Player, string.rep("a", 500))
	Pair.Server.Big.Fire(Shared.Player, string.rep("b", 500))
	assert(#Pair.Outbound == 1, `{#Pair.Outbound} packets went out before the flush, expected the first`)
	Pair.Server.StepReplication()

	local Sizes = {}
	for _, Packet in Pair.Outbound do
		table.insert(Sizes, buffer.len(Packet.Buffer))
		Pair.Deliver(Packet)
	end
	Expect("packet sizes", Sizes, { 503, 503 })
	Expect("heard", Heard, { 500, 500 })
end)

RunClosure("A send that throws leaves no Instance behind in the batch it was written into", function()
	local Pair = Build(DIRECT)
	local Heard: { string } = {}
	Pair.Client.Touch.On(function(Part, Label)
		table.insert(Heard, `{Part.Name} {Label}`)
	end)

	--> The Instance goes into the batch before the string is refused for its length.
	local Kept, Dropped = MockInstance("Kept"), MockInstance("Dropped")
	assert(not pcall(Pair.Server.Touch.Fire, Shared.Player, Dropped, "too long"), "a string past its bound was sent")
	Pair.Server.Touch.Fire(Shared.Player, Kept, "ok")
	Pair.Server.StepReplication()

	assert(#Pair.Outbound == 1, `sent {#Pair.Outbound} packets, expected one`)
	local Packet = Pair.Outbound[1]
	assert(#Packet.Instances == 1 and Packet.Instances[1] == Kept, "the refused event's Instance was sent")
	Pair.Deliver(Packet)
	Expect("heard", Heard, { "Kept ok" })
end)

return {}
