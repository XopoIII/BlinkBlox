--!strict
--- What the generated modules cost, measured without Roblox. Run from this directory:
---
---     lune run Runtime                   every bench, natively compiled and interpreted
---     lune run Runtime -- Entities       only the benches whose name contains "Entities"
---     lune run Runtime -- --frames 50    fewer frames, for a quick look
---
--- Studio's own benchmark (run.luau, generate.luau) reports frame rate and bandwidth, and neither
--- isolates this compiler's work: Studio caps the frame rate at 60, and Roblox compresses each packet
--- before counting its bytes. This one times the three things the generated code does -- a
--- frame's thousand Fires, the flush that turns them into one packet, and the server decoding that
--- packet -- each on its own, and counts the bytes the encoder produced before any compression.
---
--- Each bench runs twice: natively compiled, as the generated `--!native` asks and as a Roblox
--- server runs it, and interpreted, as most Roblox clients still run it.
local fs = require("@lune/fs")
local process = require("@lune/process")

local Attributes = require("../src/Modules/Attributes")
local Environment = require("./runtime/Environment")
local Generator = require("../src/Generator")
local Parser = require("../src/Parser")

local EVENTS_PER_FRAME = 1000
local WARMUP_FRAMES = 10
local BENCHES = { "Booleans", "Entities", "BooleansRandom", "EntitiesRandom", "Tiny" }
--> Benches only this file runs. The rest are Studio's, shared with it.
local LOCAL_BENCHES = { Tiny = true }

local Frames = 200
local Filter: string? = nil
do
	local Index = 1
	while Index <= #process.args do
		local Argument = process.args[Index]
		if Argument == "--" then
			--> What `lune run Runtime -- ...` passes through ahead of the arguments.
		elseif Argument == "--frames" then
			Frames = assert(tonumber(process.args[Index + 1]), "--frames takes a number")
			Index += 1
		else
			Filter = Argument
		end
		Index += 1
	end
end

--> The schema Studio's benchmark compiles, with the client flushing when told to rather than on a
--> Heartbeat that does not exist here.
local function Generate(): (string, string)
	local Source = fs.readFile("./definitions/Definition.blink")
	local Tree = Parser.new("./definitions/", "Definition.blink", nil, Attributes.new(nil)):Parse(Source)
	Tree.Value.Options.ManualReplication = true

	return Generator.Generate("Server", Tree), Generator.Generate("Client", Tree)
end

local function LoadPool(Name: string): { any }
	--> As benches/init.luau does in Studio, so each pool is the same on every run.
	math.randomseed(0)
	local Directory = if LOCAL_BENCHES[Name] then "./runtime/benches" else "./src/shared/benches"
	return (require :: any)(`{Directory}/{Name}`)
end

local function Percentile(Sorted: { number }, Percent: number): number
	return Sorted[math.clamp(math.ceil(#Sorted * Percent), 1, #Sorted)]
end

type Summary = { Median: number, P90: number, P99: number }

local function Summarise(Samples: { number }): Summary
	table.sort(Samples)
	return {
		Median = Percentile(Samples, 0.5),
		P90 = Percentile(Samples, 0.9),
		P99 = Percentile(Samples, 0.99),
	}
end

type Result = {
	Fire: Summary,
	Flush: Summary,
	Decode: Summary,
	Bytes: number,
	Received: number,
}

local function Run(Pair: Environment.Pair, Bench: string, Pool: { any }): Result
	local Fire = Pair.Client[Bench].Fire
	local StepReplication = Pair.Client.StepReplication
	local Reliable = Pair.Reliable
	local Player = Pair.Player

	local Received = 0
	local First: any = nil
	Pair.Server[Bench].On(function(_Player, Value)
		Received += 1
		if First == nil then
			First = Value
		end
	end)

	local FireTimes, FlushTimes, DecodeTimes = {}, {}, {}
	local Bytes = 0
	local PoolSize = #Pool
	local Sent = 0

	for Frame = 1, WARMUP_FRAMES + Frames do
		local Start = os.clock()
		for _ = 1, EVENTS_PER_FRAME do
			Fire(Pool[Sent % PoolSize + 1])
			Sent += 1
		end
		local Fired = os.clock()
		StepReplication()
		local Flushed = os.clock()

		local Packet = assert(Reliable.Sent, "The client flushed nothing")
		local Instances = Reliable.SentInstances
		Reliable.Sent = nil

		local Handler = assert(Reliable.ServerHandler, "The server never connected")
		local DecodeStart = os.clock()
		Handler(Player, Packet, Instances)
		local Decoded = os.clock()

		if Frame > WARMUP_FRAMES then
			table.insert(FireTimes, (Fired - Start) * 1000)
			table.insert(FlushTimes, (Flushed - Fired) * 1000)
			table.insert(DecodeTimes, (Decoded - DecodeStart) * 1000)
			Bytes = buffer.len(Packet)
		end
	end

	--> A benchmark of a codec that decodes the wrong thing measures nothing.
	assert(Received == Sent, `{Bench}: the server received {Received} of {Sent} events`)
	if type(First) == "table" then
		assert(#First == #Pool[1], `{Bench}: the first event decoded to a different length`)
	else
		assert(First == Pool[1], `{Bench}: the first event decoded to a different value`)
	end

	return {
		Fire = Summarise(FireTimes),
		Flush = Summarise(FlushTimes),
		Decode = Summarise(DecodeTimes),
		Bytes = Bytes,
		Received = Received,
	}
end

local function Format(Value: number): string
	return string.format("%.3f", Value)
end

local ServerSource, ClientSource = Generate()

print(`BlinkBlox {_G.VERSION or "(unbundled)"}, {Frames} frames of {EVENTS_PER_FRAME} events, times in ms per frame`)
print("")
print("|Bench|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|")
print("|---|---|---|---|---|---|---|---|")

for _, Bench in BENCHES do
	if Filter and not string.find(Bench, Filter, 1, true) then
		continue
	end

	local Pool = LoadPool(Bench)
	for _, Native in { true, false } do
		--> A pair per run: listeners, buffers and the inbound budget start from nothing each time.
		local Pair = Environment.Load(ServerSource, ClientSource, Native)
		local Result = Run(Pair, Bench, Pool)
		local Cells = {
			Bench,
			if Native then "native" else "interpreted",
			Format(Result.Fire.Median),
			Format(Result.Fire.P99),
			Format(Result.Flush.Median),
			Format(Result.Decode.Median),
			Format(Result.Decode.P99),
			string.format("%.2f", Result.Bytes / EVENTS_PER_FRAME),
		}
		print(`|{table.concat(Cells, "|")}|`)
	end
end
