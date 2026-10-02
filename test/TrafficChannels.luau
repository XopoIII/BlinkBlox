--!strict
--- Specs for what `option TrafficStats` counts on the reliable channel: every packet the flush sends,
--- whichever remote call sends it, so a channel's bytes are never fewer than its events'.
---
--- The server's flush has three calls: a player's own batch, the broadcast batch to everyone in one
--- FireAllClients, and the broadcast batch to each player who did not take it in their own. Only the
--- first was counted, so a game that mostly broadcast saw an event's bytes pass its whole channel's.
--- The client's flush has two, and the one that sends a batch cut into packets was not counted.
---
--- The server specs run with a Players service of their own, holding as many players as each needs;
--- the mock every other spec gets has one. What went on the wire is read off the stub remote: a
--- FireClient lands in `Replies` and `Delivered`, a FireAllClients in `Delivered` alone.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SERVER_SCHEMA = [[
option TrafficStats = true

event Push { From: Server, Type: Reliable, Call: ManySync, Data: u8 }
event Feed { From: Server, Type: Reliable, Call: ManySync, Data: string(0..40) }
]]

local CLIENT_SCHEMA = [[
option TrafficStats = true
option MaxEventsPerPacket = 4

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
]]

--- A player the generated server takes: a userdata, as a table is refused as a `:` call.
local function NewPlayer(Name: string): any
	local Player = newproxy(true)
	local Fields: { [string]: any } = {
		Name = Name,
		Parent = { Name = "Players" },
		IsDescendantOf = function()
			return true
		end,
	}
	getmetatable(Player).__index = Fields
	return Player
end

local Built = 0

--- A server of its own with `Count` players in the game, and those players.
local function Serve(Count: number): (Isolated.Pair, { any })
	local InGame: { any } = {}
	for Index = 1, Count do
		table.insert(InGame, NewPlayer(`Player{Index}`))
	end

	local Players = {
		PlayerAdded = Shared.Signal.new(),
		PlayerRemoving = Shared.Signal.new(),
		MaxPlayers = math.max(Count, 1),
		GetPlayers = function(_self)
			return table.clone(InGame)
		end,
	}
	local Game = {
		GetService = function(_self, Service: string)
			if Service == "Players" then
				return Players
			end
			return ServerEnvironment.game:GetService(Service)
		end,
	}

	Built += 1
	return Isolated.Build(Isolated.Parse(SERVER_SCHEMA), `CHANNELS{Built}`, false, { game = Game }), InGame
end

local function Lengths(Packets: { Isolated.Packet }): (string, number)
	local Sizes: { number } = {}
	local Total = 0
	for _, Packet in Packets do
		table.insert(Sizes, buffer.len(Packet.Buffer))
		Total += buffer.len(Packet.Buffer)
	end

	table.sort(Sizes)
	return table.concat(Sizes, ", "), Total
end

local function Same(Label: string, Got: any, Expected: any)
	if Got ~= Expected then
		ErrorPrint(`Failed "{Label}": got {Got}, expected {Expected}.`)
	end
end

--- Fails unless the channel's sent counts are exactly these, it received nothing, and no event claims
--- more bytes than the channel that carried it.
local function Channel(Label: string, Stats: any, Sent: number, SentBytes: number)
	local Reliable = Stats.Reliable
	Same(`{Label}: reliable packets`, Reliable.Sent, Sent)
	Same(`{Label}: reliable bytes`, Reliable.SentBytes, SentBytes)
	Same(`{Label}: reliable packets received`, Reliable.Received, 0)
	Same(`{Label}: reliable bytes received`, Reliable.ReceivedBytes, 0)
	Same(`{Label}: unreliable packets`, Stats.Unreliable.Sent, 0)
	Same(`{Label}: unreliable bytes`, Stats.Unreliable.SentBytes, 0)

	local Events = 0
	for Name, Counts in Stats.Events do
		Events += Counts.SentBytes
		if Counts.SentBytes > Reliable.SentBytes then
			ErrorPrint(`Failed "{Label}": {Name} sent {Counts.SentBytes} bytes, its channel {Reliable.SentBytes}.`)
		end
	end
	Same(`{Label}: the events' bytes together`, Events, SentBytes)
