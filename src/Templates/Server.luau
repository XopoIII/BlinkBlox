--!strict
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

--> RATE LIMITING. One table per player, three numbers per limited event: tokens left, the clock
--> reading those tokens were last refilled at, and the clock reading the last report was made at.
--> A flat array rather than a table per event because a player who fires nothing still pays for the
--> allocation, and this is on the path of every inbound packet.
local RateBuckets: {[Player]: {number}} = {}
local RateHandler: ((Player: Player, Event: string) -> ())? = nil

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    RateBuckets[Player] = nil
end)

--> Installs the callback invoked whenever an event is refused. Nothing is kicked automatically: a
--> false positive under server lag would eject a legitimate player, and whether that is the right
--> response is a decision only the game can make.
local function SetRateLimitHandler(Handler: ((Player: Player, Event: string) -> ())?)
    RateHandler = Handler
end

--> Refills lazily and spends one token, or reports and refuses.
--> 
--> Called after an event has been DESERIALIZED, never before: payloads are variable length, so an
--> event cannot be skipped without decoding it -- the cursor would be left mid-event and the rest of
--> the packet would decode as garbage. So this bounds listener dispatch and the game logic behind
--> it, while MaxEventsPerPacket bounds the decoding itself. The two limits are different axes.
local function RateAccept(Player: Player, Slot: number, Rate: number, Burst: number, Name: string): boolean
    --> Same PlayerRemoving race the buffer save guards against, handled the same way: the entry is
    --> dropped here rather than left for a sweep that does not exist.
    if Player.Parent == nil then
        RateBuckets[Player] = nil
        return false
    end

    local Bucket = RateBuckets[Player]
    if not Bucket then
        Bucket = table.clone(RATE_TEMPLATE)
        RateBuckets[Player] = Bucket
    end

    local Now = os.clock()
    local Tokens = math.min(Burst, Bucket[Slot] + ((Now - Bucket[Slot + 1]) * Rate))
    Bucket[Slot + 1] = Now

    if Tokens < 1 then
        Bucket[Slot] = Tokens

        --> One report per player per event per second. An exploit client sends hundreds a frame, and
        --> a warning per drop would bury the console it is trying to inform.
        if (Now - Bucket[Slot + 2]) >= 1 then
            Bucket[Slot + 2] = Now
            warn(`[Blink]: Rate limited event "{Name}" from {Player.Name}.`)
        end

        local Handler = RateHandler
        if Handler then
            --> Spawned, not called. This runs inside the per-event pcall that contains a truncated
            --> packet, so a throwing handler would abort the rest of the packet; and a handler that
            --> yields -- an analytics write, a datastore call -- would stall decoding.
            Spawn(Handler, Player, Name)
        end

        return false
    end

    Bucket[Slot] = Tokens - 1
    return true
end

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
