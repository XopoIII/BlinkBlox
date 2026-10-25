local Benches = require("../shared/benches")
local Modes = require("../shared/modes")

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Stats = game:GetService("Stats")

local Camera = workspace.CurrentCamera
Camera.FieldOfView = 1
Camera.CFrame = CFrame.new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

Players.LocalPlayer.PlayerGui:ClearAllChildren()
Players.LocalPlayer.PlayerScripts:ClearAllChildren()

for _, Item in Enum.CoreGuiType:GetEnumItems() do
	while true do
		local Success = pcall(function()
			StarterGui:SetCoreGuiEnabled(Item, false)
		end)

		if Success then
			break
		end
	end
end

type Benchmark = {
	Sent: number,
	--> Events the server heard, counted there and asked for once the tool has drained. A run that
	--> lost or duplicated one says so in the Output, not only in the table.
	Recieve: number,
	--> Bytes each event cost on the wire, after Roblox's compression: every byte the client sent from
	--> the first fire until its backlog drained, less what it sends when idle, over the events fired.
	BytesPerEvent: number,
	--> Seconds the client kept sending after its last fire. A tool whose sends fall behind its fires
	--> finishes them here, which a rate sampled during the run never saw.
	Drain: number,
	Framerate: { number },
	--> Milliseconds of CPU each frame's thousand fires took. Unlike the frame rate this is not capped
	--> by Studio's 60 FPS, so it still tells two tools apart when both reach the cap.
	FireTime: { number },
	--> Each round's bytes an event, of which BytesPerEvent is the median: their spread is the noise.
	BytesRounds: { number },
}

--> One run of one tool on one bench, before Combine folds the rounds together.
type Round = {
	Sent: number,
	BytesPerEvent: number,
	Drain: number,
	Framerates: { number },
	FireTimes: { number },
}

--> Runs of each tool on each bench. Three take three times as long as one, and a run's bandwidth
--> moved by about a byte an event from one to the next.
local ROUNDS = 3

type Results = {
	[string]: {
		[string]: Benchmark,
	},
}

