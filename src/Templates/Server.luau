return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
if not Reliable then
    local RemoteEvent = Instance.new("RemoteEvent")
    RemoteEvent.Name = BASE_EVENT_NAME .. "_RELIABLE_REMOTE"
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
end

local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
if not Unreliable then
    local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
    UnreliableRemoteEvent.Name = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE"
    UnreliableRemoteEvent.Parent = ReplicatedStorage
    Unreliable = UnreliableRemoteEvent
end

--> The server creates these when they are missing, but FindFirstChild above may have matched an
--> instance of a different class that a plugin or an earlier build left behind. Failing loudly at
--> require time beats failing per packet, forever, at runtime.
assert(Reliable:IsA("RemoteEvent"), "[Blink]: The reliable remote is not a RemoteEvent.")
assert(Unreliable:IsA("UnreliableRemoteEvent"), "[Blink]: The unreliable remote is not an UnreliableRemoteEvent.")

local PlayersMap: {[Player]: BufferSave} = {}

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
end)

--> Writing a player's buffer back is only safe while that player is still in the game.
--> A listener can yield between Load and Save -- a datastore call, a task.wait, any async work --
--> and the player may leave inside that window. PlayerRemoving has already cleared their entry by
--> then, so a plain `PlayersMap[Player] = Save()` puts back an entry that nothing will ever remove
--> again: StepReplication would allocate a buffer and fire a remote at a player who is gone, on
--> every Heartbeat, for the lifetime of the server.
local function SavePlayerBuffer(Player: Player)
    if not Player:IsDescendantOf(Players) then
        return
    end

    PlayersMap[Player] = Save()
end

local function StepReplication()
    for Player, Send in PlayersMap do
        --> Second line of defence. An entry can still be stale if it was written inside the narrow
        --> window of PlayerRemoving itself, before the player was detached; dropping it here makes
        --> the leak self-healing instead of permanent.
        if not Player:IsDescendantOf(Players) then
            PlayersMap[Player] = nil
            continue
        end

        if Send.Cursor <= 0 then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        Reliable:FireClient(Player, Buffer, Send.Instances)

        Send.Size = 64
        Send.Cursor = 0
        Send.Buffer = buffer.create(64)
        table.clear(Send.Instances)
    end
end
]]
