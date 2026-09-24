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
assert(Reliable:IsA("RemoteEvent"), "[Blink]: The reliable remote is not a RemoteEvent.")
assert(Unreliable:IsA("UnreliableRemoteEvent"), "[Blink]: The unreliable remote is not an UnreliableRemoteEvent.")

local PlayersMap: {[Player]: BufferSave} = {}

--> RATE LIMITING. One table per player, four numbers per limited event: tokens left, the clock
--> reading those tokens were last refilled at, the clock reading the last report was made at, and
--> the refusals made since that report, which the next one carries.
--> A flat array rather than a table per event because a player who fires nothing still pays for the
--> allocation, and this is on the path of every inbound packet.
local RateBuckets: {[Player]: {number}} = {}
local RateHandler: ((Player: Player, Event: string?, Refused: number) -> ())? = nil

--> THE INBOUND BUDGET. Bytes a player's packets may cost the server, refilled every second, charged
--> before a packet is decoded: tokens left, refill clock, report clock, refusals since that report.
--> Every other limit is per packet or per event, and a client that sends many packets each frame
--> passed all of them while the server decoded every one.
local InboundBudgets: {[Player]: {number}} = {}

--> INVOCATION STATE FOR FUNCTIONS THE SERVER CALLS, kept per player rather than in the single bitset
--> Base.luau gives a client. Three separate reasons, and the second is the one that matters.
-->
--> Capacity: that bitset holds thirty-two outstanding calls in total. A server asking every client a
--> question would exhaust it on the thirty-third player and stay exhausted.
-->
--> Identity: the invocation id is a u8, and the reply carries it back. With one id space shared
--> across players, a reply from player A tagged with an id belonging to a call made to player B would
--> resume B's caller with A's data -- a client choosing which of the server's suspended threads to
--> answer, and what to tell it. Keying by player makes that impossible rather than merely checked:
--> an id from A can only ever be looked up in A's own table.
-->
--> Lifetime: a player who leaves owes an answer to every call outstanding to them, and those callers
--> have to be failed rather than left to sit out the timeout.
local PlayerSlots: {[Player]: number} = {}
local PlayerCalls: {[Player]: {thread}} = {}

local function InvokePlayer(Player: Player): number
    --> Checked before a slot is claimed. A player who already left gets no answer from anyone, and
    --> PlayerRemoving has cleared their tables, so claiming here would put back entries nothing
    --> removes again and park the caller for the whole timeout to learn what is already known.
    if not Player:IsDescendantOf(Players) then
        error(`[Blink]: Cannot invoke {Player.Name}, they are no longer in the game.`)
    end

    local Slots = PlayerSlots[Player] or 0xFFFFFFFF
    local Slot = bit32.countrz(Slots)
    if Slot == 32 then
        error("[Blink]: 32 calls to this player are already awaiting a response, this call has been dropped.")
    end

    PlayerSlots[Player] = bit32.bxor(Slots, bit32.lshift(1, Slot))
    return Slot
end

local function ReleasePlayerInvocation(Player: Player, Identifier: number)
    local Slots = PlayerSlots[Player]
    if Slots then
        PlayerSlots[Player] = bit32.bor(Slots, bit32.lshift(1, Identifier))
    end

    local Calls = PlayerCalls[Player]
    if Calls then
        Calls[Identifier] = nil
    end
end

local function ParkInvocation(Player: Player, Identifier: number, Thread: thread)
    local Calls = PlayerCalls[Player]
    if not Calls then
        Calls = {}
        PlayerCalls[Player] = Calls
    end

    Calls[Identifier] = Thread
end

local function TakeInvocation(Player: Player, Identifier: number): thread?
    local Calls = PlayerCalls[Player]
    return Calls and Calls[Identifier]
end

--> The per-player half of TimeoutInvocation. Same identity check, for the same reason: by the time a
--> late reply turns up the slot may belong to an unrelated call to the same player.
local function TimeoutPlayerInvocation(Player: Player, Identifier: number, Seconds: number, Name: string)
    local Calls = PlayerCalls[Player]
    local Thread = Calls and Calls[Identifier]
    if not Thread then
        return
    end

    task.delay(Seconds, function()
        local Current = PlayerCalls[Player]
        if not Current or Current[Identifier] ~= Thread then
            return
        end

        ReleasePlayerInvocation(Player, Identifier)
        if coroutine.status(Thread) == "suspended" then
            warn(`[Blink]: "{Name}" was never answered by {Player.Name} and has been failed after {Seconds} seconds.`)
            task.spawn(Thread, false)
        end
    end)
end

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    RateBuckets[Player] = nil
    InboundBudgets[Player] = nil

    --> Every call outstanding to this player is now unanswerable. Failing them here rather than
    --> leaving them to time out matters because the thread on the other end is game code holding a
    --> lock, a queue slot or a yielded request handler.
    local Calls = PlayerCalls[Player]
    PlayerCalls[Player] = nil
    PlayerSlots[Player] = nil

    if Calls then
        for _, Thread in Calls do
            if coroutine.status(Thread) == "suspended" then
                task.spawn(Thread, false)
            end
        end
    end