local function Percentile(Samples: { number }, Percentile: number)
	assert(
		(Percentile // 1) == Percentile and Percentile >= 0 and Percentile <= 100,
		"Percentile must be an integer between 0 and 100"
	)
	local Index = ((#Samples * (Percentile / 100)) // 1)
	Index = math.max(Index, 1)
	return Samples[Index]
end

--> `Stats.DataSendKbps` is kilobytes a second, not kilobits: with it, BlinkBlox's incompressible
--> benches came out at exactly their encoded size, 603 bytes a thousand times a frame at 60 FPS.
local IDLE_KBPS = 0.5

local function WaitForPacketsToProcess()
	print("Waiting for packets to be processed.")
	while Stats.DataSendKbps > IDLE_KBPS do
		RunService.Heartbeat:Wait()
	end

	task.wait(5)
end

--> What the client sends with nothing firing, in kilobytes a second, averaged over a second.
local function IdleRate(): number
	local Total, Elapsed = 0, 0
	while Elapsed < 1 do
		local DeltaTime = RunService.Heartbeat:Wait()
		Total += Stats.DataSendKbps * DeltaTime
		Elapsed += DeltaTime
	end
	return Total / Elapsed
end

local function RunBenchmark(Tool: string, Bench: string): Round
	local Total = 0
	local Frames = 0
	local Framerates = {}

	local Sent = 0
	local FireTimes = {}
	local Pool = Benches[Bench]
	local PoolSize = #Pool
	local Events = Modes[Tool]

	local Event = Events[Bench]
	local Method

	if Tool == "roblox" then
		Method = function(Data)
			Event:FireServer(Data)
		end
	elseif Tool == "packet" then
		Method = function(Data)
			Event:Fire(Data)
		end
	else
		Method = Event.Fire or Event.send
	end

	--> Bandwidth is integrated over the whole run and its drain rather than sampled once a second and
	--> scaled by 60 / FPS. The scaled samples undercounted every tool below 60 FPS -- Packet's
	--> EntitiesRandom read as 486 bytes an event, less than its 600 bytes of random data -- because
	--> what a slow tool fired late in a second went out after the sample, and after the run.
	local Idle = IdleRate()
	local Kilobytes = 0
	local Metered = 0
	local Meter = RunService.Heartbeat:Connect(function(DeltaTime: number)
		Kilobytes += Stats.DataSendKbps * DeltaTime
		Metered += DeltaTime
	end)

	local Connection = RunService.PostSimulation:Connect(function(DeltaTime: number)
		Total += DeltaTime
		Frames += 1

		if Total >= 1 then
			Total -= 1
			table.insert(Framerates, Frames)
			Frames = 0
		end

		local Start = os.clock()
		for Index = 1, 1000 do
			Method(Pool[Sent % PoolSize + 1])
			Sent += 1
		end
		table.insert(FireTimes, (os.clock() - Start) * 1000)
	end)

	task.wait(10)
	Connection:Disconnect()
	print(`> Finished running with {Tool}`)

	--> A minute is far past any drain measured; past it the stat is not falling, and the run goes on.
	local Finished = os.clock()
	while Stats.DataSendKbps > IDLE_KBPS and os.clock() - Finished < 60 do
		RunService.Heartbeat:Wait()
	end
	local Drain = os.clock() - Finished
	Meter:Disconnect()

	return {
		Sent = Sent,
		BytesPerEvent = math.max(Kilobytes - Idle * Metered, 0) * 1000 / Sent,
		Drain = Drain,
		Framerates = Framerates,
		FireTimes = FireTimes,
	}
end

local function Median(Values: { number }): number
	local Sorted = table.clone(Values)
	table.sort(Sorted)
	local Middle = #Sorted // 2
	if #Sorted % 2 == 0 then
		return (Sorted[Middle] + Sorted[Middle + 1]) / 2
	end
	return Sorted[Middle + 1]
end

--> One tool's rounds of one bench as one result. Bandwidth moved by about a byte an event between
--> runs, enough to swap two tools' places, so each round's bytes and drain are kept and the median
--> published; frame rates and fire times are pooled over every round before their percentiles.
local function Combine(Rounds: { Round }): Benchmark
	local Framerates, FireTimes, Bytes, Drains = {}, {}, {}, {}
	local Sent = 0
	for _, Round in Rounds do
		Sent += Round.Sent
		table.move(Round.Framerates, 1, #Round.Framerates, #Framerates + 1, Framerates)
		table.move(Round.FireTimes, 1, #Round.FireTimes, #FireTimes + 1, FireTimes)
		table.insert(Bytes, Round.BytesPerEvent)
		table.insert(Drains, Round.Drain)
	end

	table.sort(FireTimes)
	table.sort(Framerates, function(a, b)
		return a > b
	end)

	local FrameratePercentiles = {}
	local FireTimePercentiles = {}
	for _, Percentage in { 50, 0, 80, 90, 95, 100 } do
		table.insert(FrameratePercentiles, Percentile(Framerates, Percentage))
		table.insert(FireTimePercentiles, Percentile(FireTimes, Percentage))
	end

	return {
		Sent = Sent,
		Recieve = 0, --> Filled in by `CountDelivered` once the server has had time to hear it all.
		BytesPerEvent = Median(Bytes),
		BytesRounds = Bytes,
		Drain = Median(Drains),
		Framerate = FrameratePercentiles,
		FireTime = FireTimePercentiles,
	}
end

--> Asks the server how many of this run's events it heard, and says so: a frame rate means nothing
--> for a tool that dropped what it was timed on.
local function CountDelivered(Tool: string, Bench: string, Result: Benchmark)
	Result.Recieve = ReplicatedStorage.Shared.GetRecieved:InvokeServer(Bench, Tool)
	if Result.Recieve == Result.Sent then
		print(`> {Tool} delivered all {Result.Sent} events of {Bench}`)
	else
		warn(`> {Tool} delivered {Result.Recieve} of {Result.Sent} events of {Bench}`)
	end
end

local function RunBenchmarks()
	local Results: Results = {}
	for Bench in Benches do
		warn(`Running {Bench} benchmark`)
		Results[Bench] = {}

		--> Each round runs the tools in an order turned by one from the last, so no tool is always the
		--> one that follows a heavy run or opens the bench.
		local Tools = {}
		for Tool in Modes do
			table.insert(Tools, Tool)
		end
		table.sort(Tools)

		local Rounds: { [string]: { Round } } = {}
		for Round = 1, ROUNDS do
			for Offset = 0, #Tools - 1 do
				local Tool = Tools[(Offset + Round - 1) % #Tools + 1]
				print(`> Running with {Tool}, round {Round} of {ROUNDS}`)
				Rounds[Tool] = Rounds[Tool] or {}
				table.insert(Rounds[Tool], RunBenchmark(Tool, Bench))

				--> Give ROBLOX some time to rest in-between tools
				WaitForPacketsToProcess()
			end
		end

		for _, Tool in Tools do
			Results[Bench][Tool] = Combine(Rounds[Tool])
			CountDelivered(Tool, Bench, Results[Bench][Tool])
		end

		--> Give ROBLOX some time to rest in-between benchmarks
		WaitForPacketsToProcess()
	end

	print("Finished running benchmarks, generating results...")
	ReplicatedStorage.Shared.Generate:FireServer(HttpService:JSONEncode(Results))
end

RunBenchmarks()