end

--- Fails unless the remote was fired as said: `Singles` the sorted sizes of the packets sent to one
--- player, `Broadcasts` those sent to everyone. Returns the bytes that went on the wire with
--- `Players` in the game, a broadcast counting once for each.
local function Wire(Label: string, Pair: Isolated.Pair, Players: number, Singles: string, Broadcasts: number): number
	local Sizes, Single = Lengths(Pair.Replies)
	local _, All = Lengths(Pair.Delivered)
	Same(`{Label}: packets to one player`, Sizes, Singles)
	Same(`{Label}: FireAllClients calls`, #Pair.Delivered - #Pair.Replies, Broadcasts)
	return Single + (All - Single) * Players
end

RunClosure("A frame of nothing but FireAll counts the broadcast batch once per player", function()
	local Pair = Serve(3)
	local Server = Pair.Server
	for Value = 1, 5 do
		Server.Push.FireAll(Value)
	end

	--> The events are counted as they are fired, the packets by the flush that sends them.
	local Before = Server.GetTrafficStats()
	Same("Push events before the flush", Before.Events.Push.Sent, 15)
	Same("Push bytes before the flush", Before.Events.Push.SentBytes, 30)
	Same("reliable packets before the flush", Before.Reliable.Sent, 0)
	Same("reliable bytes before the flush", Before.Reliable.SentBytes, 0)

	Server.StepReplication()

	--> One FireAllClients of five two-byte events, which each of three players is sent.
	Same("bytes on the wire", Wire("broadcast", Pair, 3, "", 1), 30)
	Same("the broadcast's size", buffer.len(Pair.Delivered[1].Buffer), 10)

	local After = Server.GetTrafficStats()
	Channel("broadcast", After, 3, 30)
	Same("Push events", After.Events.Push.Sent, 15)
	Same("Push bytes", After.Events.Push.SentBytes, 30)
	Same("Feed events", After.Events.Feed.Sent, 0)

	--> A flush with nothing to send counts nothing more.
	Server.StepReplication()
	Channel("an empty flush", Server.GetTrafficStats(), 3, 30)
	Same("packets after an empty flush", #Pair.Delivered, 1)
end)

RunClosure("A broadcast of varying size counts its bytes once per player", function()
	local Pair = Serve(2)
	local Server = Pair.Server
	--> An index, a one-byte length and the text: 5 bytes, then 2.
	Server.Feed.FireAll("abc")
	Server.Feed.FireAll("")
	Server.StepReplication()

	Same("bytes on the wire", Wire("texts", Pair, 2, "", 1), 14)
	local Stats = Server.GetTrafficStats()
	Channel("texts", Stats, 2, 14)
	Same("Feed events", Stats.Events.Feed.Sent, 4)
	Same("Feed bytes", Stats.Events.Feed.SentBytes, 14)
end)

RunClosure("A broadcast a diverged player took in their own packet is not counted twice", function()
	local Pair, Players = Serve(3)
	local Server = Pair.Server

	--> The first player's own event comes before any broadcast, so the flush puts the broadcast batch
	--> after it in their packet: 2 + 4. The second diverges between the broadcasts: 2 + 2 + 2. The
	--> third has nothing of their own and is sent the broadcast batch alone: 4.
	Server.Push.Fire(Players[1], 1)
	Server.Push.FireAll(2)
	Server.Push.Fire(Players[2], 3)
	Server.Push.FireAll(4)
	Server.StepReplication()

	Same("bytes on the wire", Wire("mixed", Pair, 3, "4, 6, 6", 0), 16)
	local Stats = Server.GetTrafficStats()
	Channel("mixed", Stats, 3, 16)
	Same("Push events", Stats.Events.Push.Sent, 8)
	Same("Push bytes", Stats.Events.Push.SentBytes, 16)

	--> Nobody is diverged once the flush is done: the next broadcast is one FireAllClients again.
	Server.Push.FireAll(5)
	Server.StepReplication()
	Same("packets after the second frame", #Pair.Delivered, 4)
	Same("FireAllClients after the second frame", #Pair.Delivered - #Pair.Replies, 1)
	Channel("mixed, then a broadcast", Server.GetTrafficStats(), 6, 22)
end)

RunClosure("The players who did not diverge are counted one packet each", function()
	local Pair, Players = Serve(3)
	local Server = Pair.Server

	--> The second player diverges and is sent 2 + 2 in a packet of their own; the other two are each
	--> sent the two-byte broadcast batch with a FireClient, since a FireAllClients would reach all.
	Server.Push.FireAll(1)
	Server.Push.Fire(Players[2], 2)
	Server.StepReplication()

	Same("bytes on the wire", Wire("one diverged", Pair, 3, "2, 2, 4", 0), 8)
	local Stats = Server.GetTrafficStats()
	Channel("one diverged", Stats, 3, 8)
	Same("Push events", Stats.Events.Push.Sent, 4)
end)

RunClosure("A broadcast to a server with no players counts nothing", function()
	local Pair = Serve(0)
	local Server = Pair.Server
	for Value = 1, 3 do
		Server.Push.FireAll(Value)
	end
	Server.StepReplication()

	--> The remote is fired, and reaches nobody.
	Same("bytes on the wire", Wire("empty server", Pair, 0, "", 1), 0)
	local Stats = Server.GetTrafficStats()
	Channel("empty server", Stats, 0, 0)
	Same("Push events", Stats.Events.Push.Sent, 0)
end)

RunClosure("ResetTrafficStats clears what the broadcasts counted", function()
	local Pair = Serve(2)
	local Server = Pair.Server
	Server.Push.FireAll(1)
	Server.StepReplication()
	Channel("before the reset", Server.GetTrafficStats(), 2, 4)

	Server.ResetTrafficStats()
	Channel("after the reset", Server.GetTrafficStats(), 0, 0)
end)

RunClosure("A client's batch cut into packets counts each packet", function()
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(CLIENT_SCHEMA), `CHANNELS{Built}`)
	local Client = Pair.Client
	for Value = 1, 10 do
		Client.Byte.Fire(Value)
	end
	Client.StepReplication()

	--> Four events a packet, two bytes an event.
	local Sizes, Total = Lengths(Pair.Sent)
	Same("packet sizes", Sizes, "4, 8, 8")
	Same("bytes on the wire", Total, 20)
	Channel("cut", Client.GetTrafficStats(), 3, 20)
	Same("Byte events", Client.GetTrafficStats().Events.Byte.Sent, 10)

	--> A batch that fits one packet goes the other way through the flush, and counts one.
	for Value = 1, 3 do
		Client.Byte.Fire(Value)
	end
	Client.StepReplication()
	Same("packets after the second frame", #Pair.Sent, 4)
	Channel("cut, then whole", Client.GetTrafficStats(), 4, 26)
end)

RunClosure("Without the option neither flush counts anything", function()
	for Context, Schema in { Server = SERVER_SCHEMA, Client = CLIENT_SCHEMA } do
		local Plain = string.gsub(Schema, "option TrafficStats = true\n", "")
		local Source = Generator.Generate(Context :: any, Isolated.Parse(Plain))
		if string.find(Source, "TrafficCounters", 1, true) then
			ErrorPrint(`Failed "Off": the {Context} module counts traffic.`)
		end

		local Counted = Generator.Generate(Context :: any, Isolated.Parse(Schema))
		local _, Counts = string.gsub(Counted, "TrafficCounters%[1%] %+= ", "")
		Same(`counted sends in the {Context} flush`, Counts, if Context == "Server" then 3 else 2)
	end
end)

return {}
