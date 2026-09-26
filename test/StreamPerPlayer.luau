--!strict
--- Specs for a `Per: Player` stream (docs/src/content/docs/language/streams.mdx): each player's state
--- is theirs -- sent to them alone, compared, kept alive, cleared and sped up on its own -- and a
--- player who leaves takes their state with them. The scheduler's timing is Streams.luau's.
local Assertions = require("./Assertions")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local Support = require("./StreamSupport")

local RunClosure = Assertions.RunClosure
local Expect = Support.Expect

local SCHEMA = [[
event Gap {
	From: Server,
	Type: OrderedUnreliable,
	Call: SingleSync,
	Stream: { Rate: 10, Fast: 20, Keepalive: 1, Per: Player },
	Data: f64
}
]]

--- A second player beside Shared.Player: only its identity and whether it is still in the game
--- matter to a per-player stream.
local InGame = true
local Second = newproxy(true)
local Metatable = getmetatable(Second)
Metatable.__tostring = function()
	return "Second"
end
Metatable.__index = function(_self, Key: string)
	if Key == "Parent" then
		return if InGame then {} else nil
	end
	return nil
end

local First = Shared.Player
local Built = 0

local function Fresh(): Isolated.Pair
	Built += 1
	InGame = true
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), `PERPLAYER{Built}`)
	Pair.Server.StepReplication()
	return Pair
end

