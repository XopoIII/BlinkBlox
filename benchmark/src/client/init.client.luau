local Benches = require("../shared/benches")
local Modes = require("../shared/modes")

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Stats = game:GetService("Stats")

local MAXIMUM_FRAMERATE = 60

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
	Recieve: number,
	Bandwidth: { number },
	Framerate: { number },
	--> Milliseconds of CPU each frame's thousand fires took. Unlike the frame rate this is not capped
	--> by Studio's 60 FPS, so it still tells two tools apart when both reach the cap.
	FireTime: { number },
}

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

local function WaitForPacketsToProcess()
	print("Waiting for packets to be processed.")
	while Stats.DataSendKbps > 0.5 do
		RunService.Heartbeat:Wait()
	end

	task.wait(5)
end

local function RunBenchmark(Tool: string, Bench: string): Benchmark
	local Total = 0
	local Frames = 0
	local Bandwidth = {}
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

	local Connection = RunService.PostSimulation:Connect(function(DeltaTime: number)
		Total += DeltaTime
		Frames += 1

		if Total >= 1 then
			Total -= 1
			local Scale = (MAXIMUM_FRAMERATE / Frames)
			table.insert(Bandwidth, Stats.DataSendKbps * Scale)
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

	--> Generate results
	table.sort(Bandwidth)
	table.sort(FireTimes)
	table.sort(Framerates, function(a, b)
		return a > b
	end)

	local FrameratePercentiles = {}
	local BandwidthPercentiles = {}
	local FireTimePercentiles = {}

	for _, Percentage in { 50, 0, 80, 90, 95, 100 } do
		table.insert(BandwidthPercentiles, Percentile(Bandwidth, Percentage))
		table.insert(FrameratePercentiles, Percentile(Framerates, Percentage))
		table.insert(FireTimePercentiles, Percentile(FireTimes, Percentage))
	end

	return {
		Sent = Sent,
		Recieve = 0,
		Bandwidth = BandwidthPercentiles,
		Framerate = FrameratePercentiles,
		FireTime = FireTimePercentiles,
	}
end

local function RunBenchmarks()
	local Results: Results = {}
	for Bench in Benches do
		warn(`Running {Bench} benchmark`)
		Results[Bench] = {}

		for Tool in Modes do
			print(`> Running with {Tool}`)
			Results[Bench][Tool] = RunBenchmark(Tool, Bench)

			--> Give ROBLOX some time to rest in-between tools
			WaitForPacketsToProcess()
		end

		--> Give ROBLOX some time to rest in-between benchmarks
		WaitForPacketsToProcess()
	end

	local Recieved = ReplicatedStorage.Shared.GetRecieved:InvokeServer()
	for Bench, Tools in Recieved do
		for Tool, Recieve in Tools do
			Results[Bench][Tool].Recieve = Recieve
		end
	end

	print("Finished running benchmarks, generating results...")
	ReplicatedStorage.Shared.Generate:FireServer(HttpService:JSONEncode(Results))
end

RunBenchmarks()
