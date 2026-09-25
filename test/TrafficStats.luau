--!strict
--- Specs for `option TrafficStats`: GetTrafficStats counts, per event and per channel, exactly the
--- bytes the wire format writes and reads, and ResetTrafficStats clears them. Without the option the
--- module has neither member and not one line of the counting.
---
--- The schema is this spec's own, on remotes nothing else shares (Isolated.luau), so the packets each
--- side fires are captured and can be handed to the other side byte for byte. The mock game has one
--- player. Byte counts are worked out from the wire format: an event is its one-byte index, then a
--- u16 sequence number when it is ordered, then its payload.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option TrafficStats = true

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Push { From: Server, Type: Reliable, Call: ManySync, Data: u8 }
event Blip { From: Server, Type: Unreliable, Call: ManySync, Data: u16 }
event Ping { From: Client, Type: Unreliable, Call: ManySync, Data: u8 }
event Seq { From: Client, Type: OrderedUnreliable, Call: ManySync, Data: u8 }
event Text { From: Client, Type: Reliable, Call: ManySync, Data: string(0..40) }
event Trail { From: Client, Type: OrderedUnreliable, Call: ManySync, Data: u8[..4] }
event Feed { From: Server, Type: Reliable, Call: ManySync, Data: string(0..40) }
scope Inner {
    event Poll { From: Client, Type: Reliable, Call: Polling, Data: u8 }
}
]]

local NAMES = { "Byte", "Push", "Blip", "Ping", "Seq", "Text", "Trail", "Feed", "Inner.Poll" }

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "TRAFFIC")
local Server, Client = Pair.Server, Pair.Client

type Counts = { Sent: number, SentBytes: number, Received: number, ReceivedBytes: number }

local ZERO: Counts = { Sent = 0, SentBytes = 0, Received = 0, ReceivedBytes = 0 }

local function Settle()
	task.wait(0.05)
end

local function Describe(Value: any): string
	if type(Value) ~= "table" then
		return tostring(Value)
	end
	return `\{ Sent = {Value.Sent}, SentBytes = {Value.SentBytes}, Received = {Value.Received}, ReceivedBytes = {Value.ReceivedBytes} \}`
end

--> Fails unless `Actual` holds exactly the four numbers of `Expected`, and nothing else.
local function Expect(Label: string, Actual: any, Expected: Counts)
	local Keys = 0
	for _ in Actual or {} do
		Keys += 1
	end

	if
		type(Actual) ~= "table"
		or Keys ~= 4
		or Actual.Sent ~= Expected.Sent
		or Actual.SentBytes ~= Expected.SentBytes
		or Actual.Received ~= Expected.Received
		or Actual.ReceivedBytes ~= Expected.ReceivedBytes
	then
		ErrorPrint(`Failed "{Label}": got {Describe(Actual)}, expected {Describe(Expected)}.`)
	end
end

local function Counted(Sent: number, SentBytes: number, Received: number, ReceivedBytes: number): Counts
	return { Sent = Sent, SentBytes = SentBytes, Received = Received, ReceivedBytes = ReceivedBytes }
end

--> Both sides' counters at zero, and nothing captured.
local function Reset()
	Server.ResetTrafficStats()
	Client.ResetTrafficStats()
	Server.StepReplication()
	Client.StepReplication()
	Server.ResetTrafficStats()
	Client.ResetTrafficStats()
	table.clear(Pair.Sent)
	table.clear(Pair.SentUnreliable)
	table.clear(Pair.Delivered)
	table.clear(Pair.DeliveredUnreliable)
end

local Heard = 0
Server.Byte.On(function()
	Heard += 1
end)

