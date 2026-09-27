--!strict
--- What BlinkBlox's modules cost on the paths Runtime.luau never runs. Run from this directory:
---
---     lune run Scenarios                  every scenario, natively compiled and interpreted
---     lune run Scenarios -- Stream        only the scenarios whose name contains "Stream"
---     lune run Scenarios -- --frames 50   fewer frames, for a quick look
---
--- Runtime.luau times a client firing a thousand reliable events a frame at the server, which is one
--- path of several, and the one the tools compare on. A game also has the server sending to a crowd,
--- small unreliable events every frame, streams, and events carrying Instances; this times those,
--- from definitions/Scenarios.blink, for BlinkBlox alone.
---
--- Each scenario times three things a frame: the game's calls (Fire, FireAll, Set), the flush that
--- turns them into remote calls, and the observed receiver decoding what it was sent. It also counts
--- the remote calls a frame made and the bytes they delivered, summed over every player. Roblox adds
--- framing of its own to each remote call, which no byte count here includes: a scenario that makes
--- fewer calls for the same bytes is cheaper on the wire than its bytes say.
local fs = require("@lune/fs")
local process = require("@lune/process")

local Attributes = require("../src/Modules/Attributes")
local Crowd = require("./runtime/Crowd")
local Generator = require("../src/Generator")
local Parser = require("../src/Parser")

local WARMUP_FRAMES = 10
local CROWD = 50

local Frames = 200
local Filter: string? = nil
do
	local Index = 1
	while Index <= #process.args do
		local Argument = process.args[Index]
		if Argument == "--" then
			--> What `lune run Scenarios -- ...` passes through ahead of the arguments.
		elseif Argument == "--frames" then
			Frames = assert(tonumber(process.args[Index + 1]), "--frames takes a number")
			Index += 1
		else
			Filter = Argument
		end
		Index += 1
	end
end

local function Generate(): (string, string)
	local Source = fs.readFile("./definitions/Scenarios.blink")
	local Tree = Parser.new("./definitions/", "Scenarios.blink", nil, Attributes.new(nil)):Parse(Source)
	Tree.Value.Options.ManualReplication = true

	return Generator.Generate("Server", Tree), Generator.Generate("Client", Tree)
end

type Unit = {
	id: number,
	x: number,
	y: number,
	z: number,
	health: number,
	moving: boolean,
	crouched: boolean,
}

--> A unit that differs from frame to frame, so no stream skips a send as unchanged.
local function MakeUnit(Id: number, Frame: number): Unit
	return {
		id = Id,
		x = Id * 3.5 + Frame * 0.25,
		y = 12.75,
		z = Id * -1.5 - Frame * 0.125,
		health = (Id * 7 + Frame) % 101,
		moving = (Id + Frame) % 2 == 0,
		crouched = (Id + Frame) % 3 == 0,
	}
end

type Scenario = {
	Name: string,
	--> Players on the server.
	Players: number,
	Instances: boolean?,
	--> What a frame expects the observed receiver to decode, to check the scenario measured something.
	Expected: number,
	Setup: (Pair: Crowd.Pair, Received: () -> ()) -> (),
	Fire: (Pair: Crowd.Pair, Frame: number) -> (),
	Flush: (Pair: Crowd.Pair) -> (),
	Deliver: (Pair: Crowd.Pair) -> (),
}

local function ToClient(Pair: Crowd.Pair)
	for _, Remote in { Pair.Reliable, Pair.Unreliable } do
		local Handler = Remote.ClientHandler
		for _, Packet in Remote.Inbox do
			assert(Handler, "The client never connected")(Packet.Buffer, Packet.Instances)
		end
	end
end

local function ToServer(Pair: Crowd.Pair)
	for _, Remote in { Pair.Reliable, Pair.Unreliable } do
		local Handler = Remote.ServerHandler
		for _, Packet in Remote.Outbox do
			assert(Handler, "The server never connected")(Pair.Observed, Packet.Buffer, Packet.Instances)
		end
	end
end

local BROADCASTS = 100
local INPUTS = 8
local TOUCHES = 100
local WORLD_UNITS = 16

local PARTS = {}
for Index = 1, 16 do
	PARTS[Index] = Crowd.Part(`Part{Index}`)
end

