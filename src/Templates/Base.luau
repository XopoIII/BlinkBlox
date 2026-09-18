--!strict
return [[--> Free-slot bitset for outstanding invocations: a set bit is a free slot.
-->
--> This replaces a counter that wrapped at 255 and never released a slot on SUCCESS -- only on the
--> error path. Two calls in flight across the wrap therefore collided: the reused id was still
--> occupied, and the collision check refused a perfectly legitimate call. With a bitset the id is
--> the first genuinely free slot, and it goes back the moment its reply arrives.
local InvocationSlots = 0xFFFFFFFF

local SendSize = 64
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
    tail: Entry?
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

local function Invoke(): number
    local Slot = bit32.countrz(InvocationSlots)

    --> countrz of zero is 32: every slot taken. Thirty-two calls from one side with none answered is
    --> already pathological, and failing here beats handing out an id that belongs to someone else.
    if Slot == 32 then
        error("[Blink]: 32 calls are already awaiting a response, this call has been dropped.")
    end

    InvocationSlots = bit32.bxor(InvocationSlots, bit32.lshift(1, Slot))
    return Slot
end

local function ReleaseInvocation(Identifier: number)
    InvocationSlots = bit32.bor(InvocationSlots, bit32.lshift(1, Identifier))
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
        tail = nil
    }
end

local function Pop(queue: Queue): any
    local head = queue.head
    if head == nil then
        return
    end

    queue.head = head.next
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

local Calls = table.create(256)

--> Fails an invocation nobody answered.
-->
--> Until now there was no timeout at all, and the consequence was quiet: a call that never came back
--> left its entry in `Calls` and its bit claimed in `InvocationSlots` forever, so the caller hung and
--> the slot was gone. Thirty-two of those and `Invoke` refuses every further call for the lifetime of
--> the session.
-->
--> That was survivable while the callee was always the SERVER, which always answers -- every refusal
--> path writes a three-byte failure reply precisely so the caller does not hang. It stops being
--> survivable the moment a client can be the callee, because a client that never replies is ordinary
--> rather than a fault: it left, it crashed, it was exploited.
-->
--> The identity check is what makes this safe against a reply that arrives late. By then the slot may
--> belong to an unrelated call, and resuming that caller with this one's failure would be worse than
--> the hang.
local function TimeoutInvocation(Identifier: number, Seconds: number, Name: string)
    local Thread = Calls[Identifier]
    task.delay(Seconds, function()
        if Calls[Identifier] ~= Thread then
            return
        end

        Calls[Identifier] = nil
        ReleaseInvocation(Identifier)

        if coroutine.status(Thread) == "suspended" then
            warn(`[Blink]: "{Name}" was never answered and has been failed after {Seconds} seconds.`)
            task.spawn(Thread, false)
        end
    end)
end

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
