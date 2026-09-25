--!strict
--- The stream runtime (docs/src/content/docs/language/streams.mdx), spliced into a module only when
--- its schema declares a stream: the server's half before `-- SPLIT --`, the client's after. The
--- server's half goes after the server template, because it wraps StepReplication, and before the
--- streams' own entries (Generator/Stream.luau), which call CreateStream.
---
--- A stream holds the latest state the game `Set`. Every StepReplication -- each Heartbeat, unless
--- ManualReplication hands that to the game -- advances each stream's clock by the time since the
--- last step, and a stream whose interval has come round sends its state unless it equals the last
--- one sent. It sends anyway on `Urgent`, on the first state after it was idle, on the first due step
--- after a changed state (so the clients learn the state stopped), and once `Keepalive` seconds have
--- passed since the last send (so a lost packet is replaced). `Clear` sends nil once, if the clients
--- have seen a state, and the stream is then silent until the next Set. Each packet carries the
--- server's clock in milliseconds modulo 65536.
return [[
--> STREAMS. The scheduler behind each `Stream` event; see the stream runtime in the compiler.
local Workspace = game:GetService("Workspace")

type BLINK_STREAM = {
    Name: string,
    Interval: number,
    FastInterval: number,
    Keepalive: number,
    Epsilon: number,
    Send: (Value: any, ServerTime: number) -> (),

    Value: any, --> The state the game set, nil while it holds none.
    Holding: boolean, --> Set since the last Clear.
    Clearing: boolean, --> Cleared after a state went out, and the nil not sent yet.
    Live: boolean, --> A state went out since the last Clear.
    Sent: any, --> A copy of the last state sent, which the game may have changed since.
    Moved: boolean, --> The last send carried a change from the state before it.
    Urgent: boolean,
    Fast: boolean,
    Clock: number, --> Seconds towards the next due step.
    Since: number, --> Seconds since the last send.
}

--> A step lands on an interval within this much of it: 6 frames of 1/60 add to a hair under 0.1.
local STREAM_SLACK = 1e-6

local Streams: { BLINK_STREAM } = {}
local StreamStepped = os.clock()

local function CreateStream(Name: string, Interval: number, FastInterval: number, Keepalive: number, Epsilon: number, Send: (any, number) -> ()): BLINK_STREAM
    local Stream: BLINK_STREAM = {
        Name = Name,
        Interval = Interval,
        FastInterval = FastInterval,
        Keepalive = Keepalive,
        Epsilon = Epsilon,
        Send = Send,
        Value = nil,
        Holding = false,
        Clearing = false,
        Live = false,
        Sent = nil,
        Moved = false,
        Urgent = false,
        Fast = false,
        Clock = 0,
        Since = 0,
    }
    table.insert(Streams, Stream)
    return Stream
end

--> Whether two states are the same, a number within Epsilon of the other counting as equal -- and
--> each component of a vector, CFrame or Color3 the same way. Tables are equal when they hold the same
--> keys with equal values; a buffer when its bytes are; anything else only when `==` says so. NaN
--> equals nothing, so a state holding one is always sent.
local function StreamEqual(A: any, B: any, Epsilon: number): boolean
    if A == B then
        return true
    end

    local Kind = typeof(A)
    if Kind ~= typeof(B) then
        return false
    elseif Kind == "number" then
        return math.abs(A - B) <= Epsilon
    elseif Kind == "Vector3" or Kind == "vector" then
        return math.abs(A.X - B.X) <= Epsilon and math.abs(A.Y - B.Y) <= Epsilon and math.abs(A.Z - B.Z) <= Epsilon
    elseif Kind == "Color3" then
        return math.abs(A.R - B.R) <= Epsilon and math.abs(A.G - B.G) <= Epsilon and math.abs(A.B - B.B) <= Epsilon
    elseif Kind == "CFrame" then
        local Left = { A:GetComponents() }
        local Right = { B:GetComponents() }
        for Index = 1, 12 do
            if not (math.abs(Left[Index] - Right[Index]) <= Epsilon) then
                return false
            end
        end
        return true
    elseif Kind == "buffer" then
        return buffer.len(A) == buffer.len(B) and buffer.tostring(A) == buffer.tostring(B)
    elseif Kind == "table" then
        for Key, Item in A do
            if not StreamEqual(Item, B[Key], Epsilon) then
                return false
            end
        end
        for Key in B do
            if A[Key] == nil then
                return false
            end
        end
        return true
    end

    return false
end

--> What a sent state is compared against next, copied because the game may change a table it set.
local function StreamCopy(Value: any): any
    local Kind = typeof(Value)
    if Kind == "table" then
        local Copy = {}
        for Key, Item in Value do
            Copy[Key] = StreamCopy(Item)
        end
        return Copy
    elseif Kind == "buffer" then
        local Copy = buffer.create(buffer.len(Value))
        buffer.copy(Copy, 0, Value)
        return Copy
    end

    return Value
end

local function StreamSet(Stream: BLINK_STREAM, Value: any)
    if Value == nil then
        error(`[BlinkBlox]: Stream "{Stream.Name}" cannot be set to nil. Call Clear to clear it.`, 3)
    end

    --> An idle stream sends its first state at the next step, not an interval later; and a Clear not
    --> sent yet is replaced by this state, which tells the clients just as much.
    if not Stream.Holding then
        Stream.Urgent = true
    end

    Stream.Value = Value
    Stream.Holding = true
    Stream.Clearing = false
end

local function StreamClear(Stream: BLINK_STREAM)
    --> Only clients that were sent a state need telling it is gone.
    Stream.Clearing = Stream.Live
    Stream.Holding = false
    Stream.Value = nil
    Stream.Urgent = false
end

local function SendStream(Stream: BLINK_STREAM, Value: any)
    local ServerTime = math.floor(Workspace:GetServerTimeNow() * 1000) % 65536
    local Sent: boolean, Failure: any = pcall(Stream.Send, Value, ServerTime)
    if not Sent then
        --> It would fail the same way at every step. The stream stops until the game sets another.
        Stream.Holding = false
        Stream.Value = nil
        task.spawn(error, `[BlinkBlox]: Stream "{Stream.Name}" could not send its state: {Failure}`, 0)
    end
end

local function StepStream(Stream: BLINK_STREAM, Delta: number)
    if Stream.Clearing then
        Stream.Clearing = false
        Stream.Live = false
        Stream.Sent = nil
        Stream.Moved = false
        Stream.Clock = 0
        Stream.Since = 0
        SendStream(Stream, nil)
        return
    end

    if not Stream.Holding then
        return
    end

    Stream.Clock += Delta
    Stream.Since += Delta

    local Interval = if Stream.Fast then Stream.FastInterval else Stream.Interval
    local Forced = Stream.Urgent
    if not Forced and Stream.Clock < Interval - STREAM_SLACK then
        return
    end

    --> The clock keeps what it overran by, so a rate the frame rate does not divide still averages out
    --> to the rate. After a hitch longer than an interval it starts again rather than catching up.
    Stream.Urgent = false
    Stream.Clock = if Forced then 0 else math.max(Stream.Clock - Interval, 0)
    if Stream.Clock >= Interval then
        Stream.Clock = 0
    end

    --> Moved is a change from a state the clients already have. The first state is not one, so a
    --> stream that starts still is not sent twice.
    local Changed = not Stream.Live or not StreamEqual(Stream.Value, Stream.Sent, Stream.Epsilon)
    local Moved = Stream.Live and Changed
    if not (Forced or Changed or Stream.Moved or Stream.Since >= Stream.Keepalive - STREAM_SLACK) then
        return
    end

    Stream.Moved = Moved
    Stream.Since = 0
    Stream.Live = true
    Stream.Sent = StreamCopy(Stream.Value)
    SendStream(Stream, Stream.Value)
end

local function StepStreams()
    local Now = os.clock()
    local Delta = Now - StreamStepped
    StreamStepped = Now

    for _, Stream in Streams do
        StepStream(Stream, Delta)
    end
end

--> Streams step first, so a state sent this frame goes out ahead of the frame's reliable batch.
local StepReliable = StepReplication
StepReplication = function()
    StepStreams()
    StepReliable()
end
-- SPLIT --
--> STREAMS. A stream's stamp is the server's clock in milliseconds modulo 65536; this puts it back in
--> seconds, the one nearest the client's own estimate of that clock, which is within a ping of it.
local Workspace = game:GetService("Workspace")

local function UnwrapStamp(Stamp: number): number
    local Now = Workspace:GetServerTimeNow() * 1000
    local Time = Now - Now % 65536 + Stamp
    if Time > Now + 32768 then
        Time -= 65536
    elseif Time < Now - 32768 then
        Time += 65536
    end
    return Time / 1000
end
]]
