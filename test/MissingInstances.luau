--!strict
--- An Instance that does not arrive refuses its own event and nothing else.
---
--- An Instance the sender had can reach the other side as nil: not streamed in, not replicated there,
--- or destroyed before the packet was sent. Every read of a required Instance used to throw on that,
--- and the one pcall a packet has turned it into the loss of every event after it -- an honest
--- player's inputs, with StreamingEnabled on, several times a minute. The slot was read, so the
--- cursor is sound: only that event is refused, it is reported by name, and the packet goes on.
--- Anything that is neither an Instance nor nil in the slot is still a packet no sender writes.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Before { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Carry { From: Client, Type: Reliable, Call: ManySync, Data: (Instance, u8) }
event After { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Maybe { From: Client, Type: Reliable, Call: ManySync, Data: Instance? }
event Polled { From: Client, Type: Reliable, Call: Polling, Data: Instance }
event Down { From: Server, Type: Reliable, Call: ManySync, Data: Instance[] }
event DownAfter { From: Server, Type: Reliable, Call: ManySync, Data: u8 }
event Two { From: Client, Type: Reliable, Call: ManySync, Data: (Instance, Instance, u8) }
event Owners { From: Client, Type: Reliable, Call: ManySync, Data: map { [Instance]: u8 } }
event Many { From: Client, Type: Reliable, Call: ManySync, Data: Instance[] }
function Ask { Yield: Coroutine, Data: Instance, Return: u8 }
]]

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "MISSING")
local Server = Pair.Server
local Client = Pair.Client

local Part = roblox.Instance.new("Part")

local Received: { string } = {}
local function Record(Name: string)
	return function()
		table.insert(Received, Name)
	end
end
Server.Before.On(Record("Before"))
Server.Carry.On(Record("Carry"))
Server.After.On(Record("After"))
Server.Owners.On(Record("Owners"))
Server.Two.On(Record("Two"))
local CarriedPart: any = nil
Server.Carry.On(function(_Player, Value)
	CarriedPart = Value
end)
Server.Many.On(Record("Many"))
Server.Maybe.On(function(_Player, Value)
	table.insert(Received, if Value == nil then "Maybe nil" else "Maybe")
end)
Client.DownAfter.On(Record("DownAfter"))
Client.Down.On(Record("Down"))

local Reports: { { Event: string?, Failure: string } } = {}
Server.SetDecodeErrorHandler(function(_Player, Event, Failure)
	table.insert(Reports, { Event = Event, Failure = Failure })
end)

--- Flushes the client and returns the one packet it sent.
local function Flush(): Isolated.Packet
	table.clear(Pair.Sent)
	Client.StepReplication()
	if #Pair.Sent ~= 1 then
		error(`one flush sent {#Pair.Sent} packets`)
	end
	return Pair.Sent[1]
end

local function Expect(Condition: boolean, Message: string)
	if not Condition then
		ErrorPrint(Message)
	end
end

