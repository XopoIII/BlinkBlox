--!strict
--!native
--!optimize 2

--- The server's sends to more than one player -- FireAll, FireList, FireExcept -- and the pieces
--- they share with a send to one: the loop over recipients and the per-recipient sequence stamp.
---
--- Moved out of Event.luau when that file reached its size cap.
local Batches = require("./Batches")
local Blocks = require("./Blocks")
local Fragments = require("./Fragments")
local State = require("./State")
local Traffic = require("./Traffic")

local RELIABLE_BODY = Fragments.RELIABLE_BODY
local UNRELIABLE_BODY = Fragments.UNRELIABLE_BODY

local Send = {}

--- What a server send needs to know about the event it sends. `Ordered` is the event's index when it
--- is an ordered unreliable one, whose sequence number each send stamps per recipient. `Traffic` is
--- where its counters start under `option TrafficStats`, and nil otherwise.
export type Send = {
	IsReliable: boolean,
	WriteEvent: string,
	Name: string,
	Ordered: number?,
	Traffic: number?,
	--> A stream's scheduled send rather than the game's Fire; see CheckSize.
	Stream: boolean?,
}

--- Stamps the recipient's own sequence number into an ordered packet. An unreliable server send always
--- starts from a fresh buffer, so the event sits at offset 0 and its sequence at offset 1.
function Send.StampOrder(Target: Blocks.Block, Event: Send)
	if Event.Ordered then
		Target:Line(`buffer.writeu16(Buffer, 1, NextOrder(Player, {Event.Ordered}))`)
	end
end

--- Refuses a packet past the unreliable limit. An event's send drops it and warns, as it always has.
--- A stream's send throws instead: SendStream then reports it once and stops the stream until the
--- game sets another state. Dropped quietly, it was counted as sent, so the stream went on believing
--- the players had a state they never got, and warned at every step it was due.
local function CheckSize(Fire: Blocks.Block, Event: Send)
	if Event.Stream then
		Fire:Line("local Bytes = SendCursor + #SendInstances * UNRELIABLE_INSTANCE_BYTES")
		Fire:Line(
			`if Bytes > MAX_UNRELIABLE_SIZE then error(\`\{Bytes} bytes exceeds the \{MAX_UNRELIABLE_SIZE} byte limit.\`) end`
		)
		return
	end

	Fire:Line(`if not CheckUnreliableSize("{Event.Name}") then return end`)
end

--- Whether this send goes to a batch rather than straight out: a stream's always, an event's under
--- `option BatchUnreliable`. See Batches.luau.
local function Batched(Event: Send): boolean
	local Batch = Event.Stream == true or Batches.Events()
	if Batch then
		State.UsesBatches = true
	end
	return Batch
end

--- Appends the event in the scratch buffer to `Player`'s batch, stamping an ordered event's sequence.
local function AppendTo(Target: Blocks.Block, Event: Send)
	if Event.Ordered then
		Target:Line(`AppendOrdered(Player, {Event.Ordered})`)
	else
		Target:Line("AppendUnreliable(Player)")
	end
end

--- An unreliable server send to one player, `Player`: the unreliable `Fire`, and a `Per: Player`
--- stream's send. Leaves the function open for the caller to end.
function Send.One(Fire: Blocks.Block, Event: Send): Blocks.Block
	Fire:Line("LoadScratch()")
	Fire:Line(Event.WriteEvent)
	CheckSize(Fire, Event)
	if Batched(Event) then
		AppendTo(Fire, Event)
		Fire:Line("KeepScratch()")
		Traffic.Sent(Fire, Event.Traffic, "SendCursor", true)
		return Fire
	end

	Fire:Lines(UNRELIABLE_BODY, 1)
	Send.StampOrder(Fire, Event)
	Fire:Line("Unreliable:FireClient(Player, Buffer, SendInstances)")
	Traffic.Sent(Fire, Event.Traffic, "SendCursor", true)
	return Fire
end

--- The loop over the players a send reaches, leaving out `Except` when asked to.
local function EachRecipient(Target: Blocks.Block, Recipients: string, SkipExcept: boolean?): Blocks.Block
	local Loop = Target:Iterator("_", "Player", Recipients)
	if SkipExcept then
		Loop = Loop:Compare("Player", "Except", "Equals"):Line("continue"):End()
	end

	return Loop
end

--- A server send to more than one player: FireAll, FireList and FireExcept. Each writes the event
--- once into a fresh buffer and hands it to every recipient; they differ only in who that is. An
--- unreliable FireAll hands it to `FireAllClients` instead of looping.
---
--- Traffic is counted per recipient, since each is sent the bytes: a FireAll to twenty players counts
--- twenty events. `FireAllClients` counts the players in the game when it is called.
function Send.Broadcast(
	Fire: Blocks.Block,
	Event: Send,
	Recipients: string,
	Options: { AllClients: boolean?, SkipExcept: boolean? }
): Blocks.Block
	Fire:Line("LoadScratch()")
	Fire:Line(Event.WriteEvent)

	if Event.IsReliable then
		Fire:Lines(RELIABLE_BODY.Header, 1)
		if Options.AllClients then
			Fire:Line(RELIABLE_BODY.Shared)
			if Event.Traffic then
				Fire:Line("local Reached = #Players:GetPlayers()")
				Traffic.Sent(Fire, Event.Traffic, "Size", false, "Reached")
			end
		else
			local Loop = EachRecipient(Fire, Recipients, Options.SkipExcept):Lines(RELIABLE_BODY.Body, 2)
			Traffic.Sent(Loop, Event.Traffic, "Size", false)
			Loop:End()
		end
	elseif Batched(Event) then
		CheckSize(Fire, Event)

		--> An ordered event's sequence is each player's own, so only an unordered one to everyone
		--> goes to the batch everyone shares.
		if Options.AllClients and not Event.Ordered then
			Fire:Line("AppendUnreliable(nil)")
			if Event.Traffic then
				Fire:Line("local Reached = #Players:GetPlayers()")
				Traffic.Sent(Fire, Event.Traffic, "SendCursor", true, "Reached")
			end
		else
			local Loop = EachRecipient(Fire, Recipients, Options.SkipExcept)
			AppendTo(Loop, Event)
			Traffic.Sent(Loop, Event.Traffic, "SendCursor", true)
			Loop:End()
		end
		Fire:Line("KeepScratch()")
	else
		CheckSize(Fire, Event)
		Fire:Lines(UNRELIABLE_BODY, 1)

		--> An ordered packet carries a different number to each player, so it is sent one by one.
		if Options.AllClients and not Event.Ordered then
			Fire:Line("Unreliable:FireAllClients(Buffer, SendInstances)")
			if Event.Traffic then
				Fire:Line("local Reached = #Players:GetPlayers()")
				Traffic.Sent(Fire, Event.Traffic, "SendCursor", true, "Reached")
			end
		else
			local Loop = EachRecipient(Fire, Recipients, Options.SkipExcept)
			Send.StampOrder(Loop, Event)
			Loop:Line("Unreliable:FireClient(Player, Buffer, SendInstances)")
			Traffic.Sent(Loop, Event.Traffic, "SendCursor", true)
			Loop:End()
		end
	end

	return Fire:End()
end

return Send