end)

--> Installs the callback told about refused events: at most once per player per event per second,
--> with `Refused` the number of refusals that report stands for. `Event` is nil when what was refused
--> was whole packets over the inbound budget rather than one event. Nothing is kicked automatically:
--> a false positive under server lag would eject a legitimate player, and whether that is the right
--> response is a decision only the game can make.
local function SetRateLimitHandler(Handler: ((Player: Player, Event: string?, Refused: number) -> ())?)
    RateHandler = Handler
end

--> DECODE FAILURES (upstream issue #102). A packet that cannot be decoded is abandoned where it
--> failed, since the cursor is left mid-event and nothing after it can be trusted. That stays silent
--> by default -- a client sending garbage every frame must not be able to fill the output -- but the
--> game is entitled to know who sent it and what it claimed to be, to log it, flag the account or
--> kick. `Event` is nil when the index named no event at all.
local DecodeHandler: ((Player: Player, Event: string?, Failure: string) -> ())? = nil

local function SetDecodeErrorHandler(Handler: ((Player: Player, Event: string?, Failure: string) -> ())?)
    DecodeHandler = Handler
end

local function ReportDecodeFailure(Player: Player, Event: string?, Failure: unknown)
    local Handler = DecodeHandler
    if Handler then
        --> Spawned for the same reason RateAccept spawns its handler: one that throws or yields must
        --> not reach back into the receive loop that called it.
        Spawn(Handler, Player, Event, tostring(Failure))
    end
end

--> Charges a packet against its sender's inbound budget, or reports and refuses it.
-->
--> Called from the connection before the packet is decoded, so a refusal costs the server a table
--> lookup rather than a decode. The burst is a whole second of budget because the clock here is the
--> server's: after a hitch Roblox delivers the queued packets together, and a refused reliable packet
--> takes every event in it along. Reported on the same once-a-second schedule as RateAccept.
local function InboundAccept(Player: Player, Cost: number, Rate: number, Burst: number): boolean
    if Player.Parent == nil then
        InboundBudgets[Player] = nil
        return false
    end

    local Now = os.clock()
    local Budget = InboundBudgets[Player]
    if not Budget then
        --> The report clock starts at minus infinity so the first refusal is always reported.
        Budget = {Burst, Now, -math.huge, 0}
        InboundBudgets[Player] = Budget
    end

    local Tokens = math.min(Burst, Budget[1] + ((Now - Budget[2]) * Rate))
    Budget[2] = Now

    if Tokens >= Cost then
        Budget[1] = Tokens - Cost
        return true
    end

    Budget[1] = Tokens
    local Refused = Budget[4] + 1
    if (Now - Budget[3]) < 1 then
        Budget[4] = Refused
        return false
    end

    Budget[3] = Now
    Budget[4] = 0
    warn(`[Blink]: Dropped packets from {Player.Name} over the inbound budget of {Rate} bytes a second, {Refused} refused.`)

    local Handler = RateHandler
    if Handler then
        --> Spawned: this runs in the remote's connection, outside any pcall, and a throwing handler
        --> would take the connection's thread with it.
        Spawn(Handler, Player, nil, Refused)
    end

    return false
end

--> Refills lazily and spends one token, or reports and refuses.
--> 
--> Called after an event has been DESERIALIZED, never before: payloads are variable length, so an
--> event cannot be skipped without decoding it -- the cursor would be left mid-event and the rest of
--> the packet would decode as garbage. So this bounds listener dispatch and the game logic behind
--> it, while MaxEventsPerPacket bounds the decoding of one packet and InboundAccept how many packets
--> a second get decoded at all. The three limits are different axes.
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

        --> One report per player per event per second, the warning and the handler alike. An exploit
        --> client sends hundreds a frame; a report per drop would bury the console it is trying to
        --> inform, and spawn the game's handler as often. Refusals in between are counted instead.
        local Refused = Bucket[Slot + 3] + 1
        if (Now - Bucket[Slot + 2]) < 1 then
            Bucket[Slot + 3] = Refused
            return false
        end

        Bucket[Slot + 2] = Now
        Bucket[Slot + 3] = 0
        warn(`[Blink]: Rate limited event "{Name}" from {Player.Name}, {Refused} refused.`)

        local Handler = RateHandler
        if Handler then
            --> Spawned, not called. This runs inside the per-event pcall that contains a truncated
            --> packet, so a throwing handler would abort the rest of the packet; and a handler that
            --> yields -- an analytics write, a datastore call -- would stall decoding.
            Spawn(Handler, Player, Name, Refused)
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

        --> The buffer this player's writes grew is kept for the next frame rather than regrown from
        --> 64 bytes every Heartbeat: only the exact-size copy above goes on the wire, and every writer
        --> writes whole bytes, so what is left past the cursor is never read. One that a burst grew
        --> past 4 KB is let go, so a single large frame is not held for the rest of the session.
        Send.Cursor = 0
        if Send.Size > 4096 then
            Send.Size = 64
            Send.Buffer = buffer.create(64)
        end
        table.clear(Send.Instances)
    end
end
]]