--- `Count` frames. For each player, the frames that sent to them, counting from 1.
local function Frames(Pair: Isolated.Pair, Count: number, Each: ((Frame: number) -> ())?): { [any]: { number } }
	local Sent: { [any]: { number } } = { [First] = {}, [Second] = {} }
	for Index = 1, Count do
		if Each then
			Each(Index)
		end

		local Before = #Pair.Outbound
		Shared.AdvanceClock(Support.FRAME)
		Pair.Server.StepReplication()
		for Packet = Before + 1, #Pair.Outbound do
			local To = Pair.Outbound[Packet].Player
			assert(Sent[To], `frame {Index} sent to {To}, who is neither player`)
			assert(Sent[To][#Sent[To]] ~= Index, `frame {Index} sent to {To} twice`)
			table.insert(Sent[To], Index)
		end
	end

	return Sent
end

--- What the client makes of every packet sent to `Player`, in order.
local function Received(Pair: Isolated.Pair, Player: any): { string }
	local Got: { string } = {}
	Pair.Client.Gap.On(function(Value)
		table.insert(Got, if Value == nil then "nil" else tostring(Value))
	end)
	for _, Packet in Pair.Outbound do
		if Packet.Player == Player then
			Pair.Deliver(Packet)
		end
	end
	return Got
end

RunClosure("A per-player stream sends each player their own state, to them alone", function()
	local Pair = Fresh()
	Pair.Server.Gap.Set(First, 1.5)
	Pair.Server.Gap.Set(Second, 2.5)

	local Sent = Frames(Pair, 1)
	Expect("frames to the first", Sent[First], { 1 })
	Expect("frames to the second", Sent[Second], { 1 })

	--> Nothing goes out to everyone: every packet names its player, and carries that player's state
	--> after the six bytes of header. Read from the bytes, since the one client here would take the
	--> second player's packet, numbered 1 like the first's, as stale.
	local States: { [any]: number } = {}
	for _, Packet in Pair.Outbound do
		assert(Packet.Player ~= nil, "a per-player stream used FireAllClients")
		States[Packet.Player] = buffer.readf64(Packet.Buffer, 6)
	end
	Expect("the states", { States[First], States[Second] }, { 1.5, 2.5 })
end)

RunClosure("Each player's state is compared and kept alive on its own", function()
	local Pair = Fresh()
	Pair.Server.Gap.Set(First, 1)
	Pair.Server.Gap.Set(Second, 1)

	--> The first's state never changes: sent at once, then only at the keepalive a second on. The
	--> second's changes at frames 10 and 20: sent at the next due step after each, and once more at
	--> the step after that, so the client learns it stopped.
	local Sent = Frames(Pair, 70, function(Frame)
		if Frame == 10 or Frame == 20 then
			Pair.Server.Gap.Set(Second, Frame)
		end
	end)

	Expect("frames to the first", Sent[First], { 1, 61 })
	Expect("frames to the second", Sent[Second], { 1, 13, 19, 25, 31 })
end)

RunClosure("Clear, Urgent and SetFast touch only the player they name", function()
	local Pair = Fresh()
	Pair.Server.Gap.Set(First, 1)
	Pair.Server.Gap.Set(Second, 1)
	Frames(Pair, 1)

	--> Cleared: the first gets nil at the next step and nothing after; the second keeps its keepalive.
	Pair.Server.Gap.Clear(First)
	local Sent = Frames(Pair, 60)
	Expect("frames to the first after Clear", Sent[First], { 1 })
	Expect("frames to the second after the first's Clear", Sent[Second], { 60 })
	Expect("the first's states", Received(Pair, First), { "1", "nil" })

	--> Urgent: the second at the next step, the first -- holding nothing -- not at all.
	Pair.Server.Gap.Urgent(Second)
	Pair.Server.Gap.Urgent(First)
	Sent = Frames(Pair, 1)
	Expect("frames to the first after Urgent", Sent[First], {})
	Expect("frames to the second after Urgent", Sent[Second], { 1 })

	--> SetFast on the second: a state changing every frame goes out every 3 frames to it, every 6 to
	--> the first. The first was just sent, so its clock starts at 0; the second's has run a frame
	--> since its Urgent send, so it comes due a frame sooner.
	Pair.Server.Gap.Set(First, 0)
	Frames(Pair, 1)
	Pair.Server.Gap.SetFast(Second, true)
	Sent = Frames(Pair, 12, function(Frame)
		Pair.Server.Gap.Set(First, Frame)
		Pair.Server.Gap.Set(Second, Frame)
	end)
	Expect("frames to the first, at Rate", Sent[First], { 6, 12 })
	Expect("frames to the second, at Fast", Sent[Second], { 2, 5, 8, 11 })
end)

RunClosure("Setting a player's state to nil throws, and names Clear", function()
	local Pair = Fresh()
	local Thrown, Failure = pcall(Pair.Server.Gap.Set, First, nil)
	assert(not Thrown, "Set(Player, nil) was accepted")
	local Message = 'Stream "Gap" cannot be set to nil. Call Clear to clear it.'
	assert(string.find(tostring(Failure), Message, 1, true), `threw "{Failure}", expected "{Message}"`)
	Expect("frames after the refused Set", Frames(Pair, 60)[First], {})
end)

RunClosure("A player who leaves takes their state, and one who has left gets none", function()
	local Pair = Fresh()
	Pair.Server.Gap.Set(First, 1)
	Pair.Server.Gap.Set(Second, 1)
	Frames(Pair, 1)

	--> PlayerRemoving drops the state while the player is still parented: no keepalive follows.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Second)
	local Sent = Frames(Pair, 120)
	Expect("frames to the second after leaving", Sent[Second], {})
	Expect("frames to the first meanwhile", Sent[First], { 60, 120 })

	--> Detached, the player is not given a new state by a late Set or SetFast, and a late Clear or
	--> Urgent finds nothing to act on. Apart, so a Clear cannot cancel the Set before it is sent.
	InGame = false
	Pair.Server.Gap.Set(Second, 2)
	Pair.Server.Gap.SetFast(Second, true)
	Sent = Frames(Pair, 120)
	Expect("frames to the second after a late Set", Sent[Second], {})

	Pair.Server.Gap.Clear(Second)
	Pair.Server.Gap.Urgent(Second)
	Sent = Frames(Pair, 120)
	Expect("frames to the second after a late Clear and Urgent", Sent[Second], {})
	InGame = true
end)

return {}
