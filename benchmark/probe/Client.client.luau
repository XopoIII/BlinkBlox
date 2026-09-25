--!strict
--> The client half of the unreliable size probe; see ReplicatedStorage.ProbeCommon.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = require(ReplicatedStorage:WaitForChild("ProbeCommon"))
local Unreliable = ReplicatedStorage:WaitForChild("ProbeUnreliable") :: UnreliableRemoteEvent
local Control = ReplicatedStorage:WaitForChild("ProbeControl") :: RemoteEvent

local Logs: { string } = {}
LogService.MessageOut:Connect(function(Message: string)
	local Lower = string.lower(Message)
	if #Logs < 20 and (string.find(Lower, "unreliable") or string.find(Lower, "payload")) then
		table.insert(Logs, Message)
	end
end)

local FromServer = Common.NewRecord()
Unreliable.OnClientEvent:Connect(function(Payload)
	Common.Record(FromServer, Payload)
end)

local Parts: { Instance } = {}
for Index = 1, 16 do
	Parts[Index] = workspace:WaitForChild(`ProbePart{Index}`)
end

Control.OnClientEvent:Connect(function(Stage: string)
	if Stage == "Start" then
		Common.SendAll(function(Payload, Instances)
			Unreliable:FireServer(Payload, Instances)
		end, Parts)
		Control:FireServer("ClientSent")
	elseif Stage == "ServerSent" then
		task.wait(Common.SETTLE)
		Control:FireServer(
			"Report",
			HttpService:JSONEncode({
				Summary = Common.Summarise(FromServer),
				Logs = Logs,
			})
		)
	end
end)
