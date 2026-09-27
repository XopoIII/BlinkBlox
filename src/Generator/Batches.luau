--!strict
--!native
--!optimize 2

--- Unreliable batches: every unreliable event a side sends in a frame, gathered into as few packets as
--- the unreliable limit allows and sent at the flush, where each had been a remote call of its own.
---
--- A stream is always batched: it is sent from StepReplication already, so gathering it costs nothing
--- in time. An ordinary unreliable event is batched under `option BatchUnreliable`, since it then waits
--- for the flush rather than going at once -- as a reliable event always has.
---
--- Spliced in after the side's template, and only into a module that batches anything. It wraps
--- StepReplication, as the stream runtime does, so a frame sends its reliable batch and then its
--- unreliable ones. On the server a broadcast goes to one batch, sent in one FireAllClients, and a send
--- to one player to that player's; an ordered event's sequence is each player's own, so it is always
--- sent player by player. On the client there is one batch, which is also held to the server's
--- MaxEventsPerPacket, as the reliable one is.
local Lifecycle = require("./Lifecycle")
local State = require("./State")

local Batches = {}

--- Whether this module batches the unreliable events it sends, beyond its streams.
function Batches.Events(): boolean
	return State.Options.BatchUnreliable == true
end

local COMMON = [[

--> UNRELIABLE BATCHES; see Generator/Batches.luau.
type BLINK_UNRELIABLE = { Buffer: buffer, Size: number, Cursor: number, Instances: {Instance}, Events: number }

local function NewUnreliable(): BLINK_UNRELIABLE
    return { Buffer = buffer.create(64), Size = 64, Cursor = 0, Instances = {}, Events = 0 }
end

--> Appends what the scratch buffer holds -- one event, written there by the send -- to `Batch`.
local function CopyUnreliable(Batch: BLINK_UNRELIABLE): number
    local Size = SendCursor
    local Cursor = Batch.Cursor
    local InUse = Cursor + Size
    if InUse > Batch.Size then
        local Grown = Batch.Size
        while InUse > Grown do
            Grown *= 1.5
        end

        local Resized = buffer.create(Grown)
        buffer.copy(Resized, 0, Batch.Buffer, 0, Cursor)
        Batch.Buffer = Resized
        Batch.Size = Grown
    end

    buffer.copy(Batch.Buffer, Cursor, SendBuffer, 0, Size)
    Batch.Cursor = InUse
    Batch.Events += 1

    local Count = #SendInstances
    if Count > 0 then
        table.move(SendInstances, 1, Count, #Batch.Instances + 1, Batch.Instances)
    end

    return Cursor
end

--> Whether the event in the scratch buffer would take `Batch` past the unreliable limit.
local function Overflows(Batch: BLINK_UNRELIABLE): boolean
    return Batch.Cursor + SendCursor + (#Batch.Instances + #SendInstances) * UNRELIABLE_INSTANCE_BYTES > MAX_UNRELIABLE_SIZE
end
]]

local SERVER = [[

local SharedUnreliable = NewUnreliable()
local PlayerUnreliable: {[Player]: BLINK_UNRELIABLE} = {}

Players.PlayerRemoving:Connect(function(Player)
    PlayerUnreliable[Player] = nil
end)

local function SendUnreliable(Batch: BLINK_UNRELIABLE, Player: Player?)
    local Used = Batch.Cursor
    if Used == 0 then
        return
    end

    local Packet = buffer.create(Used)
    buffer.copy(Packet, 0, Batch.Buffer, 0, Used)
    if Player then
        Unreliable:FireClient(Player, Packet, Batch.Instances)
    else
        Unreliable:FireAllClients(Packet, Batch.Instances)
    end

    Batch.Cursor = 0
    Batch.Events = 0
    table.clear(Batch.Instances)
end

--> A player's batch, made on their first unreliable event of the session. None for a player who has
--> already left: PlayerRemoving has run, and nothing would clear a batch made now.
local function PlayerBatch(Player: Player): BLINK_UNRELIABLE?
    local Batch = PlayerUnreliable[Player]
    if Batch == nil then
        if Player.Parent == nil then
            return nil
        end

        Batch = NewUnreliable()
        PlayerUnreliable[Player] = Batch
    end

    return Batch
end

--> Appends the event in the scratch buffer to everyone's batch, or to `Player`'s.
local function AppendUnreliable(Player: Player?)
%GUARD%    local Batch = if Player then PlayerBatch(Player) else SharedUnreliable
    if Batch == nil then
        return
    end

    if Overflows(Batch) then
        SendUnreliable(Batch, Player)
    end
    CopyUnreliable(Batch)
end
%ORDERED%
local StepBeforeUnreliable = StepReplication
StepReplication = function()
    StepBeforeUnreliable()
    SendUnreliable(SharedUnreliable, nil)
    for Player, Batch in PlayerUnreliable do
        if Player.Parent == nil then
            PlayerUnreliable[Player] = nil
            continue
        end

        SendUnreliable(Batch, Player)
    end
end
]]

--> The same append for an ordered event, whose sequence is the player's own and is stamped over the
--> placeholder the serialiser left after its index.
local SERVER_ORDERED = [[

local function AppendOrdered(Player: Player, Slot: number)
%GUARD%    local Batch = PlayerBatch(Player)
    if Batch == nil then
        return
    end

    if Overflows(Batch) then
        SendUnreliable(Batch, Player)
    end
    local At = CopyUnreliable(Batch)
    buffer.writeu16(Batch.Buffer, At + 1, NextOrder(Player, Slot))
end
]]

local CLIENT = [[

local ClientUnreliable = NewUnreliable()

local function SendUnreliable()
    local Used = ClientUnreliable.Cursor
    if Used == 0 then
        return
    end

    local Packet = buffer.create(Used)
    buffer.copy(Packet, 0, ClientUnreliable.Buffer, 0, Used)
    Unreliable:FireServer(Packet, ClientUnreliable.Instances)

    ClientUnreliable.Cursor = 0
    ClientUnreliable.Events = 0
    table.clear(ClientUnreliable.Instances)
end

--> Appends the event in the scratch buffer to the batch, sending the batch first when the event would
--> take it past the unreliable limit or the server's event cap.
local function AppendUnreliable()
    if Overflows(ClientUnreliable) or ClientUnreliable.Events >= MAX_EVENTS_PER_PACKET then
        SendUnreliable()
    end
    CopyUnreliable(ClientUnreliable)
end

local StepBeforeUnreliable = StepReplication
StepReplication = function()
    StepBeforeUnreliable()
    SendUnreliable()
end
]]

--> Before Start, a send is dropped rather than batched, as the stand-in remote would have dropped it.
local GUARD = [[
    if not Started then
        DropBeforeStart()
        return
    end
]]

--- The runtime, or nothing when this module batches nothing.
function Batches.Body(): { string }
	if not State.UsesBatches then
		return {}
	end

	if State.Context == "Client" then
		return { COMMON, CLIENT }
	end

	local Guard = if Lifecycle.Deferred(State.Context, State.Options) then GUARD else ""
	local Ordered = if State.UsesOrdering then string.gsub(SERVER_ORDERED, "%%GUARD%%", Guard) else ""
	local Server = string.gsub(SERVER, "%%GUARD%%", Guard)
	Server = string.gsub(Server, "%%ORDERED%%", function()
		return Ordered
	end)
	return { COMMON, Server }
end

return Batches