local SCENARIOS: { Scenario } = {
	{
		Name = "Broadcast",
		Players = CROWD,
		Expected = BROADCASTS,
		Setup = function(Pair, Received)
			Pair.Client.Snapshot.On(function(_Value)
				Received()
			end)
		end,
		Fire = function(Pair, Frame)
			local FireAll = Pair.Server.Snapshot.FireAll
			for Index = 1, BROADCASTS do
				FireAll(MakeUnit(Index, Frame))
			end
		end,
		Flush = function(Pair)
			Pair.Server.StepReplication()
		end,
		Deliver = ToClient,
	},
	{
		Name = "UnreliableInput",
		Players = 1,
		Expected = INPUTS,
		Setup = function(Pair, Received)
			Pair.Server.Input.On(function(_Player, _Value)
				Received()
			end)
		end,
		Fire = function(Pair, Frame)
			local Fire = Pair.Client.Input.Fire
			for Index = 1, INPUTS do
				Fire({
					move = (Frame + Index) % 256,
					turn = Index * 100 - 400,
					jump = Index == 1,
					sprint = Frame % 2 == 0,
				})
			end
		end,
		Flush = function(Pair)
			Pair.Client.StepReplication()
		end,
		Deliver = ToServer,
	},
	{
		Name = "Instances",
		Players = 1,
		Instances = true,
		Expected = TOUCHES,
		Setup = function(Pair, Received)
			Pair.Server.Touch.On(function(_Player, _Part, _Force)
				Received()
			end)
		end,
		Fire = function(Pair, Frame)
			local Fire = Pair.Client.Touch.Fire
			for Index = 1, TOUCHES do
				Fire(PARTS[(Index + Frame) % #PARTS + 1], Index)
			end
		end,
		Flush = function(Pair)
			Pair.Client.StepReplication()
		end,
		Deliver = ToServer,
	},
	{
		Name = "StreamWorld",
		Players = CROWD,
		Expected = 1,
		Setup = function(Pair, Received)
			Pair.Client.World.On(function(_Value, _ServerTime)
				Received()
			end)
		end,
		Fire = function(Pair, Frame)
			local Units = table.create(WORLD_UNITS)
			for Index = 1, WORLD_UNITS do
				Units[Index] = MakeUnit(Index, Frame)
			end
			Pair.Server.World.Set(Units)
			--> Every frame rather than twenty times a second: the scheduler's timing is not what this measures.
			Pair.Server.World.Urgent()
		end,
		Flush = function(Pair)
			Pair.Server.StepReplication()
		end,
		Deliver = ToClient,
	},
	{
		Name = "StreamPerPlayer",
		Players = CROWD,
		Expected = 1,
		Setup = function(Pair, Received)
			Pair.Client.Self.On(function(_Value, _ServerTime)
				Received()
			end)
		end,
		Fire = function(Pair, Frame)
			local Self = Pair.Server.Self
			for Index, Player in Pair.Players do
				Self.Set(Player, MakeUnit(Index, Frame))
				Self.Urgent(Player)
			end
		end,
		Flush = function(Pair)
			Pair.Server.StepReplication()
		end,
		Deliver = ToClient,
	},
}

local function Percentile(Sorted: { number }, Percent: number): number
	return Sorted[math.clamp(math.ceil(#Sorted * Percent), 1, #Sorted)]
end

local function Median(Samples: { number }): number
	table.sort(Samples)
	return Percentile(Samples, 0.5)
end

type Result = { Fire: number, Flush: number, Decode: number, Calls: number, Bytes: number }

local function Run(Scenario: Scenario, Server: string, Client: string, Native: boolean): Result
	local Pair = Crowd.Load(Server, Client, Native, Scenario.Players, Scenario.Instances == true)
	local Received = 0
	Scenario.Setup(Pair, function()
		Received += 1
	end)

	local FireTimes, FlushTimes, DecodeTimes = {}, {}, {}
	local Calls, Bytes = 0, 0

	for Frame = 1, WARMUP_FRAMES + Frames do
		Pair.Reset()
		Received = 0

		local Start = os.clock()
		Scenario.Fire(Pair, Frame)
		local Fired = os.clock()
		Scenario.Flush(Pair)
		local Flushed = os.clock()
		Scenario.Deliver(Pair)
		local Decoded = os.clock()

		assert(
			Received == Scenario.Expected,
			`{Scenario.Name}: frame {Frame} decoded {Received} events, expected {Scenario.Expected}`
		)

		if Frame > WARMUP_FRAMES then
			table.insert(FireTimes, (Fired - Start) * 1000)
			table.insert(FlushTimes, (Flushed - Fired) * 1000)
			table.insert(DecodeTimes, (Decoded - Flushed) * 1000)
			Calls += Pair.Reliable.Calls + Pair.Unreliable.Calls
			Bytes += Pair.Reliable.Bytes + Pair.Unreliable.Bytes
		end
	end

	return {
		Fire = Median(FireTimes),
		Flush = Median(FlushTimes),
		Decode = Median(DecodeTimes),
		Calls = Calls / Frames,
		Bytes = Bytes / Frames,
	}
end

local function Format(Value: number): string
	return string.format("%.3f", Value)
end

local ServerSource, ClientSource = Generate()

print(`BlinkBlox {_G.VERSION or "(unbundled)"}, {Frames} frames, times in ms per frame, {CROWD} players where a crowd`)
print("")
print("|Scenario|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|")
print("|---|---|---|---|---|---|---|")

for _, Native in { true, false } do
	for _, Scenario in SCENARIOS do
		if Filter and not string.find(Scenario.Name, Filter, 1, true) then
			continue
		end

		local Result = Run(Scenario, ServerSource, ClientSource, Native)
		local Cells: { string } = {
			Scenario.Name,
			if Native then "native" else "interpreted",
			Format(Result.Fire),
			Format(Result.Flush),
			Format(Result.Decode),
			string.format("%.1f", Result.Calls),
			string.format("%.1f", Result.Bytes),
		}
		print(`|{table.concat(Cells, "|")}|`)
	end
end
