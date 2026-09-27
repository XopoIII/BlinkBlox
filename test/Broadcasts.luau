--!strict
--- Specs for the server's broadcast batch: a reliable FireAll is written once and sent to everyone in
--- one FireAllClients, and a player's own events keep their order against the broadcasts around them.
local Assertions = require("./Assertions")
local Isolated = require("./Isolated")
local Shared = require("./Shared")

local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Note { From: Server, Type: Reliable, Call: ManySync, Data: u8 }
]]

local Built = 0

--- A fresh pair, `Send` run on its server and the server flushed, and every packet it sent handed to
--- its client. What the client received, in order, and the pair: `Replies` holds what went to one
--- player, `Delivered` that and every FireAllClients.
local function Frame(Send: (Server: any) -> ()): ({ number }, Isolated.Pair)
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), `BROADCASTS{Built}`)

	local Received: { number } = {}
	Pair.Client.Note.On(function(Value)
		table.insert(Received, Value)
	end)

	Send(Pair.Server)
	Pair.Server.StepReplication()
	for _, Packet in Pair.Delivered do
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end

	return Received, Pair
end

local function Expect(What: string, Got: { any }, Expected: { any })
	local Left, Right = {}, {}
	for Index, Value in Got do
		Left[Index] = tostring(Value)
	end
	for Index, Value in Expected do
		Right[Index] = tostring(Value)
	end

	local Shown, Wanted = table.concat(Left, ", "), table.concat(Right, ", ")
	assert(Shown == Wanted, `{What}: got \{{Shown}\}, expected \{{Wanted}\}`)
end

RunClosure("A frame of broadcasts goes out as one FireAllClients", function()
	local Received, Pair = Frame(function(Server)
		for Value = 1, 3 do
			Server.Note.FireAll(Value)
		end
	end)

	Expect("received", Received, { 1, 2, 3 })
	assert(#Pair.Delivered == 1 and #Pair.Replies == 0, "the broadcasts did not go out as one FireAllClients")
end)

RunClosure("A player's own events keep their order against the broadcasts around them", function()
	local Received = Frame(function(Server)
		Server.Note.Fire(Shared.Player, 1)
		Server.Note.FireAll(2)
		Server.Note.Fire(Shared.Player, 3)
		Server.Note.FireAll(4)
		Server.Note.FireList({ Shared.Player }, 5)
		Server.Note.FireAll(6)
	end)

	Expect("received", Received, { 1, 2, 3, 4, 5, 6 })
end)

RunClosure("A player's own events before the first broadcast arrive ahead of it", function()
	local Received = Frame(function(Server)
		Server.Note.Fire(Shared.Player, 1)
		Server.Note.Fire(Shared.Player, 2)
		Server.Note.FireAll(3)
	end)

	Expect("received", Received, { 1, 2, 3 })
end)

RunClosure("The broadcast batch is empty after the flush", function()
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), `BROADCASTS{Built}`)
	local Received: { number } = {}
	Pair.Client.Note.On(function(Value)
		table.insert(Received, Value)
	end)

	Pair.Server.Note.FireAll(1)
	Pair.Server.StepReplication()
	Pair.Server.Note.Fire(Shared.Player, 2)
	Pair.Server.StepReplication()

	for _, Packet in Pair.Delivered do
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end

	Expect("received", Received, { 1, 2 })
	assert(#Pair.Delivered == 2, `sent {#Pair.Delivered} packets over two frames, expected two`)
end)

return {}
