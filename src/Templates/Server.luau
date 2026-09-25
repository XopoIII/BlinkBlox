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
    --> Set BEFORE parenting, and that ordering is the whole trick. An attribute written on an
    --> unparented instance replicates atomically with the instance itself; one written afterwards is
    --> a separate replication event with no ordering guarantee against the client's WaitForChild
    --> returning. Doing it here removes the race rather than papering over it with a wait.
    RemoteEvent:SetAttribute("SchemaSignature", SCHEMA_SIGNATURE)
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
else
    --> The remote already existed -- planted by Rojo, or left by an earlier build. Here the attribute
    --> IS a separate replication event, so the client tolerates arriving before it.
    Reliable:SetAttribute("SchemaSignature", SCHEMA_SIGNATURE)
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
assert(Reliable:IsA("RemoteEvent"), "[BlinkBlox]: The reliable remote is not a RemoteEvent.")
assert(Unreliable:IsA("UnreliableRemoteEvent"), "[BlinkBlox]: The unreliable remote is not an UnreliableRemoteEvent.")

local PlayersMap: {[Player]: BLINK_BUFFER_SAVE} = {}

--> How many rows a polled event's queue holds on the server before it stops taking more. Clients fill
--> it, and a game that polls an event rarely, or has not got round to polling it at all, would let
--> them grow it without end -- each row pinning its Player. A game that drains its queues every
--> frame never comes near this, however full the server is.
local MAX_POLLED = 256 * math.max(Players.MaxPlayers, 1)

-- SPLIT --

--> INVOCATION STATE FOR FUNCTIONS THE SERVER CALLS, one set per player rather than the single set
--> Base.luau gives a client. Three separate reasons, and the second is the one that matters.
-->
--> Capacity: that set holds thirty-two outstanding calls in total. A server asking every client a
--> question would exhaust it on the thirty-third player and stay exhausted.
-->
--> Identity: the invocation id is a u8, and the reply carries it back. With one id space shared
--> across players, a reply from player A tagged with an id belonging to a call made to player B would
--> resume B's caller with A's data -- a client choosing which of the server's suspended threads to
--> answer, and what to tell it. Keying by player makes that impossible rather than merely checked:
--> an id from A can only ever be looked up in A's own set.
-->
--> Lifetime: a player who leaves owes an answer to every call outstanding to them, and those callers
--> have to be failed rather than left to sit out the timeout.
local PlayerInvocations: {[Player]: BLINK_INVOCATIONS} = {}

local function InvokePlayer(Player: Player, Index: number): number
    --> Checked before an id is claimed. A player who already left gets no answer from anyone, and
    --> PlayerRemoving has cleared their set, so claiming here would put back a set nothing removes
    --> again and park the caller for the whole timeout to learn what is already known.
    if not Player:IsDescendantOf(Players) then
        error(`[BlinkBlox]: Cannot invoke {Player.Name}, they are no longer in the game.`)
    end

    local State = PlayerInvocations[Player]
    if not State then
        State = CreateInvocations()
        PlayerInvocations[Player] = State
    end

    return ClaimInvocation(State, Index)
end

--> The per-player TimeoutInvocation. A call made while the player was on their way out -- from a
--> PlayerRemoving handler, or a caller retrying the failure it was just handed -- recreates a set
--> PlayerRemoving has already cleared, and nothing else would ever remove it. The timer is the one
--> thing certain to run afterwards, so it is what lets go.
local function TimeoutPlayerInvocation(Player: Player, Identifier: number, Seconds: number, Name: string)
    local State = PlayerInvocations[Player]
    if not State then
        return
    end

    TimeoutInvocation(State, Identifier, Seconds, `"{Name}" was never answered by {Player.Name}`, function()
        if not Player:IsDescendantOf(Players) and PlayerInvocations[Player] == State then
            PlayerInvocations[Player] = nil
        end
    end)
end

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    RateBuckets[Player] = nil
    InboundBudgets[Player] = nil
    Reports[Player] = nil
    Drops[Player] = nil
    ListenerErrors[Player] = nil
    InFlight[Player] = nil
    InFlightRefused[Player] = nil

    --> Every call outstanding to this player is now unanswerable. Failing them here rather than
    --> leaving them to time out matters because the thread on the other end is game code holding a
    --> lock, a queue slot or a yielded request handler. Their timers go with them.
    local State = PlayerInvocations[Player]
    PlayerInvocations[Player] = nil

    if State then
        local Threads = table.clone(State.Threads)
        for Identifier in table.clone(State.Claimed) do
            ReleaseInvocation(State, Identifier)
        end

        for _, Thread in Threads do
            if coroutine.status(Thread) == "suspended" then
                task.spawn(Thread, false)
            end
        end
    end
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

    --> Written into the entry the player already has, rather than a new one each time: this runs on
    --> every reliable send to a player, and the entry also carries its shrink count.
    local Entry = PlayersMap[Player]
    if Entry == nil then
        PlayersMap[Player] = Save()
        return
    end

    Entry.Size = SendSize
    Entry.Cursor = SendCursor
    Entry.Buffer = SendBuffer
    Entry.Instances = SendInstances
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

        local Used = Send.Cursor
        if Used > 0 then
            local Buffer = buffer.create(Used)
            buffer.copy(Buffer, 0, Send.Buffer, 0, Used)
            Reliable:FireClient(Player, Buffer, Send.Instances)

            Send.Cursor = 0
            table.clear(Send.Instances)
        end

        --> The buffer this player's writes grew is kept for the next frame rather than regrown from
        --> 64 bytes every Heartbeat: only the exact-size copy above goes on the wire, and every writer
        --> writes whole bytes, so what is left past the cursor is never read. One that has sat mostly
        --> empty for a second is let go, so a burst is not held for the rest of the session; see
        --> ShouldShrink.
        local Shrink, Underused = ShouldShrink(Send.Size, Used, Send.Underused or 0)
        Send.Underused = Underused
        if Shrink then
            Send.Size = 64
            Send.Buffer = buffer.create(64)
        end
    end
end
]]
