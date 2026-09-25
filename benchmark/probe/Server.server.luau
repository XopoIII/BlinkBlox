--!strict
--> The server half of the unreliable size probe; see ReplicatedStorage.ProbeCommon.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = require(ReplicatedStorage:WaitForChild("ProbeCommon"))

local Unreliable = Instance.new("UnreliableRemoteEvent")
Unreliable.Name = "ProbeUnreliable"
Unreliable.Parent = ReplicatedStorage

local Control = Instance.new("RemoteEvent")
Control.Name = "ProbeControl"
Control.Parent = ReplicatedStorage

--> Replicated parts, so a reference to one means the same instance on both sides.
local Parts: { Instance } = {}
for Index = 1, 16 do
	local Part = Instance.new("Part")
	Part.Name = `ProbePart{Index}`
	Part.Anchored = true
	Part.Parent = workspace
	Parts[Index] = Part
end

--> What Studio says about each event it drops: the documentation promises a message naming how many
--> bytes over the limit it was, which gives the encoding's cost exactly.
local Logs: { string } = {}
LogService.MessageOut:Connect(function(Message: string)
	local Lower = string.lower(Message)
	if #Logs < 20 and (string.find(Lower, "unreliable") or string.find(Lower, "payload")) then
		table.insert(Logs, Message)
	end
end)

local FromClient = Common.NewRecord()
Unreliable.OnServerEvent:Connect(function(_Player, Payload)
	Common.Record(FromClient, Payload)
end)

local Player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

Control.OnServerEvent:Connect(function(Sender: Player, Stage: string, Report: string?)
	if Stage == "ClientSent" then
		task.wait(Common.SETTLE)
		print("> Client to server counted, now server to client")
		Common.SendAll(function(Payload, Instances)
			Unreliable:FireClient(Sender, Payload, Instances)
		end, Parts)
		Control:FireClient(Sender, "ServerSent")
	elseif Stage == "Report" and Report then
		local FromServer = HttpService:JSONDecode(Report)
		local Result = {
			PayloadLimit = 1000,
			ClientToServer = Common.Summarise(FromClient),
			ServerToClient = FromServer.Summary,
			ServerLogs = Logs,
			ClientLogs = FromServer.Logs,
		}

		local Value = Instance.new("StringValue")
		Value.Name = "Result"
		Value.Value = HttpService:JSONEncode(Result)
		Value.Parent = game
		print("Probe finished")
	end
end)

print(`> Probing with {Player.Name}, client to server first`)
Control:FireClient(Player, "Start")