RunClosure("A u8 event fired three times counts three events and six bytes, on both sides", function()
	Reset()
	for Value = 1, 3 do
		Client.Byte.Fire(Value)
	end

	--> Counted as written, before the flush sends them; the packet is counted by the flush.
	local Before = Client.GetTrafficStats()
	Expect("Client Byte before the flush", Before.Events.Byte, Counted(3, 6, 0, 0))
	Expect("Client reliable before the flush", Before.Reliable, ZERO)

	Client.StepReplication()
	local After = Client.GetTrafficStats()
	Expect("Client reliable after the flush", After.Reliable, Counted(1, 6, 0, 0))
	Expect("Client unreliable", After.Unreliable, ZERO)

	if #Pair.Sent ~= 1 or buffer.len(Pair.Sent[1].Buffer) ~= 6 then
		ErrorPrint(`Failed "Wire": {#Pair.Sent} packet(s), expected one of 6 bytes, which the counts claim.`)
	end

	Heard = 0
	Pair.Feed(true, Pair.Sent[1].Buffer)
	Settle()

	local Received = Server.GetTrafficStats()
	Expect("Server Byte", Received.Events.Byte, Counted(0, 0, 3, 6))
	Expect("Server reliable", Received.Reliable, Counted(0, 0, 1, 6))
	if Heard ~= 3 then
		ErrorPrint(`Failed "Server Byte": the listener heard {Heard} events, expected 3.`)
	end

	for _, Name in NAMES do
		if Name ~= "Byte" then
			Expect(`Server {Name}`, Received.Events[Name], ZERO)
			Expect(`Client {Name}`, After.Events[Name], ZERO)
		end
	end
end)

RunClosure("Unreliable and ordered events count their packets and their sequence number", function()
	Reset()
	Client.Ping.Fire(9)
	Client.Seq.Fire(9)
	Client.Seq.Fire(10)

	local Sent = Client.GetTrafficStats()
	Expect("Client Ping", Sent.Events.Ping, Counted(1, 2, 0, 0))
	Expect("Client Seq", Sent.Events.Seq, Counted(2, 8, 0, 0))
	Expect("Client unreliable", Sent.Unreliable, Counted(3, 10, 0, 0))
	Expect("Client reliable", Sent.Reliable, ZERO)

	for _, Packet in Pair.SentUnreliable do
		Pair.Feed(false, Packet.Buffer)
	end
	Settle()

	local Received = Server.GetTrafficStats()
	Expect("Server Ping", Received.Events.Ping, Counted(0, 0, 1, 2))
	Expect("Server Seq", Received.Events.Seq, Counted(0, 0, 2, 8))
	Expect("Server unreliable", Received.Unreliable, Counted(0, 0, 3, 10))
end)

RunClosure("Server sends count once per recipient, and the client counts what it receives", function()
	Reset()
	local Player = Shared.Player
	Server.Push.Fire(Player, 1)
	Server.Push.Fire(Player, 2)
	Server.Push.FireAll(3)
	Server.Push.FireList({ Player, Player }, 4)
	Server.Push.FireExcept(Player, 5)
	Expect("Server Push", Server.GetTrafficStats().Events.Push, Counted(5, 10, 0, 0))

	Server.StepReplication()
	Expect("Server reliable", Server.GetTrafficStats().Reliable, Counted(1, 10, 0, 0))

	Server.Blip.FireAll(300)
	Server.Blip.FireList({ Player, Player }, 301)
	Server.Blip.Fire(Player, 302)
	Server.Blip.FireExcept(Player, 303)
	local Sent = Server.GetTrafficStats()
	Expect("Server Blip", Sent.Events.Blip, Counted(4, 12, 0, 0))
	Expect("Server unreliable", Sent.Unreliable, Counted(4, 12, 0, 0))

	if #Pair.Delivered ~= 1 or buffer.len(Pair.Delivered[1].Buffer) ~= 10 then
		ErrorPrint(`Failed "Wire": {#Pair.Delivered} reliable packet(s), expected one of 10 bytes.`)
	end

	Pair.FeedClient(true, Pair.Delivered[1].Buffer)
	for _, Packet in Pair.DeliveredUnreliable do
		Pair.FeedClient(false, Packet.Buffer)
	end
	Settle()

	local Received = Client.GetTrafficStats()
	Expect("Client Push", Received.Events.Push, Counted(0, 0, 5, 10))
	Expect("Client Blip", Received.Events.Blip, Counted(0, 0, 4, 12))
	Expect("Client reliable", Received.Reliable, Counted(0, 0, 1, 10))
	Expect("Client unreliable", Received.Unreliable, Counted(0, 0, 4, 12))
end)

