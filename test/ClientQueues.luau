--!strict
--- The client's queue for events and calls that arrive before a listener does.
---
--- It grew for as long as the server sent and printed a warning for every event past 256, so a client
--- that never listened to an event sent each frame filled its memory and its output together (zap's
--- #190 describes the same spiral). It stops at 256 now, as the server's does, and says so once.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Late { From: Server, Type: Reliable, Call: ManySync, Data: u16 }
]]

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "CLIENTQUEUES")
local Server = Pair.Server
local Client = Pair.Client

local function Expect(Condition: boolean, Message: string)
	if not Condition then
		ErrorPrint(Message)
	end
end

local function Deliver()
	table.clear(Pair.Delivered)
	Server.StepReplication()
	for _, Packet in Pair.Delivered do
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end
end

RunClosure("A client queue stops at 256, warns once, and replays what it kept", function()
	table.clear(Shared.Warnings)
	for Value = 1, 300 do
		Server.Late.Fire(Shared.Player, Value)
	end
	Deliver()

	local Warned = 0
	for _, Warning in Shared.Warnings do
		if string.find(Warning, '"Late" has 256 events waiting', 1, true) then
			Warned += 1
		end
	end
	Expect(Warned == 1, `{Warned} warnings for 44 events past the cap`)

	local Received: { number } = {}
	Client.Late.On(function(Value)
		table.insert(Received, Value)
	end)
	Expect(#Received == 256, `{#Received} events replayed, expected the 256 kept`)
	Expect(Received[1] == 1 and Received[256] == 256, "the queue kept other events than the first 256")
end)

return {}
