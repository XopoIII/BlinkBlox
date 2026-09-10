return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent

--> WaitForChild returns whatever carries that name. A client can create an instance of any class in
--> ReplicatedStorage, so without this the first thing to answer to the name wins -- and every
--> outgoing packet is then handed to an object of the attacker's choosing.
assert(Reliable:IsA("RemoteEvent"), "[Blink]: The reliable remote is not a RemoteEvent.")
assert(Unreliable:IsA("UnreliableRemoteEvent"), "[Blink]: The unreliable remote is not an UnreliableRemoteEvent.")

--> Present so code shared between contexts can install a handler without branching on which module
--> it got. The client never rate limits: it is talking to the server, which is trusted.
local function SetRateLimitHandler(_Handler: ((Player: Player, Event: string) -> ())?) end

local function StepReplication()
    if SendCursor <= 0 then
        return
    end

    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    Reliable:FireServer(Buffer, SendInstances)

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = buffer.create(64)
    table.clear(SendInstances)
end
]]