RunClosure("A polled event in a scope is counted under its path", function()
	Reset()
	Pair.Feed(true, buffer.fromstring("\4\7\4\8"))
	Settle()

	local Stats = Server.GetTrafficStats()
	Expect("Server Inner.Poll", Stats.Events["Inner.Poll"], Counted(0, 0, 2, 4))
	if Stats.Events.Poll ~= nil then
		ErrorPrint(`Failed "Scope": the event is counted under its bare name as well.`)
	end

	local Polled = 0
	for _ in Server.Inner.Poll.Iter() do
		Polled += 1
	end
	if Polled ~= 2 then
		ErrorPrint(`Failed "Scope": {Polled} events were queued, expected 2.`)
	end
end)

RunClosure("Events of varying size count the bytes each one took, both ways", function()
	Reset()
	--> A string(0..40) is a one-byte length and its bytes; a u8[..4] a one-byte count and its elements.
	Client.Text.Fire("hello")
	Client.Text.Fire("")
	Client.Trail.Fire({ 1, 2, 3 })
	Client.Trail.Fire({})

	local Sent = Client.GetTrafficStats()
	Expect("Client Text", Sent.Events.Text, Counted(2, 9, 0, 0))
	Expect("Client Trail", Sent.Events.Trail, Counted(2, 11, 0, 0))
	Expect("Client unreliable", Sent.Unreliable, Counted(2, 11, 0, 0))

	Client.StepReplication()
	Expect("Client reliable", Client.GetTrafficStats().Reliable, Counted(1, 9, 0, 0))
	if #Pair.Sent ~= 1 or buffer.len(Pair.Sent[1].Buffer) ~= 9 then
		ErrorPrint(`Failed "Wire": {#Pair.Sent} packet(s), expected one of 9 bytes, which the counts claim.`)
	end

	Pair.Feed(true, Pair.Sent[1].Buffer)
	for _, Packet in Pair.SentUnreliable do
		Pair.Feed(false, Packet.Buffer)
	end
	Settle()

	local Received = Server.GetTrafficStats()
	Expect("Server Text", Received.Events.Text, Counted(0, 0, 2, 9))
	Expect("Server Trail", Received.Events.Trail, Counted(0, 0, 2, 11))

	Server.Feed.FireAll("abc")
	Server.Feed.FireList({ Shared.Player, Shared.Player }, "abcd")
	Server.Feed.FireExcept(Shared.Player, "abcdef")
	Expect("Server Feed", Server.GetTrafficStats().Events.Feed, Counted(3, 17, 0, 0))

	Server.StepReplication()
	Pair.FeedClient(true, Pair.Delivered[1].Buffer)
	Settle()
	Expect("Client Feed", Client.GetTrafficStats().Events.Feed, Counted(0, 0, 3, 17))
	Expect("Client reliable", Client.GetTrafficStats().Reliable, Counted(1, 9, 1, 17))
end)

RunClosure("Refused and undecodable packets are not counted as events", function()
	Reset()
	--> Refused before decoding: not a buffer. Not counted at all.
	Pair.Feed(true, "not a buffer" :: any)
	--> Accepted, then cut inside the second event: the packet counts, the first event counts, the
	--> second does not.
	Pair.Feed(true, buffer.fromstring("\0\1\0"))
	Settle()
	Shared.DrainWarnings()

	local Stats = Server.GetTrafficStats()
	Expect("Server reliable", Stats.Reliable, Counted(0, 0, 1, 3))
	Expect("Server Byte", Stats.Events.Byte, Counted(0, 0, 1, 2))
end)

RunClosure("ResetTrafficStats zeroes every count and keeps every name", function()
	Client.Byte.Fire(1)
	Client.StepReplication()
	Server.ResetTrafficStats()
	Client.ResetTrafficStats()

	for _, Module in { Server, Client } do
		local Stats = Module.GetTrafficStats()
		Expect("Reliable", Stats.Reliable, ZERO)
		Expect("Unreliable", Stats.Unreliable, ZERO)

		local Count = 0
		for Name, Counts in Stats.Events do
			Count += 1
			Expect(`Event {Name}`, Counts, ZERO)
		end

		if Count ~= #NAMES then
			ErrorPrint(`Failed "Reset": {Count} events are listed, expected {#NAMES}.`)
		end
	end
end)

