--!strict
--> The server half of the unreliable latency probe; see the client half. Each event carries the
--> client's `os.clock()` when it was fired, and Studio runs both sides in one process, so the
--> difference is the time from fire to arrival. The server keeps it per mode, counts the remote calls
--> each mode made, and writes medians once the client says it is done.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Unreliable = Instance.new("UnreliableRemoteEvent")
Unreliable.Name = "LatencyUnreliable"
Unreliable.Parent = ReplicatedStorage

local Done = Instance.new("RemoteEvent")
Done.Name = "LatencyDone"
Done.Parent = ReplicatedStorage

local Samples: { [number]: { number } } = {}
local Calls: { [number]: number } = {}

--> A packet: [u8 mode][u16 count] then each event's f64 clock.
Unreliable.OnServerEvent:Connect(function(_Player, Payload: buffer)
	local Now = os.clock()
	local Mode = buffer.readu8(Payload, 0)
	local Count = buffer.readu16(Payload, 1)
	Calls[Mode] = (Calls[Mode] or 0) + 1
	local List = Samples[Mode]
	if not List then
		List = {}
		Samples[Mode] = List
	end
	for Index = 0, Count - 1 do
		table.insert(List, (Now - buffer.readf64(Payload, 3 + Index * 8)) * 1000)
	end
end)

local function Percentile(List: { number }, Share: number): number
	return List[math.clamp(math.ceil(#List * Share), 1, #List)]
end

Done.OnServerEvent:Connect(function(_Player, Names: { string }, Fired: { number })
	local Rows = {}
	for Mode, Name in Names do
		local List = Samples[Mode] or {}
		table.sort(List)
		table.insert(Rows, {
			Mode = Name,
			Fired = Fired[Mode],
			Arrived = #List,
			Calls = Calls[Mode] or 0,
			Median = if #List > 0 then Percentile(List, 0.5) else -1,
			P90 = if #List > 0 then Percentile(List, 0.9) else -1,
		})
	end
	local Result = Instance.new("StringValue")
	Result.Name = "Result"
	Result.Value = HttpService:JSONEncode(Rows)
	Result.Parent = game
	print("--RESULTS JSON--")
	print(Result.Value)
end)
