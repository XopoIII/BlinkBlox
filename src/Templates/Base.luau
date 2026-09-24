--!strict
return [[local SendSize = 64
local SendOffset = 0
local SendCursor = 0
local SendBuffer = buffer.create(64)
local SendInstances = {}

local RecieveCursor = 0
local RecieveBuffer = buffer.create(64)

local RecieveInstances = {}
local RecieveInstanceCursor = 0

local Null = newproxy()

type Entry = {
    value: any,
    next: Entry?
}

type Queue = {
    head: Entry?,
    tail: Entry?,
    count: number
}

type BufferSave = {
    Size: number, 
    Cursor: number, 
    Buffer: buffer, 
    Instances: {Instance}
}

local function Read(Bytes: number)
    local Offset = RecieveCursor
    RecieveCursor += Bytes
    return Offset
end

local function Save(): BufferSave
    return {
        Size = SendSize,
        Cursor = SendCursor,
        Buffer = SendBuffer,
        Instances = SendInstances
    }
end

local function Load(Save: BufferSave?)
    if Save then
        SendSize = Save.Size
        SendCursor = Save.Cursor
        SendOffset = Save.Cursor
        SendBuffer = Save.Buffer
        SendInstances = Save.Instances
        return
    end

    --> A fresh buffer, never a shared scratch one, although StepReplication now keeps its buffers:
    --> `Load(PlayersMap[Player])` lands here for a player with no entry yet, and the Save that
    --> follows stores this buffer as theirs. Two players handed one buffer would write into each other.
    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = buffer.create(64)
    SendInstances = {}
end

--> Undoes a write that threw part way through.
-->
--> Every serialiser writes straight into SendBuffer through Allocate, and an assert can fire in the
--> MIDDLE of one -- after the event id, after two fields of three. Without this the bytes already
--> written stay and SendCursor stays advanced over them, so the next flush ships a truncated event
--> and the receiver decodes everything after it as garbage. One rejected Fire corrupts the whole
--> batch it happened to share.
-->
--> Only the cursor and the instance count are restored. A buffer that Allocate grew on the way is
--> kept deliberately: growing copied the earlier bytes across, so the larger buffer is just as
--> valid, and discarding it would only make the next write grow it again.
local function Mark(): (number, number)
    return SendCursor, #SendInstances
end

local function Rollback(Cursor: number, Instances: number)
    SendCursor = Cursor
    SendOffset = Cursor

    for Index = #SendInstances, Instances + 1, -1 do
        SendInstances[Index] = nil
    end
end

local function Allocate(Bytes: number)
    local InUse = (SendCursor + Bytes)
    if InUse > SendSize then
        --> Avoid resizing the buffer for every write
        while InUse > SendSize do
            SendSize *= 1.5
        end

        local Buffer = buffer.create(SendSize)
        buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
        SendBuffer = Buffer
    end

    SendOffset = SendCursor
    SendCursor += Bytes
    
    return SendOffset
end

local function CreateQueue(): Queue
    return {
        head = nil,
        tail = nil,
        count = 0
    }
end

local function Pop(queue: Queue): any
    local head = queue.head
    if head == nil then
        return
    end

    queue.head = head.next
    queue.count -= 1
    if queue.head == nil then
        --> Otherwise the last entry stays reachable, value and all, until the next push.
        queue.tail = nil
    end

    return head.value
end

local function Push(queue: Queue, value: any)
    local entry: Entry = {
        value = value,
        next = nil
    }

    if queue.tail ~= nil then
        queue.tail.next = entry
    end

    queue.tail = entry

    if queue.head == nil then
        queue.head = entry
    end

    queue.count += 1
end

--> One Luau thread, reused across Async dispatches, instead of one allocated per event.
-->
--> The pattern GoodSignal and FastSignal use, suggested for Blink on the devforum thread in 2024 and
--> never measured until now. Against task.spawn on the dispatch the generated code actually performs
--> -- call a listener, never touch the thread again -- it is about 18% faster per dispatch and, more
--> to the point, allocates nothing: a thread per event is garbage the collector walks in some later
--> frame, a cost that never shows up where it was spent.
-->
--> Nothing here handles a listener that yields or errors, because nothing needs to. Either one keeps
--> the thread it was given, the next dispatch finds the pool empty and makes a fresh one, and the
--> pool degrades to exactly what task.spawn was doing before.
local FreeThread: thread? = nil

local function RunInThread<T...>(Function: (T...) -> (), ...: T...)
    local Held = FreeThread
    FreeThread = nil
    Function(...)
    FreeThread = Held
end

local function CreateThread()
    FreeThread = coroutine.running()
    while true do
        RunInThread(coroutine.yield())
    end
end

--> Takes a FUNCTION. Resuming an existing thread -- an invocation waiting on its reply -- still goes
--> through task.spawn directly, since there is nothing to pool.
local function Spawn<T...>(Function: (T...) -> (), ...: T...)
    if not FreeThread then
        task.spawn(CreateThread)
    end

    task.spawn(FreeThread :: thread, Function, ...)
end

--> OUTSTANDING INVOCATIONS: the calls this side made that are still waiting for an answer.
-->
--> A call is known by its id, a u8 the answer carries back, and by the function it was made to. The
--> id alone used to be the whole identity, and three faults came of it. Ids were handed out lowest
--> free first, so the id a reply had just released was the next one claimed -- usually from the very
--> same thread. A timer armed for one call then found "its" slot holding the same thread and failed
--> whichever later call happened to be in flight. A reply that arrived after its call had timed out,
--> or had been cancelled, resumed that later call with the earlier one's values. And nothing
--> checked which FUNCTION a reply was for, so an answer to one function could resume a caller of
--> another, typed as something else entirely.
-->
--> So ids now go round the whole u8, skipping any still in use, and a released id is the last to
--> come back; a late reply reaches a newer call only after 255 more have been made, and only if that
--> one is to the same function, which the reply is checked against. Each call's timer is cancelled
--> the moment the call is settled, so a timer only ever fires for the call that armed it. At most
--> thirty-two calls are outstanding at once, as before: more than that with none answered is
--> already pathological, and failing here beats queueing without bound.
type Invocations = {
    Next: number,
    Outstanding: number,
    --> The function index each claimed id was claimed for.
    Claimed: {[number]: number},
    Threads: {[number]: thread},
    Timers: {[number]: thread},
}

local function CreateInvocations(): Invocations
    return {
        Next = 0,
        Outstanding = 0,
        Claimed = {},
        Threads = {},
        Timers = {},
    }
end

local function ClaimInvocation(State: Invocations, Index: number): number
    if State.Outstanding >= 32 then
        error("[BlinkBlox]: 32 calls are already awaiting a response, this call has been dropped.")
    end

    local Identifier = State.Next
    while State.Claimed[Identifier] ~= nil do
        Identifier = (Identifier + 1) % 256
    end

    State.Next = (Identifier + 1) % 256
    State.Claimed[Identifier] = Index
    State.Outstanding += 1
    return Identifier
end

--> Settles a call: its id goes back and its timer is cancelled. Safe to call twice, and on a state
--> that is already gone -- a player who left takes theirs with them.
local function ReleaseInvocation(State: Invocations?, Identifier: number)
    if not State or State.Claimed[Identifier] == nil then
        return
    end

    State.Claimed[Identifier] = nil
    State.Threads[Identifier] = nil
    State.Outstanding -= 1

    local Timer = State.Timers[Identifier]
    if Timer then
        State.Timers[Identifier] = nil
        task.cancel(Timer)
    end
end

local function ParkInvocation(State: Invocations?, Identifier: number, Thread: thread)
    if State and State.Claimed[Identifier] ~= nil then
        State.Threads[Identifier] = Thread
    end
end

--> The caller an answer is for, settled on the way out -- or nil when the id is not outstanding or
--> was claimed by a different function. That second case is what a hostile client answering one
--> function's call with another function's reply runs into.
local function TakeInvocation(State: Invocations?, Identifier: number, Index: number): thread?
    if not State or State.Claimed[Identifier] ~= Index then
        return nil
    end

    local Thread = State.Threads[Identifier]
    ReleaseInvocation(State, Identifier)
    return Thread
end

--> Fails a call nobody answered, after `Seconds`.
-->
--> Until there was a timeout at all, a call that never came back left its id claimed forever, and
--> thirty-two of those made every further call fail for the rest of the session. That was survivable
--> while the callee was always the server, which always answers -- every refusal path writes a
--> failure reply precisely so the caller does not hang -- and stopped being so once a client could
--> be the callee, since a client that never replies is ordinary: it left, it crashed, it was
--> exploited. `Expired` runs after the caller has been failed; the server uses it to let go of a
--> player who is gone.
local function TimeoutInvocation(State: Invocations, Identifier: number, Seconds: number, Name: string, Expired: (() -> ())?)
    local Thread = State.Threads[Identifier]
    if not Thread then
        return
    end

    State.Timers[Identifier] = task.delay(Seconds, function()
        --> Cleared first, so the release below does not try to cancel the timer that is running it.
        State.Timers[Identifier] = nil
        ReleaseInvocation(State, Identifier)

        if coroutine.status(Thread) == "suspended" then
            warn(`[BlinkBlox]: {Name} and has been failed after {Seconds} seconds.`)
            task.spawn(Thread, false)
        end

        if Expired then
            Expired()
        end
    end)
end

local Invocations = CreateInvocations()

local Events: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

local Queue: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

--> The name of every event this side receives, by channel and index, so a packet that fails to
--> decode can be reported as the event it claimed to be. Filled by the declarations below.
local EventNames: any = {
    Reliable = {},
    Unreliable = {}
}

]]