RunClosure("GetTrafficStats hands out a fresh table each call", function()
	Reset()
	local First = Client.GetTrafficStats()
	First.Events.Byte.Sent = 99
	First.Reliable.Sent = 99
	Client.Byte.Fire(1)

	local Second = Client.GetTrafficStats()
	Expect("Second Byte", Second.Events.Byte, Counted(1, 2, 0, 0))
	Expect("Second reliable", Second.Reliable, ZERO)
	if First == Second or First.Events == Second.Events then
		ErrorPrint(`Failed "Fresh": two calls returned the same table.`)
	end
	Reset()
end)

RunClosure("Without the option there are no members and no counting", function()
	local Plain = string.gsub(SCHEMA, "option TrafficStats = true\n", "")
	local Tree = Isolated.Parse(Plain)
	for _, Context in { "Server", "Client" } do
		local Source = Generator.Generate(Context :: any, Tree)
		if string.find(Source, "Traffic", 1, true) then
			ErrorPrint(`Failed "Off": the {Context} module mentions Traffic.`)
		end

		local Declaration = Generator.GenerateTypescript(Context :: any, Tree)
		if string.find(Declaration, "TrafficStats", 1, true) then
			ErrorPrint(`Failed "Off": the {Context} TypeScript declares TrafficStats.`)
		end
	end

	local Off = Isolated.Build(Isolated.Parse(`option TrafficStats = false\n{Plain}`), "TRAFFICOFF")
	for _, Module in { Off.Server, Off.Client } do
		if Module.GetTrafficStats ~= nil or Module.ResetTrafficStats ~= nil then
			ErrorPrint(`Failed "Off": a module built with TrafficStats = false has the members.`)
		end
	end
end)

RunClosure("The members and fields follow Casing, in Luau and TypeScript", function()
	local Spellings = {
		Pascal = { "GetTrafficStats", "ResetTrafficStats", "SentBytes", "Events" },
		Camel = { "getTrafficStats", "resetTrafficStats", "sentBytes", "events" },
		Snake = { "get_traffic_stats", "reset_traffic_stats", "sent_bytes", "events" },
	}

	for Casing, Names in Spellings do
		local Tree = Isolated.Parse(`option Casing = {Casing}\n{SCHEMA}`)
		for _, Context in { "Server", "Client" } do
			local Source = Generator.Generate(Context :: any, Tree)
			for _, Line in
				{
					`{Names[1]} = GetTrafficStats,`,
					`{Names[2]} = ResetTrafficStats,`,
					`{Names[3]} = if Bytes > 0 then TrafficCounters[Base + 1] * Bytes else TrafficCounters[Base],`,
					`{Names[4]} = Events,`,
				}
			do
				if not string.find(Source, Line, 1, true) then
					ErrorPrint(`Failed "Casing": the {Casing} {Context} module has no "{Line}".`)
				end
			end

			local Declaration = Generator.GenerateTypescript(Context :: any, Tree)
			local Counts = if Casing == "Pascal"
				then "{ Sent: number; SentBytes: number; Received: number; ReceivedBytes: number }"
				elseif
					Casing == "Camel"
				then "{ sent: number; sentBytes: number; received: number; receivedBytes: number }"
				else "{ sent: number; sent_bytes: number; received: number; received_bytes: number }"
			local Channels = if Casing == "Pascal"
				then { "Events", "Reliable", "Unreliable" }
				else { "events", "reliable", "unreliable" }
			local Expected = {
				`export declare const {Names[1]}: () => \{ {Channels[1]}: Record<string, {Counts}>; {Channels[2]}: {Counts}; {Channels[3]}: {Counts} \}`,
				`export declare const {Names[2]}: () => void`,
			}
			for _, Line in Expected do
				if not string.find(Declaration, Line .. "\n", 1, true) then
					ErrorPrint(`Failed "TypeScript": the {Casing} {Context} declaration lacks "{Line}".`)
				end
			end
		end
	end
end)

RunClosure("The edit-mode stub hands out the real functions, reporting zeros", function()
	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	local Stub = Modules.MockRequire("../Network/IsolatedTRAFFICServer.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	local Stats = Stub.GetTrafficStats()
	Expect("Stub reliable", Stats.Reliable, ZERO)
	Expect("Stub unreliable", Stats.Unreliable, ZERO)
	for _, Name in NAMES do
		Expect(`Stub {Name}`, Stats.Events[Name], ZERO)
	end
	Stub.ResetTrafficStats()
end)
