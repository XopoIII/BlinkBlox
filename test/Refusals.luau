--!strict
--- The second half of the guard specs: what the server does with traffic it will not act on -- a
--- queue nobody drains, a packet it cannot decode, an invocation of a player who has left, a channel
--- with no events on it, a burst of refused events -- and how it reports each to the game.
---
--- Split out of Guards.luau at the size limit. They run straight after it, as they did inside it.
local Assertions = require("./Assertions")
local ClientEnvironment = require("./Client")
local Harness = require("./Harness")
local Modules = require("./Modules")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local fs = require("@lune/fs")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server
local MockRequire = Modules.MockRequire
local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--> The index the generated server gave a declaration, read out of the module rather than hard-coded,
--> so a declaration added above it cannot quietly retarget a spec.
local function ReliableIndex(Name: string): number
	local Source = fs.readFile("../Network/Server.luau")
	local Index = string.match(Source, `EventNames%.Reliable%[(%d+)%] = "{Name}"`)
	assert(Index, `The server module has no reliable index for "{Name}".`)
	return tonumber(Index) :: number
end

--> Sends `Count` copies of one raw event, in packets small enough for the inbound caps to accept.
local function Flood(Event: { number }, Count: number)
	local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
	local Sent = 0
	while Sent < Count do
		local Batch = math.min(60, Count - Sent)
		local Packet = buffer.create(Batch * #Event)
		for Copy = 0, Batch - 1 do
			for Offset, Byte in Event do
				buffer.writeu8(Packet, Copy * #Event + Offset - 1, Byte)
			end
		end

		Remote.OnServerEvent:Fire(Shared.Player, Packet, {})
		Sent += Batch
	end

	task.wait(0.3)
end

RunClosure("A client cannot grow a polled event's queue past its cap", function()
	--> The same fault as the listener queue above, on the other queue a client fills: a polled event
	--> is stored until the game asks for it, and a game that asks rarely, or not yet, let a client grow
	--> it without end. It stops at 256 rows per player the server can hold, one in the mock.
	--> Whatever earlier specs left queued, drained first.
	local Drain = Server.ClientEmptyPollEvent.Iter()
	while Drain() ~= nil do
		continue
	end

	Flood({ ReliableIndex("ClientEmptyPollEvent") }, 300)

	local Polled = 0
	for _ in Server.ClientEmptyPollEvent.Iter() do
		Polled += 1
	end

	if Polled ~= 256 then
		ErrorPrint(`Failed "Polled queue": {Polled} rows were queued, expected the cap of 256.`)
	end
end)

RunClosure("A client cannot grow the queue of an event nobody listens to", function()
	--> Upstream issue #93. Events that arrive with no listener bound are queued for the listener
	--> that has not connected yet -- and on the server, a client decides how many arrive. Uncapped,
	--> an event the game never handles grew server memory for as long as a client kept sending,
	--> with a warning per event past 256.
	Shared.DrainWarnings()
	Flood({ ReliableIndex("Unlistened") }, 300)
	local Warned = #Shared.DrainWarnings()

	local Replayed = 0
	local Disconnect = Server.Unlistened.On(function()
		Replayed += 1
	end)

	task.wait(0.3)
	Disconnect()

	if Replayed ~= 256 then
		ErrorPrint(`Failed "Unlistened queue": {Replayed} queued events were replayed, expected the cap of 256.`)
	end

	if Warned ~= 0 then
		ErrorPrint(`Failed "Unlistened queue": the server printed {Warned} warning(s) about a client's traffic.`)
	end

	--> Invocations the same way, except that a caller past the cap is answered with a failure rather
	--> than dropped. Those answers are counted on their way to the client: three bytes each, the
	--> function's index, the invocation id and a zero for "failed".
	local Index = ReliableIndex("Unanswered")
	local Refused = 0
	local Spy = ClientEnvironment.Instances.BLINK_RELIABLE_REMOTE.OnClientEvent:Connect(function(Packet: buffer)
		for Offset = 0, buffer.len(Packet) - 3, 3 do
			if buffer.readu8(Packet, Offset) == Index and buffer.readu8(Packet, Offset + 2) == 0 then
				Refused += 1
			end
		end
	end)

	Flood({ Index, 0 }, 300)
	Spy:Disconnect()

	if Refused ~= 300 - 256 then
		ErrorPrint(`Failed "Unlistened queue": {Refused} invocations past the cap were refused, expected {300 - 256}.`)
	end

	local Answered = 0
	Server.Unanswered.On(function()
		Answered += 1
	end)

	task.wait(0.3)

	if Answered ~= 256 then
		ErrorPrint(`Failed "Unlistened queue": {Answered} queued invocations were run, expected the cap of 256.`)
	end
end)

RunClosure("A packet the server cannot decode is reported to the game", function()
	--> Upstream issue #102. The server abandons such a packet silently, which is right for its
	--> output and wrong for the game: it could not tell who sent it or what it claimed to be.
	local Reports: { { Player: any, Event: string?, Failure: string } } = {}
	Server.SetDecodeErrorHandler(function(Player, Event, Failure)
		table.insert(Reports, { Player = Player, Event = Event, Failure = Failure })
	end)

	local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE

	--> Truncated: the index of an event with a one-byte payload, and no payload.
	Remote.OnServerEvent:Fire(Shared.Player, buffer.fromstring(string.char(ReliableIndex("PlainFromClient"))), {})
	task.wait(0.2)

	--> Nonsense: an index that names no event.
	Remote.OnServerEvent:Fire(Shared.Player, buffer.fromstring("\255"), {})
	task.wait(0.2)

	Server.SetDecodeErrorHandler(nil)

	local Truncated, Unknown = Reports[1], Reports[2]
	if #Reports ~= 2 or not Truncated or not Unknown then
		ErrorPrint(`Failed "Decode reports": {#Reports} report(s), expected 2.`)
		return
	end

	if Truncated.Player ~= Shared.Player or Truncated.Event ~= "PlainFromClient" then
		ErrorPrint(`Failed "Decode reports": a truncated packet was reported as "{Truncated.Event}".`)
	end

	if Unknown.Event ~= nil or not string.find(Unknown.Failure, "Unknown event index", 1, true) then
		ErrorPrint(`Failed "Decode reports": an unknown index was reported as "{Unknown.Event}": {Unknown.Failure}`)
	end
end)

RunClosure("Invoking a player who has left fails at once", function()
	--> Claiming a slot for a departed player put back the tables PlayerRemoving had just cleared,
	--> where nothing removed them again, and parked the caller for the whole timeout.
	Shared.SetPlayerInGame(false)
	local Started = os.clock()
	local Ok, Failure = pcall(Server.AskClient.Invoke, Shared.Player, 1)
	local Elapsed = os.clock() - Started
	Shared.SetPlayerInGame(true)

	if Ok or not string.find(tostring(Failure), "no longer in the game", 1, true) then
		ErrorPrint(`Failed "Invoking a departed player": {if Ok then "it succeeded" else tostring(Failure)}.`)
	end

	if Elapsed > 1 then
		ErrorPrint(`Failed "Invoking a departed player": it took {Elapsed} seconds to fail.`)
	end
end)

RunClosure("A packet on a channel with no events is reported once and read no further", function()
	--> Drift's server receives nothing: every event in it is From: Server, so neither of its channels
	--> has an index to branch on. Its decode loop used to read the index byte and succeed, so a
	--> packet of junk was consumed byte after byte up to MaxEventsPerPacket and never reported.
	-->
	--> Its own copy, loaded here, because it has a decode handler of its own. It shares the mock
	--> remotes with Test's server, which is why the bytes are 255 -- an index Test's server knows
	--> nothing about either -- and why the signature it writes is put back afterwards.
	local Signatures = table.clone(Shared.Attributes.BLINK_RELIABLE_REMOTE or {})
	local Empty = MockRequire("../Network/DriftServer.luau", {
		game = ServerEnvironment.game,
		Color3 = ServerEnvironment.Color3,
		DateTime = ServerEnvironment.DateTime,
		BrickColor = ServerEnvironment.BrickColor,
	})
	Shared.Attributes.BLINK_RELIABLE_REMOTE = Signatures

	local Reports: { { Event: string?, Failure: string } } = {}
	Empty.SetDecodeErrorHandler(function(_Player, Event, Failure)
		table.insert(Reports, { Event = Event, Failure = Failure })
	end)

	Shared.DrainWarnings()
	local Junk = buffer.fromstring(string.rep("\255", 100))
	ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE.OnServerEvent:Fire(Shared.Player, Junk, {})
	ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE.OnServerEvent:Fire(Shared.Player, Junk, {})
	task.wait(0.3)
	Empty.SetDecodeErrorHandler(nil)

	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "too many events", 1, true) then
			ErrorPrint(`Failed "Empty channel": the packet was read up to the event cap: {Warning}`)
		end
	end

	if #Reports ~= 2 then
		ErrorPrint(`Failed "Empty channel": {#Reports} report(s) for two junk packets, expected one each.`)
		return
	end

	for _, Report in Reports do
		if Report.Event ~= nil or not string.find(Report.Failure, "receives no events", 1, true) then
			ErrorPrint(`Failed "Empty channel": reported as "{Report.Event}": {Report.Failure}`)
		end
	end
end)

RunClosure("A burst of refused events is reported once a second, with its count", function()
	--> The warning was limited to once a second and the handler was not: a client sending hundreds
	--> of refused events a frame spawned hundreds of handler threads a frame, which is the flood the
	--> limit exists to absorb, moved into the game's own analytics.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	local Disconnect = Server.RateLimited.On(function() end)
	task.wait(0.2)
	Shared.AdvanceClock(10)

	local Reports: { { Event: string, Refused: number? } } = {}
	Server.SetRateLimitHandler(function(_Player, Event, Refused)
		table.insert(Reports, { Event = Event, Refused = Refused })
	end)

	--> Rate 5, Burst 10: fifteen at once is ten accepted and five refused. The first refusal is
	--> reported at once and the other four are held for the next report.
	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end
	task.wait(0.4)

	local First = #Reports
	local FirstCount = Reports[1] and Reports[1].Refused

	--> A second later: five refilled tokens, ten refusals, one report standing for the four held
	--> back and the one that made it.
	Shared.AdvanceClock(1)
	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end
	task.wait(0.4)

	Disconnect()
	Server.SetRateLimitHandler(nil)

	if First ~= 1 or FirstCount ~= 1 then
		ErrorPrint(
			`Failed "Rate reports": five refusals made {First} report(s) counting {FirstCount}, expected 1 of 1.`
		)
	end

	local Second = Reports[2]
	if #Reports ~= 2 or not Second or Second.Refused ~= 5 or Second.Event ~= "RateLimited" then
		ErrorPrint(
			`Failed "Rate reports": {#Reports} report(s) after a second, the last counting {Second and Second.Refused}, expected 2 and 5.`
		)
	end
end)

return {}
