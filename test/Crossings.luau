--!strict
--- Specs for where the features of one release meet: a stream counted by `TrafficStats`, a
--- fixed-point number inside a stream's state, a stream's bounds in `ExportLimits`, a stream on a
--- server under `AutoStart = false`, and the members all of them add on a client that gave up on the
--- remotes under `ClientConnectTimeout`. Each feature has its own specs; these check only the seams.
--- test/Sources/Crossing.blink puts the same combinations in front of the goldens and the type gate.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local World = require("./World")
local fs = require("@lune/fs")

local RunClosure = Assertions.RunClosure

--- One Heartbeat at sixty frames a second.
local FRAME = 1 / 60

local function Same(Got: any, Expected: any, What: string)
	if Got ~= Expected then
		error(`{What}: expected {Expected}, got {Got}`, 2)
	end
end

local function Expect(Condition: boolean, Message: string)
	if not Condition then
		error(Message, 2)
	end
end

--- Fails unless `Got` holds exactly `Expected`, in order.
local function List(What: string, Got: { any }, Expected: { any })
	local Left, Right = {}, {}
	for Index, Value in Got do
		Left[Index] = tostring(Value)
	end
	for Index, Value in Expected do
		Right[Index] = tostring(Value)
	end

	local Shown, Wanted = table.concat(Left, ", "), table.concat(Right, ", ")
	Expect(Shown == Wanted, `{What}: got \{{Shown}\}, expected \{{Wanted}\}`)
end

--- Fails unless `Counts` holds exactly these four numbers.
local function Counted(What: string, Counts: any, Sent: number, SentBytes: number, Received: number, Bytes: number)
	local Shown = `{Counts.Sent}, {Counts.SentBytes}, {Counts.Received}, {Counts.ReceivedBytes}`
	local Wanted = `{Sent}, {SentBytes}, {Received}, {Bytes}`
	Expect(Shown == Wanted, `{What}: counted \{{Shown}\}, expected \{{Wanted}\}`)
end

local Built = 0

--- A server and client of their own, stepped once so the streams' clock starts at the mock clock.
local function Fresh(Schema: string): Isolated.Pair
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(Schema), `CROSSING{Built}`)
	Pair.Server.StepReplication()
	return Pair
end

