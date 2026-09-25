--!strict
--!native
--!optimize 2

--- The server's sends to more than one player, shared by an event's FireAll, FireList and FireExcept
--- and by a stream's scheduled send (Stream.luau): each writes the event once into a fresh buffer and
--- hands it to every recipient, stamping each one's own sequence number into an ordered packet.
local Blocks = require("./Blocks")
local Fragments = require("./Fragments")

local RELIABLE_BODY = Fragments.RELIABLE_BODY
local UNRELIABLE_BODY = Fragments.UNRELIABLE_BODY

local Sends = {}

--- What a server send needs to know about the event it sends. `Ordered` is the event's index when it
--- is an ordered unreliable one, whose sequence number each send stamps per recipient.
export type Send = { IsReliable: boolean, WriteEvent: string, Name: string, Ordered: number? }

--- Stamps the recipient's own sequence number into an ordered packet. An unreliable server send always
--- starts from a fresh buffer, so the event sits at offset 0 and its sequence at offset 1.
function Sends.StampOrder(Into: Blocks.Block, Target: Send)
	if Target.Ordered then
		Into:Line(`buffer.writeu16(Buffer, 1, NextOrder(Player, {Target.Ordered}))`)
	end
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
function Sends.Broadcast(
	Fire: Blocks.Block,
	Target: Send,
	Recipients: string,
	Options: { AllClients: boolean?, SkipExcept: boolean? }
): Blocks.Block
	Fire:Line("Load()")
	Fire:Line(Target.WriteEvent)

	if Target.IsReliable then
		Fire:Line(RELIABLE_BODY.Header)
		EachRecipient(Fire, Recipients, Options.SkipExcept):Lines(RELIABLE_BODY.Body, 2):End()
	else
		Fire:Line(`if not CheckUnreliableSize("{Target.Name}") then return end`)
		Fire:Lines(UNRELIABLE_BODY, 1)

		--> An ordered packet carries a different number to each player, so it is sent one by one.
		if Options.AllClients and not Target.Ordered then
			Fire:Line("Unreliable:FireAllClients(Buffer, SendInstances)")
		else
			local Loop = EachRecipient(Fire, Recipients, Options.SkipExcept)
			Sends.StampOrder(Loop, Target)
			Loop:Line("Unreliable:FireClient(Player, Buffer, SendInstances)"):End()
		end
	end

	return Fire:End()
end

return Sends