RunClosure("A missing Instance refuses its own event, and the packet goes on", function()
	table.clear(Received)
	table.clear(Reports)
	Client.Before.Fire(1)
	Client.Carry.Fire(Part, 2)
	Client.After.Fire(3)
	local Packet = Flush()
	Packet.Instances[1] = nil
	Pair.Feed(true, Packet.Buffer, Packet.Instances)

	Expect(table.concat(Received, ",") == "Before,After", `the server received {table.concat(Received, ",")}`)
	Expect(#Reports == 1, `{#Reports} reports for one missing Instance`)
	local Report = Reports[1]
	if Report then
		Expect(Report.Event == "Carry", `the refusal named "{Report.Event}"`)
		Expect(string.find(Report.Failure, "did not arrive", 1, true) ~= nil, `the refusal said "{Report.Failure}"`)
	end

	--> The next packet is not refused for the last one's missing Instance.
	table.clear(Received)
	Client.Carry.Fire(Part, 4)
	Packet = Flush()
	Pair.Feed(true, Packet.Buffer, Packet.Instances)
	Expect(table.concat(Received, ",") == "Carry", `the next packet delivered {table.concat(Received, ",")}`)
end)

RunClosure(
	"A map keyed by a missing Instance, and an array whose last one is missing, refuse only themselves",
	function()
		for _, Case in { "Owners", "Many" } do
			table.clear(Received)
			table.clear(Reports)
			if Case == "Owners" then
				Client.Owners.Fire({ [Part] = 1 })
			else
				Client.Many.Fire({ Part, Part })
			end
			Client.After.Fire(3)
			local Packet = Flush()
			Packet.Instances[#Packet.Instances] = nil
			Pair.Feed(true, Packet.Buffer, Packet.Instances)

			Expect(table.concat(Received, ",") == "After", `{Case}: the server received {table.concat(Received, ",")}`)
			Expect(#Reports == 1 and Reports[1].Event == Case, `{Case}: {#Reports} reports`)
		end
	end
)

RunClosure("An event refused where its first Instance is missing leaves the next event its own", function()
	--> A flat event is refused where the missing Instance is found, and the Instance cursor is moved
	--> past the slots it had not read yet; the next event must still get the part meant for it.
	table.clear(Received)
	table.clear(Reports)
	CarriedPart = nil
	local Other = roblox.Instance.new("Part")
	Client.Two.Fire(Part, Part, 1)
	Client.Carry.Fire(Other, 2)
	Client.After.Fire(3)
	local Packet = Flush()
	Packet.Instances[1] = nil
	Pair.Feed(true, Packet.Buffer, Packet.Instances)

	Expect(table.concat(Received, ",") == "Carry,After", `the server received {table.concat(Received, ",")}`)
	Expect(CarriedPart == Other, "the next event was handed another event's Instance")
	Expect(#Reports == 1 and Reports[1].Event == "Two", `{#Reports} reports`)
end)

RunClosure("Something other than an Instance in the slot still stops the packet", function()
	table.clear(Received)
	Client.Carry.Fire(Part, 2)
	Client.After.Fire(3)
	local Packet = Flush()
	Packet.Instances[1] = "not an instance"
	Pair.Feed(true, Packet.Buffer, Packet.Instances)
	Expect(#Received == 0, `a forged slot delivered {table.concat(Received, ",")}`)
end)

RunClosure("An absent optional Instance is delivered as nil, not refused", function()
	table.clear(Received)
	table.clear(Reports)
	Client.Maybe.Fire(Part)
	Client.After.Fire(3)
	local Packet = Flush()
	Packet.Instances[1] = nil
	Pair.Feed(true, Packet.Buffer, Packet.Instances)
	Expect(table.concat(Received, ",") == "Maybe nil,After", `the server received {table.concat(Received, ",")}`)
	Expect(#Reports == 0, `{#Reports} reports for an optional Instance`)
end)

RunClosure("A polled event missing an Instance is not queued", function()
	Client.Polled.Fire(Part)
	Client.After.Fire(5)
	local Packet = Flush()
	Packet.Instances[1] = nil
	table.clear(Received)
	Pair.Feed(true, Packet.Buffer, Packet.Instances)

	local Polled = 0
	for _ in Server.Polled.Iter() do
		Polled += 1
	end
	Expect(Polled == 0, `{Polled} polled rows for an event missing its Instance`)
	Expect(table.concat(Received, ",") == "After", `the server received {table.concat(Received, ",")}`)
end)

RunClosure("A call missing an Instance is answered with a failure at once", function()
	table.clear(Pair.Replies)
	local Ran = false
	Server.Ask.On(function(_Player, _Value)
		Ran = true
		return 1
	end)

	task.spawn(function()
		pcall(Client.Ask.Invoke, Part)
	end)
	local Packet = Flush()
	Packet.Instances[1] = nil
	Pair.Feed(true, Packet.Buffer, Packet.Instances)
	Server.StepReplication()

	Expect(not Ran, "the listener ran for a call missing its Instance")
	local Reply = Pair.Replies[#Pair.Replies]
	Expect(Reply ~= nil and buffer.len(Reply.Buffer) == 3, "no three-byte failure reply was sent")
	if Reply then
		Expect(buffer.readu8(Reply.Buffer, 2) == 0, "the reply does not say the call failed")
	end
end)

RunClosure("On the client, a missing Instance warns once an event and the rest is delivered", function()
	table.clear(Received)
	table.clear(Shared.Warnings)
	for _ = 1, 2 do
		table.clear(Pair.Delivered)
		Server.Down.Fire(Shared.Player, { Part, Part })
		Server.DownAfter.Fire(Shared.Player, 7)
		Server.StepReplication()
		local Packet = Pair.Delivered[#Pair.Delivered]
		Packet.Instances[2] = nil
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end

	Expect(table.concat(Received, ",") == "DownAfter,DownAfter", `the client received {table.concat(Received, ",")}`)
	local Warned = 0
	for _, Warning in Shared.Warnings do
		if string.find(Warning, '"Down"', 1, true) and string.find(Warning, "did not arrive", 1, true) then
			Warned += 1
		end
	end
	Expect(Warned == 1, `{Warned} warnings for two drops of the same event`)
end)

return {}
