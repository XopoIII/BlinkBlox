--!strict
--!native
--!optimize 2

--- The server's sends to more than one player -- FireAll, FireList, FireExcept -- and the pieces
--- they share with a send to one: the loop over recipients and the per-recipient sequence stamp.
---
--- Moved out of Event.luau when that file reached its size cap.
local Blocks = require("./Blocks")
local Fragments = require("./Fragments")
local Traffic = require("./Traffic")

local RELIABLE_BODY = Fragments.RELIABLE_BODY
local UNRELIABLE_BODY = Fragments.UNRELIABLE_BODY

local Send = {}

--- What a server send needs to know about the event it sends. `Ordered` is the event's index when it
--- is an ordered unreliable one, whose sequence number each send stamps per recipient. `Traffic` is
--- where its counters start under `option TrafficStats`, and nil otherwise.
export type Send = { IsReliable: boolean, WriteEvent: string, Name: string, Ordered: number?, Traffic: number? }

--- Stamps the recipient's own sequence number into an ordered packet. An unreliable server send always
--- starts from a fresh buffer, so the event sits at offset 0 and its sequence at offset 1.
function Send.StampOrder(Target: Blocks.Block, Event: Send)
	if Event.Ordered then
		Target:Line(`buffer.writeu16(Buffer, 1, NextOrder(Player, {Event.Ordered}))`)
	end
end

--- An unreliable server send to one player, `Player`: the unreliable `Fire`, and a `Per: Player`
--- stream's send. Leaves the function open for the caller to end.
function Send.One(Fire: Blocks.Block, Event: Send): Blocks.Block
	Fire:Line("Load()")
	Fire:Line(Event.WriteEvent)
	Fire:Line(`if not CheckUnreliableSize("{Event.Name}") then return end`)
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
	Fire:Line("Load()")
	Fire:Line(Event.WriteEvent)

	if Event.IsReliable then
		Fire:Line(RELIABLE_BODY.Header)
		local Loop = EachRecipient(Fire, Recipients, Options.SkipExcept):Lines(RELIABLE_BODY.Body, 2)
		Traffic.Sent(Loop, Event.Traffic, "Size", false)
		Loop:End()
	else
		Fire:Line(`if not CheckUnreliableSize("{Event.Name}") then return end`)
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
