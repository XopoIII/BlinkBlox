--!strict
--!native
--!optimize 2

--- How an event's Fire writes into a batch that outlives it: the client's own, and the one the server
--- keeps per player. A broadcast writes into the scratch buffer and needs none of this.
---
--- Moved out of Event.luau when that file reached its size cap.
local Blocks = require("./Blocks")
local Parser = require("../Parser")
local Size = require("../Modules/Size")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode

local Writes = {}

--- Whether a write of `Data` can put anything in the instance list. Measured as the size analysis
--- measures it; a payload it cannot measure is taken to carry one.
function Writes.CarriesInstances(Data: Type?): boolean
	if not Data then
		return false
	end

	local Measured, Measurement = pcall(Size.Sealed, Data :: any)
	return not Measured or Measurement.Refs > 0
end

export type Write = {
	--- The client's reliable Fire.
	Begun: (Target: Blocks.Block) -> (),
	--- A server's reliable Fire to one player, between LoadPlayer and SavePlayerBuffer.
	Player: (Target: Blocks.Block) -> (),
}

--- `WriteEvent` is the call that serialises the event from `WriteArguments`; `Counters` is where its
--- traffic counters start under `option TrafficStats`, and nil otherwise. `Index` is the event's
--- channel index, which Frame merges consecutive same-index events under one header with.
function Writes.new(
	Identifier: string,
	WriteArguments: string,
	WriteEvent: string,
	Data: Type?,
	Counters: number?,
	Index: number?
): Write
	--> The same call, protected. `LoadPlayer` installs the player's saved instance list itself rather
	--> than a copy, so an Instance appended before a later field threw stayed in it even though the
	--> cursor was never saved -- and every instance after it in that flush reached the client one
	--> place out.
	local TryWriteEvent = `pcall({Util.GetPath(Identifier, true, State.Scope)}, {WriteArguments})`

	local CarriesInstances = Writes.CarriesInstances(Data)

	--> Writes into a batch that is kept, undoing whatever a write that throws had already added.
	local function WriteKept(Target: Blocks.Block)
		Target:Line("local Cursor, Instances = Mark()")
		Target:Line(`local Sent: boolean, Failure: any = {TryWriteEvent}`)
		Target:Compare("Sent", "true", "Not"):Line("Rollback(Cursor, Instances)"):Line("error(Failure, 0)"):End()
	end

	--> The client's batch, undone lazily rather than under a pcall; see Begin in the base template and
	--> Commit in the client's. An event that can carry Instances counts them and checks the instance
	--> cap too, written out here rather than called: an interpreted client pays for every call, and
	--> the extra work had made such a Fire slower than the pcall it replaced.
	local function Begun(Target: Blocks.Block)
		if not CarriesInstances then
			Target:Line("Begin()")
			if Counters then
				Target:Line("local Cursor = SendCursor")
			end
			Target:Line(WriteEvent)
			if Index ~= nil then
				--> After the cut Commit may make, so a run never crosses the packet a Cut opens; the
				--> packet boundary Frame then sees is the new one, and the event starts the new
				--> packet's first run as a plain entry. Commit returns where the event began.
				Target:Line(`Frame(Commit(), {Index}, PacketStart)`)
			else
				Target:Line("Commit()")
			end
			return
		end

		Target:Line("if PendingCursor >= 0 then Settle() end")
		Target:Line("local Start, Before = SendCursor, CommittedInstances")
		Target:Line("PendingCursor = Start")
		Target:Line(WriteEvent)
		Target:Line("local Count = #SendInstances")
		Target:Line("PendingCursor = -1")
		Target:Line("CommittedInstances = Count")
		Target:Line("PacketEvents += 1")
		Target:Line(
			"if PacketEvents > MAX_EVENTS_PER_PACKET or SendCursor - PacketStart > MAX_PACKET_SIZE or Count - PacketInstances > MAX_INSTANCES_PER_PACKET then Cut(Start, Before) end"
		)
		if Index ~= nil then
			--> The cut above, when it fires, is at the entry's still-plain boundary; Frame runs after
			--> it and its Packet argument says which packet the event landed in, so a run never spans
			--> two packets however the cuts fall.
			Target:Line(`Frame(Start, {Index}, PacketStart)`)
		end
		if Counters then
			Target:Line("local Cursor = Start")
		end
	end

	--> A player's batch on the server. A write that throws never reaches SavePlayerBuffer, so the
	--> player's saved cursor is where it was and the bytes past it are never sent. The instance list
	--> is the exception: `LoadPlayer` installs the player's own rather than a copy, so a payload that
	--> can append to it is still written under Mark and Rollback.
	local function Player(Target: Blocks.Block)
		if CarriesInstances then
			WriteKept(Target)
			return
		end

		if Counters then
			Target:Line("local Cursor = SendCursor")
		end
		Target:Line(WriteEvent)
	end

	return { Begun = Begun, Player = Player }
end

return Writes
