--!strict
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

--> Refuse to run against a server built from a different schema.
-->
--> Event ids are positional, so inserting an event renumbers every event after it. Without this the
--> two sides agree on nothing but the remote's NAME: a client one build behind reads index 7 as
--> whatever index 7 means now, decodes one event's payload as another's, and dispatches it. Nothing
--> errors, which is why this failure is usually found by its symptoms.
-->
--> Erroring at require time rather than warning and carrying on: a module that silently stops
--> sending is the very failure this removes, just relocated. It is also the house style -- the scope
--> guard errors, and both class checks above assert.
local Signature = Reliable:GetAttribute("SchemaSignature")
if Signature == nil then
    --> Absent when the server found its remote already in place and wrote the attribute after it had
    --> replicated. Bounded, because an attribute that never arrives means an older server rather than
    --> a slow one, and hanging is the diagnosis nobody can act on.
    local Waited = 0
    while Signature == nil and Waited < 5 do
        Waited += task.wait(0.1)
        Signature = Reliable:GetAttribute("SchemaSignature")
    end
end

if Signature == nil then
    error("[Blink]: The server did not publish a schema signature. It is running a build of Blink from before this check existed, or a different networking module created the remote.")
elseif Signature ~= SCHEMA_SIGNATURE then
    error(`[Blink]: This client was built from a different schema than the server (client {SCHEMA_SIGNATURE}, server {Signature}). Recompile both sides from the same .blink file.`)
end

--> Present so code shared between contexts can install a handler without branching on which module
--> it got. The client never rate limits: it is talking to the server, which is trusted.
local function SetRateLimitHandler(_Handler: ((Player: Player, Event: string) -> ())?) end

--> A packet from the server that cannot be decoded is a bug in the game rather than an attack --
--> usually a Sync listener that yielded, or a client built from a different schema. It is said out
--> loud unless a handler takes it over, and either way it names the event and the error, because
--> "a packet could not be decoded" alone is what made the original report so hard to diagnose.
local DecodeHandler: ((Event: string?, Failure: string) -> ())? = nil

local function SetDecodeErrorHandler(Handler: ((Event: string?, Failure: string) -> ())?)
    DecodeHandler = Handler
end

local function ReportDecodeFailure(Event: string?, Failure: unknown)
    local Handler = DecodeHandler
    if Handler then
        Spawn(Handler, Event, tostring(Failure))
        return
    end

    warn(`[Blink]: Dropped a packet that could not be decoded, at event "{Event or "unknown"}": {Failure}`)
end

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