--- `Count` frames on the mock clock, `Each(Frame)` run before each step. The frames that sent.
local function Frames(Pair: Isolated.Pair, Count: number, Each: (Frame: number) -> ()): { number }
	local Sent = {}
	for Index = 1, Count do
		Each(Index)
		local Before = #Pair.Outbound
		Shared.AdvanceClock(FRAME)
		Pair.Server.StepReplication()
		Expect(#Pair.Outbound - Before <= 1, `frame {Index} sent more than one packet`)
		if #Pair.Outbound > Before then
			table.insert(Sent, Index)
		end
	end

	return Sent
end

RunClosure("TrafficStats counts a stream's sends and receives, bytes and all, on its channel", function()
	local Pair = Fresh([[
option TrafficStats = true
event Tick { From: Server, Type: OrderedUnreliable, Call: ManySync, Stream: { Rate: 10 }, Data: u16<0.01> }
event Ready { From: Client, Type: Reliable, Call: SingleSync, Rate: 10, Data: u8 }
]])

	--> Frame 1 sends the first state, 7 a change, 13 the still state after it; 20 is the clear.
	local Sent = Frames(Pair, 20, function(Frame)
		if Frame == 20 then
			Pair.Server.Tick.Clear()
		else
			Pair.Server.Tick.Set(if Frame < 7 then 1.5 else 2.5)
		end
	end)
	List("frames that sent", Sent, { 1, 7, 13, 20 })

	--> A state is its index, a u16 sequence number, the optional's flag byte, the u16 steps and the
	--> u16 stamp: 8 bytes. The clear carries no state: 6.
	local Lengths = {}
	for _, Packet in Pair.Outbound do
		table.insert(Lengths, buffer.len(Packet.Buffer))
	end
	List("packet lengths", Lengths, { 8, 8, 8, 6 })

	local Server = Pair.Server.GetTrafficStats()
	Counted("the server's Tick", Server.Events.Tick, 4, 30, 0, 0)
	Counted("the server's unreliable channel", Server.Unreliable, 4, 30, 0, 0)
	Counted("the server's reliable channel", Server.Reliable, 0, 0, 0, 0)
	Counted("the server's Ready", Server.Events.Ready, 0, 0, 0, 0)

	local Heard: { any } = {}
	Pair.Client.Tick.On(function(Value: number?)
		table.insert(Heard, if Value == nil then "nil" else Value)
	end)
	for _, Packet in Pair.Outbound do
		Pair.Deliver(Packet)
	end
	List("values heard", Heard, { 1.5, 2.5, 2.5, "nil" })

	local Client = Pair.Client.GetTrafficStats()
	Counted("the client's Tick", Client.Events.Tick, 0, 0, 4, 30)
	Counted("the client's unreliable channel", Client.Unreliable, 0, 0, 4, 30)

	Pair.Server.ResetTrafficStats()
	Counted("the server's Tick after a reset", Pair.Server.GetTrafficStats().Events.Tick, 0, 0, 0, 0)
end)

RunClosure("A fixed-point field in a stream's state round-trips, compared in real units", function()
	local Pair = Fresh([[
struct Crawl { Id: u8, Speed: u16<0.1>(0..100) }
event Crawls { From: Server, Type: OrderedUnreliable, Call: SingleSync, Stream: { Rate: 10, Epsilon: 0.5 }, Data: Crawl }
]])

	local Heard: { number } = {}
	Pair.Client.Crawls.On(function(Value: any)
		table.insert(Heard, Value.Speed)
	end)

	--> 12.6 is 0.26 from the 12.34 sent, inside Epsilon, so frame 7 sends nothing -- compared in steps,
	--> 126 against 123, it would have. 12.9 is 0.56 away: frame 13 sends it, and 19 the still state.
	local Sent = Frames(Pair, 24, function(Frame)
		local Speed = if Frame == 1 then 12.34 elseif Frame <= 7 then 12.6 else 12.9
		Pair.Server.Crawls.Set({ Id = 1, Speed = Speed })
	end)
	List("frames that sent", Sent, { 1, 13, 19 })

	for _, Packet in Pair.Outbound do
		Pair.Deliver(Packet)
	end

	--> 12.34 went as 123 steps and reads back as exactly the double 12.3 is.
	List("speeds heard", Heard, { 12.3, 12.9, 12.9 })
	Same(Heard[1], 12.3, "the first speed")
	Same(Heard[2], 12.9, "the second speed")
end)

RunClosure("ExportLimits holds the bounds of the type a stream streams, not of its wire pack", function()
	local Schema = [[
option ExportLimits = true
struct Crawl { Id: u8, Speed: u16<0.1>(0..100), Heat: u8<saturate>(1..200) }
event Crawls { From: Server, Type: OrderedUnreliable, Call: SingleSync, Stream: { Rate: 10 }, Data: Crawl[..16] }
event Tick { From: Server, Type: OrderedUnreliable, Call: ManySync, Stream: { Rate: 5 }, Data: u16<0.01, saturate> }
]]
	local Pair = Fresh(Schema)

	for Side, Module in { Server = Pair.Server, Client = Pair.Client } do
		local Crawls = Module.Limits.Crawls
		Same(Crawls.Value, nil, `{Side}: Crawls.Value`)
		Same(Crawls.ServerTime, nil, `{Side}: Crawls.ServerTime`)
		Same(Crawls.Length.Min, 0, `{Side}: Crawls.Length.Min`)
		Same(Crawls.Length.Max, 16, `{Side}: Crawls.Length.Max`)
		Same(Crawls.Element.Id, nil, `{Side}: Crawls.Element.Id`)
		Same(Crawls.Element.Speed.Min, 0, `{Side}: Crawls.Element.Speed.Min`)
		Same(Crawls.Element.Speed.Max, 100, `{Side}: Crawls.Element.Speed.Max`)
		Same(Crawls.Element.Speed.Step, 0.1, `{Side}: Crawls.Element.Speed.Step`)
		Same(Crawls.Element.Heat.Min, 1, `{Side}: Crawls.Element.Heat.Min`)
		Same(Crawls.Element.Heat.Max, 200, `{Side}: Crawls.Element.Heat.Max`)
		Same(Crawls.Element.Heat.Step, nil, `{Side}: Crawls.Element.Heat.Step`)

		local Tick = Module.Limits.Tick
		Same(Tick.Min, 0, `{Side}: Tick.Min`)
		Same(Tick.Max, 655.35, `{Side}: Tick.Max`)
		Same(Tick.Step, 0.01, `{Side}: Tick.Step`)
		Same(Tick.Value, nil, `{Side}: Tick.Value`)
	end

	local Declared = Generator.GenerateTypescript("Server" :: any, Isolated.Parse(Schema))
	local Start = assert(string.find(Declared, "export declare const Limits", 1, true), "no Limits declaration")
	local Declaration = string.sub(Declared, Start)
	Expect(string.find(Declaration, "readonly Crawls: {", 1, true) ~= nil, "Limits declares no Crawls")
	Expect(string.find(Declaration, "readonly ServerTime", 1, true) == nil, "Limits declares the stamp")
end)

--- Writes one side of a schema named `Name` and returns its path, for a World.
local function Write(Name: string, Schema: string, Side: "Server" | "Client"): string
	local Path = `../Network/Crossing{Name}{Side}.luau`
	fs.writeFile(Path, Generator.Generate(Side, Isolated.Parse(`option RemoteScope = "{Name}"\n{Schema}`)))
	return Path
end

local function Count(Map: { [any]: any }): number
	local Total = 0
	for _ in Map do
		Total += 1
	end
	return Total
end

RunClosure("Under AutoStart = false a stream's scheduler does not run before Start", function()
	local Place = World.new()
	local Heartbeat = Shared.Signal.new()
	local Schema = [[
option AutoStart = false
option TrafficStats = true
event Tick { From: Server, Type: OrderedUnreliable, Call: ManySync, Stream: { Rate: 10 }, Data: u16<0.01> }
]]
	local Server = World.Load(Place, Write("CROSSSTART", Schema, "Server"), "Server", Heartbeat)

	local function Frame()
		Shared.AdvanceClock(FRAME)
		for _, Connection in Heartbeat.Connections do
			Connection(FRAME)
		end
	end

	--> A first state is due at the very next step, so a scheduler that ran would send in frame one.
	Server.Tick.Set(1.5)
	for _ = 1, 30 do
		Frame()
	end
	Same(Count(Heartbeat.Connections), 0, "Heartbeat connections before Start")
	Same(#Place.Created, 0, "instances created before Start")
	Same(#Place.Warnings, 0, "warnings before Start")
	Same(Server.GetTrafficStats().Events.Tick.Sent, 0, "Tick sends before Start")

	Server.Start()
	local Unreliable = Place.Children[Server.Remotes.Unreliable]
	Frame()
	Same(#Unreliable.Sent, 1, "packets in the first frame after Start")
	Same(Server.GetTrafficStats().Events.Tick.Sent, 1, "Tick sends after Start")

	--> And on schedule from there: a change goes at the next due step, six frames after the first.
	Server.Tick.Set(2.5)
	for _ = 1, 5 do
		Frame()
	end
	Same(#Unreliable.Sent, 1, "packets five frames after the first")
	Frame()
	Same(#Unreliable.Sent, 2, "packets six frames after the first")
	Same(#Place.Warnings, 0, "warnings")
end)

RunClosure("A client that gave up on the remotes keeps GetTrafficStats, Limits and a stream's On", function()
	local Place = World.new()
	local Schema = [[
option ClientConnectTimeout = 0.1
option TrafficStats = true
option ExportLimits = true
event Tick { From: Server, Type: OrderedUnreliable, Call: ManySync, Stream: { Rate: 10 }, Data: u16<0.01> }
event Ready { From: Client, Type: Reliable, Call: SingleSync, Rate: 10, Data: u8 }
]]
	local Client = World.Load(Place, Write("CROSSSTUB", Schema, "Client"), "Client")
	Same(Client.Connected, false, "Connected")

	local Stats = Client.GetTrafficStats()
	Counted("the stub's Tick", Stats.Events.Tick, 0, 0, 0, 0)
	Counted("the stub's Ready", Stats.Events.Ready, 0, 0, 0, 0)
	Counted("the stub's reliable channel", Stats.Reliable, 0, 0, 0, 0)
	Counted("the stub's unreliable channel", Stats.Unreliable, 0, 0, 0, 0)
	Client.ResetTrafficStats()

	Same(Client.Limits.Tick.Max, 655.35, "Limits.Tick.Max")
	Same(Client.Limits.Tick.Step, 0.01, "Limits.Tick.Step")

	local Heard = 0
	local Disconnect = Client.Tick.On(function()
		Heard += 1
	end)
	Same(type(Disconnect), "function", "the stream's On disconnect")
	Disconnect()

	Client.Ready.Fire(1)
	Counted("Ready after a Fire", Client.GetTrafficStats().Events.Ready, 0, 0, 0, 0)
	Same(Heard, 0, "listener calls")
	Same(#Place.Warnings, 0, "warnings")
end)

return {}
