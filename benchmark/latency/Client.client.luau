--!strict
--> The client half of the unreliable latency probe. Each mode fires four events a frame for a few
--> seconds, either early in the frame (RenderStepped, where input arrives) or late (a Heartbeat
--> handler connected after the flush), and sends them one of three ways:
-->
--> - at once, one remote call an event, as an unbatched unreliable Fire does;
--> - gathered and sent by a Heartbeat handler, as BatchUnreliable sends with StepReplication;
--> - gathered and sent by a `task.defer` the first event of a batch schedules.
-->
--> The server measures how long each event took to arrive.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Unreliable = ReplicatedStorage:WaitForChild("LatencyUnreliable") :: UnreliableRemoteEvent
local Done = ReplicatedStorage:WaitForChild("LatencyDone") :: RemoteEvent

local EVENTS_PER_FRAME = 4
local SECONDS = 5

local Mode = 0
local Queue: { number } = {}
local Scheduled = false

local function Send(Clocks: { number })
	local Payload = buffer.create(3 + #Clocks * 8)
	buffer.writeu8(Payload, 0, Mode)
	buffer.writeu16(Payload, 1, #Clocks)
	for Index, Clock in Clocks do
		buffer.writef64(Payload, 3 + (Index - 1) * 8, Clock)
	end
	Unreliable:FireServer(Payload)
end

local function Flush()
	Scheduled = false
	if #Queue > 0 then
		Send(Queue)
		table.clear(Queue)
	end
end

local Strategy = "Immediate"
local function Fire()
	local Clock = os.clock()
	if Strategy == "Immediate" then
		Send({ Clock })
	else
		table.insert(Queue, Clock)
		if Strategy == "Deferred" and not Scheduled then
			Scheduled = true
			task.defer(Flush)
		end
	end
end

--> The Heartbeat flush, connected first so that a late fire comes after it, as a game's Heartbeat
--> handler connected after the module's does.
RunService.Heartbeat:Connect(function()
	if Strategy == "Heartbeat" then
		Flush()
	end
end)

local Early = true
local Active = false
local Fired = 0
local function FireFrame()
	for _ = 1, EVENTS_PER_FRAME do
		Fire()
		Fired += 1
	end
end
RunService.RenderStepped:Connect(function()
	if Active and Early then
		FireFrame()
	end
end)
RunService.Heartbeat:Connect(function()
	if Active and not Early then
		FireFrame()
	end
end)

task.wait(3)

local Names: { string } = {}
local FiredByMode: { number } = {}
for _, When in { "early", "late" } do
	for _, How in { "Immediate", "Heartbeat", "Deferred" } do
		Mode += 1
		Names[Mode] = `{How}, fired {When}`
		Strategy = How
		Early = When == "early"
		Fired = 0
		Active = true
		task.wait(SECONDS)
		Active = false
		task.wait(0.5)
		Flush()
		FiredByMode[Mode] = Fired
		task.wait(1)
	end
end

Done:FireServer(Names, FiredByMode)
