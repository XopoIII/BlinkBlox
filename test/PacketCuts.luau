--!strict
--- Specs for the client cutting its reliable batch into packets the server takes.
---
--- The server refuses a packet past MaxPacketSize, MaxEventsPerPacket or MaxInstancesPerPacket and
--- reports the player to the game's packet-drop handler, which a game may strike or ban on. A client
--- used to send a frame's events as one packet whatever the limits, so an honest player who fired
--- more in one frame than a packet may carry -- after a hitch, from a busy interface -- was refused
--- and reported as though hostile. Each packet the client sends now fits, and is cut at an event.
---
--- The limits are small enough to reach cheaply, as PacketDrops.luau's are; the budget is raised out
--- of the way, since it is not what these specs are about.
local Assertions = require("./Assertions")
local Isolated = require("./Isolated")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option MaxPacketSize = 256
option MaxEventsPerPacket = 4
option MaxInstancesPerPacket = 2
option InboundBytesPerSecond = 1048576

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Note { From: Client, Type: Reliable, Call: ManySync, Data: string(..200) }
event Touch { From: Client, Type: Reliable, Call: ManySync, Data: Instance }
]]

local function MockInstance(Name: string): any
	return {
		__typeof = "Instance",
		Name = Name,
		IsA = function()
			return true
		end,
	}
end

local Built = 0

type Frame = { Sizes: { number }, Received: { string }, Drops: { string } }

--- A fresh pair; `Fire` fires one frame's events on its client, which is flushed, and every packet it
--- sent is handed to its server. What the packets were, what the server received, and what it refused.
local function Frame(Fire: (Client: any) -> ()): Frame
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), `CUTS{Built}`)

	local Received: { string } = {}
	Pair.Server.Byte.On(function(_Player, Value)
		table.insert(Received, `Byte {Value}`)
	end)
	Pair.Server.Note.On(function(_Player, Value)
		table.insert(Received, `Note {#Value}`)
	end)
	Pair.Server.Touch.On(function(_Player, Value)
		table.insert(Received, `Touch {Value.Name}`)
	end)

	local Drops: { string } = {}
	Pair.Server.SetPacketDropHandler(function(_Player, Reason)
		table.insert(Drops, Reason)
	end)

	Fire(Pair.Client)
	Pair.Client.StepReplication()

	local Sizes: { number } = {}
	for _, Packet in Pair.Sent do
		table.insert(Sizes, buffer.len(Packet.Buffer))
		Pair.Feed(true, Packet.Buffer, Packet.Instances)
	end
	task.wait(0.2)

	return { Sizes = Sizes, Received = Received, Drops = Drops }
end

local function Expect(What: string, Got: { any }, Expected: { any })
	local Shown, Wanted = {}, {}
	for Index, Value in Got do
		Shown[Index] = tostring(Value)
	end
	for Index, Value in Expected do
		Wanted[Index] = tostring(Value)
	end

	local Left, Right = table.concat(Shown, ", "), table.concat(Wanted, ", ")
	assert(Left == Right, `{What}: got \{{Left}\}, expected \{{Right}\}`)
end

RunClosure("A frame of more events than a packet takes is cut at the event cap", function()
	local Result = Frame(function(Client)
		for Value = 1, 10 do
			Client.Byte.Fire(Value)
		end
	end)

	--> Two bytes an event: its index and its value.
	Expect("packet sizes", Result.Sizes, { 8, 8, 4 })
	Expect("drops", Result.Drops, {})
	assert(#Result.Received == 10, `the server received {#Result.Received} of 10 events`)
	assert(Result.Received[10] == "Byte 10", `the last event was {Result.Received[10]}`)
end)

RunClosure("A frame of more bytes than a packet takes is cut before the event that overflows it", function()
	local Result = Frame(function(Client)
		for _ = 1, 3 do
			Client.Note.Fire(string.rep("x", 100))
		end
	end)

	--> An index, a one-byte length and a hundred bytes: two fit in 256, the third does not.
	Expect("packet sizes", Result.Sizes, { 204, 102 })
	Expect("drops", Result.Drops, {})
	Expect("received", Result.Received, { "Note 100", "Note 100", "Note 100" })
end)

RunClosure("A frame of more Instances than a packet takes is cut at the instance cap", function()
	local Result = Frame(function(Client)
		for Index = 1, 3 do
			Client.Touch.Fire(MockInstance(`Part{Index}`))
		end
	end)

	--> An Instance travels beside the buffer, so each event is its index alone.
	Expect("packet sizes", Result.Sizes, { 2, 1 })
	Expect("drops", Result.Drops, {})
	Expect("received", Result.Received, { "Touch Part1", "Touch Part2", "Touch Part3" })
end)

RunClosure("A Fire that throws between the others is left out and cuts nothing", function()
	local Result = Frame(function(Client)
		for Value = 1, 3 do
			Client.Byte.Fire(Value)
		end
		assert(not pcall(Client.Note.Fire, string.rep("x", 300)), "a note past its bound was sent")
		for Value = 4, 6 do
			Client.Byte.Fire(Value)
		end
	end)

	Expect("packet sizes", Result.Sizes, { 8, 4 })
	Expect("drops", Result.Drops, {})
	Expect("received", Result.Received, { "Byte 1", "Byte 2", "Byte 3", "Byte 4", "Byte 5", "Byte 6" })
end)

return {}
