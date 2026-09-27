--!strict
--- Specs for the per-player outbound budget, `option OutboundBytesPerSecond`: every byte the server
--- sends a player is charged to that player, and a `Priority: Low` send is left out while the player's
--- budget is spent. Nothing else is ever held back for it.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure

--> A burst of 1000 bytes. Each Chatter or Hit below is 303 bytes on the wire: its index, a two-byte
--> length and 300 bytes of payload.
local SCHEMA = [[
option OutboundBytesPerSecond = 1000
event Chatter { From: Server, Type: Unreliable, Call: SingleSync, Priority: Low, Data: buffer(0..400) }
event Hit { From: Server, Type: Unreliable, Call: SingleSync, Data: buffer(0..400) }
event Score { From: Server, Type: Reliable, Call: SingleSync, Data: buffer(0..4000) }
event Mine {
	From: Server,
	Type: OrderedUnreliable,
	Call: SingleSync,
	Priority: Low,
	Stream: { Rate: 20, Per: Player },
	Data: u16
}
]]

local PAYLOAD = buffer.create(300)
local LARGE = buffer.create(1200)

local Pairs = 0
local function Pair(): Isolated.Pair
	Pairs += 1
	return Isolated.Build(Isolated.Parse(SCHEMA), `OUTBOUND{Pairs}`)
end

RunClosure("A low event goes until the player's budget is spent, and a normal one always goes", function()
	local Built = Pair()
	for _ = 1, 6 do
		Built.Server.Chatter.Fire(Shared.Player, PAYLOAD)
	end

	--> 1000, 697, 394 and 91 are all above zero, so four go; the fifth finds -212.
	assert(#Built.Outbound == 4, `expected 4 low sends before the budget ran out, got {#Built.Outbound}`)

	for _ = 1, 3 do
		Built.Server.Hit.Fire(Shared.Player, PAYLOAD)
	end
	assert(#Built.Outbound == 7, `a normal event was held back for the budget: {#Built.Outbound} sends`)
end)

RunClosure("A spent budget refills, and a low event goes again", function()
	local Built = Pair()
	for _ = 1, 5 do
		Built.Server.Chatter.Fire(Shared.Player, PAYLOAD)
	end
	assert(#Built.Outbound == 4, `expected 4 low sends, got {#Built.Outbound}`)

	--> -212 plus a second of refill is 788: back above zero.
	Shared.AdvanceClock(1)
	Built.Server.Chatter.Fire(Shared.Player, PAYLOAD)
	assert(#Built.Outbound == 5, "a refilled budget still left the low event out")
end)

RunClosure("A reliable broadcast is charged to everyone it reaches", function()
	local Built = Pair()
	Built.Server.Score.FireAll(LARGE)
	Built.Server.StepReplication()
	assert(#Built.Delivered == 1, "the reliable broadcast did not go out")

	Built.Server.Chatter.Fire(Shared.Player, PAYLOAD)
	assert(#Built.Outbound == 0, "the broadcast's bytes were not charged to the player")
end)

RunClosure("A low FireAll leaves out only the players whose budget is spent", function()
	local Built = Pair()
	Built.Server.Chatter.FireAll(PAYLOAD)
	assert(#Built.Outbound == 1 and Built.Outbound[1].Player == Shared.Player, "a low FireAll did not go to the player")

	Built.Server.Score.Fire(Shared.Player, LARGE)
	Built.Server.StepReplication()
	Built.Server.Chatter.FireAll(PAYLOAD)
	assert(#Built.Outbound == 1, "a low FireAll reached a player whose budget was spent")
end)

RunClosure("A low stream held per player waits for the budget, then sends its latest state", function()
	local Built = Pair()
	local Received: { number } = {}
	Built.Client.Mine.On(function(Value)
		table.insert(Received, Value)
	end)

	Built.Server.Score.Fire(Shared.Player, LARGE)
	Built.Server.StepReplication()

	Built.Server.Mine.Set(Shared.Player, 1)
	Built.Server.Mine.Urgent(Shared.Player)
	Built.Server.StepReplication()
	assert(#Built.Outbound == 0, "a low stream was sent to a player whose budget was spent")

	Shared.AdvanceClock(2)
	Built.Server.Mine.Set(Shared.Player, 2)
	Built.Server.StepReplication()
	assert(#Built.Outbound == 1, `expected the held state once the budget refilled, got {#Built.Outbound} sends`)

	Built.Deliver(Built.Outbound[1])
	task.wait(0.1)
	assert(#Received == 1 and Received[1] == 2, `the client received {table.concat(Received, ", ")}, expected 2`)
end)

RunClosure("A schema without the option has no outbound budget in its module", function()
	local Source = string.gsub(SCHEMA, "option OutboundBytesPerSecond = 1000\n", "")
	local Server = Generator.Generate("Server", Isolated.Parse(Source))
	assert(not string.find(Server, "Outbound", 1, true), "a module without the option carries the budget")
end)
