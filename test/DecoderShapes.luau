--!strict
--- Specs for the shape of a channel's decoder (Packets.CloseDecode). A channel whose events read no
--- Instance and run no loop holds the decode loop; one that reads an Instance or an array stays a
--- function the loop calls once an event. Either way a branch that leaves its event -- a refused call, a missing Instance -- must go
--- on with the packet's next event: in the held loop it continues, and a `return` there would drop
--- the rest of the packet.
local Assertions = require("./Assertions")
local Generator = require("../src/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local PLAIN = [[
function Price { Yield: Coroutine, Rate: 1, Burst: 1, Data: u8, Return: u8 }
event After { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
]]

local WITH_INSTANCE = [[
event Touch { From: Client, Type: Reliable, Call: SingleSync, Data: Instance }
event After { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
]]

--> The array sits inside an optional struct: a loop anywhere in what an event reads counts
local WITH_ARRAY = [[
event List { From: Client, Type: Reliable, Call: SingleSync, Data: struct { Items: u8[..4] }? }
event After { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
]]

local function Expect(Condition: boolean, Message: string)
	if not Condition then
		ErrorPrint(`Failed "decoder shapes": {Message}`)
	end
end

RunClosure("A channel holds its decode loop unless its events read an Instance or run a loop", function()
	local Plain = Generator.Generate("Server", Isolated.Parse(PLAIN))
	Expect(
		string.find(Plain, "local function DecodeReliable(Player: Player, Size: number): ()", 1, true) ~= nil,
		"a channel with no Instance does not hold its loop"
	)
	Expect(string.find(Plain, "local function DecodeLoop(", 1, true) == nil, "DecodeLoop is emitted with no use")

	local Touched = Generator.Generate("Server", Isolated.Parse(WITH_INSTANCE))
	Expect(
		string.find(Touched, "local function DecodeReliable(Player: Player): ()", 1, true) ~= nil,
		"a channel that reads an Instance is not a function the loop calls"
	)
	Expect(
		string.find(Touched, "pcall(DecodeLoop, DecodeReliable, Player, Size)", 1, true) ~= nil,
		"the connection does not hand that channel to DecodeLoop"
	)

	local Listed = Generator.Generate("Server", Isolated.Parse(WITH_ARRAY))
	Expect(
		string.find(Listed, "pcall(DecodeLoop, DecodeReliable, Player, Size)", 1, true) ~= nil,
		"a channel whose event reads an array holds the loop around it"
	)

	for _, Source in { Plain, Touched, Listed } do
		Expect(string.find(Source, "next event", 1, true) == nil, "a branch's exit marker reached the output")
	end
end)

RunClosure("A refused call in a channel that holds its loop goes on with the packet's next event", function()
	local Pair = Isolated.Build(Isolated.Parse(PLAIN), "DECODERSHAPES")
	local Server, Client = Pair.Server, Pair.Client
	Shared.AdvanceClock(10)
	local Refusals = 0
	Server.SetRateLimitHandler(function()
		Refusals += 1
	end)

	local Heard: { number } = {}
	Server.After.On(function(_Player, Value)
		table.insert(Heard, Value)
	end)
	Server.Price.On(function(_Player, Value)
		return Value
	end)

	local Outcome = { Answered = 0, Refused = 0 }
	for _ = 1, 2 do
		task.spawn(function()
			if pcall(Client.Price.Invoke, 1) then
				Outcome.Answered += 1
			else
				Outcome.Refused += 1
			end
		end)
	end
	--> The calls are written once their threads run; the event after them, so it follows the refused one
	task.wait()
	Client.After.Fire(7)

	--> Both calls and the event go in one packet, the refused call between the first and the event
	table.clear(Pair.Sent)
	Client.StepReplication()
	Expect(#Pair.Sent == 1, `one flush sent {#Pair.Sent} packets`)
	Pair.Feed(true, Pair.Sent[1].Buffer, Pair.Sent[1].Instances)
	local Bytes = Pair.Sent[1].Buffer
	Expect(Refusals == 1, `{Refusals} calls refused, expected the second`)
	Expect(buffer.readu8(Bytes, buffer.len(Bytes) - 1) == 7, "the event is not the packet's last")
	Expect(#Heard == 1 and Heard[1] == 7, `the event after a refused call was heard {#Heard} times`)

	table.clear(Pair.Delivered)
	Server.StepReplication()
	for _, Packet in Pair.Delivered do
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end
	task.wait(0.1)
	Expect(
		Outcome.Answered == 1 and Outcome.Refused == 1,
		`{Outcome.Answered} calls answered and {Outcome.Refused} refused, expected one of each`
	)
end)

return {}
