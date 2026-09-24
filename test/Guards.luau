--!strict
--- The specs for what this fork exists to do: keep a generated server usable while a client it does
--- not control is sending it whatever it likes.
---
--- Packet bounds, rate limiting, buffers that survive a player leaving mid-invocation, invocation
--- slots that come back, unreliable payloads too large to send, edit-mode stubs. Each was written
--- against a specific failure and each was verified to fail without its guard -- see the commit
--- "Cover the remaining guards with tests that were verified to fail without them".
---
--- Split out of Test.luau so that file could come back under the size limit and stop needing an
--- entry in scripts/check-file-size.sh at all.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local fs = require("@lune/fs")
local task = require("@lune/task")

local ServerEnvironment = require("./Server")

local Assertions = require("./Assertions")

local Client = Modules.Client
local Server = Modules.Server
local MockRequire = Modules.MockRequire

local ErrorPrint = Harness.ErrorPrint

local RunClosure = Assertions.RunClosure

RunClosure("Firing at a player who left does not resurrect their buffer", function()
	--> Upstream issue #84. A remote function's listener may yield, and the player can leave while it
	--> is suspended. PlayerRemoving clears their PlayersMap entry, but the resumed listener then
	--> wrote it straight back -- and nothing removes it a second time, so StepReplication allocated
	--> a buffer and fired a remote at a player who was gone on every Heartbeat, for ever.
	local Received = 0
	local Disconnect = Client.ReliableServer.On(function()
		Received += 1
	end)

	--> The player leaves.
	Shared.SetPlayerInGame(false)
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	--> This is the write a resumed listener performs. It must be dropped, not stored.
	Server.ReliableServer.Fire(Shared.Player, 1)

	--> Long enough for several Heartbeats, so a resurrected entry would replicate at least once.
	task.wait(0.5)

	Disconnect()
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(
			`Failed "Firing at a player who left": the client received {Received} event(s) after the player left.`
		)
	end

	--> And the map must be usable again for a player who is present.
	local ReceivedAfter = 0
	local DisconnectAfter = Client.ReliableServer.On(function()
		ReceivedAfter += 1
	end)

	Server.ReliableServer.Fire(Shared.Player, 1)
	task.wait(0.5)
	DisconnectAfter()

	if ReceivedAfter == 0 then
		ErrorPrint(`Failed "Firing at a player who left": a present player stopped receiving events.`)
	end
end)

RunClosure("Inbound packets are bounded", function()
	--> Upstream issue #45. The server parses a client's buffer in an unbounded loop, one event per
	--> iteration, so `buffer.create(1000000)` used to buy a million listener dispatches inside one
	--> remote callback. Three limits now bound that, and each is checked here.
	local MaxEventsPerPacket = 64

	--> 1. An oversized buffer is refused outright, before anything is parsed.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(64 * 1024), {})

		task.wait(0.2)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": an oversized packet was parsed ({Received} events).`)
		end
	end

	--> 2. A packet carrying more events than the cap is truncated, not parsed whole. Sent through
	--> the real client API so this exercises the same path a legitimate flood would take.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		for _ = 1, MaxEventsPerPacket * 2 do
			Client.ReliableClient.Fire(1)
		end

		task.wait(0.5)
		Disconnect()

		if Received > MaxEventsPerPacket then
			ErrorPrint(
				`Failed "Inbound packets are bounded": {Received} events decoded from one packet, cap is {MaxEventsPerPacket}.`
			)
		end

		if Received == 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": the cap swallowed legitimate traffic entirely.`)
		end
	end

	--> 3. The guard's shape, asserted against the emitted code.
	-->
	--> The remaining protections cannot be observed through these mocks: `Signal:Fire` dispatches via
	--> `task.spawn`, so a throw inside the remote handler lands in another thread and never reaches a
	--> pcall here — a behavioural test would pass whether or not the guard exists, which is worse
	--> than no test. What matters is that the generator still emits them, and that is checkable.
	-->
	--> A TRUNCATED packet is why the pcall is there: one byte tagging an event that carries data
	--> makes the reader run off the end of the buffer, and `Read` advances the cursor with no bounds
	--> check. That packet is SMALLER than a legitimate one, so no size cap can catch it.
	do
		local Source = fs.readFile("../Network/Server.luau")
		local Required = {
			["argument type check"] = `if typeof(Buffer) ~= "buffer" or type(Instances) ~= "table" then`,
			["departed player stops the loop"] = "Player.Parent ~= nil",
			["reliable remote class check"] = `assert(Reliable:IsA("RemoteEvent")`,
			["unreliable remote class check"] = `assert(Unreliable:IsA("UnreliableRemoteEvent")`,
			["oversized packet check"] = "if buffer.len(Buffer) >",
			["instance count check"] = "if #Instances >",
			["decoded event counter"] = "DecodedEvents += 1",
			["decode pcall"] = "local Parsed, Failure = pcall(function()",
			["decode failure is reported"] = `ReportDecodeFailure(Player, "Reliable", EventNames.Reliable[Decoding], Failure)`,
			["unknown event id stops the packet"] = `error("[BlinkBlox]: Unknown event index.")`,
		}

		for Name, Fragment in Required do
			if not string.find(Source, Fragment, 1, true) then
				ErrorPrint(`Failed "Inbound packets are bounded": generated server code has no {Name}.`)
			end
		end
	end

	--> 4. Ordinary traffic still arrives untouched — a cap that breaks the normal path is worse than
	--> the hole it closes.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		Client.ReliableClient.Fire(1)
		task.wait(0.3)
		Disconnect()

		if Received ~= 1 then
			ErrorPrint(`Failed "Inbound packets are bounded": a single legitimate event arrived {Received} time(s).`)
		end
	end

	--> 5. Arguments of the wrong type are dropped rather than dispatched. A client picks what it
	--> passes to FireServer; the generated signature is a promise it never made.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, "not a buffer", {})
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(8), "not a table")
		Remote.OnServerEvent:Fire(Shared.Player)

		task.wait(0.3)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": malformed arguments dispatched {Received} event(s).`)
		end
	end
end)

RunClosure("Edit mode stubs keep the shape of the real API", function()
	--> Upstream issue #81. With `RunService:IsRunning()` false — edit mode, and therefore every
	--> Roblox story framework — the module returns a frozen stub table instead of touching remotes.
	--> A stub whose entries have the wrong SHAPE does not degrade quietly, it raises: `On` returning
	--> nil breaks `local Disconnect = ...On(...)`, and `Iter` returning nil breaks `for ... in`.
	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	local Stub = MockRequire("../Network/Server.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	local Disconnect = Stub.ReliableClient.On(function() end)
	if type(Disconnect) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": On returned {type(Disconnect)}, expected a disconnect function.`)
	end
	Disconnect()

	for _ in Stub.ClientPollEvent.Iter() do
		ErrorPrint(`Failed "Edit mode stubs": Iter yielded a value in edit mode.`)
	end

	if type(Stub.StepReplication) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": StepReplication is {type(Stub.StepReplication)}, expected a function.`)
	end
	Stub.StepReplication()

	--> Firing is a no-op rather than an error: a story that pushes state outward should not crash.
	Stub.ReliableServer.FireAll(1)
end)

RunClosure("Rate limiting", function()
	--> Neither zap nor upstream's rewrite has this, and it is the axis the packet caps cannot cover:
	--> MaxEventsPerPacket bounds one packet, while 200 well-formed packets a second pass every check
	--> there is. The bucket bounds events per second, per player, per event.
	-->
	--> The clock is the mock one from Shared, so "a second passes" is an exact statement rather than
	--> a race with the machine running the suite.

	--> Two things have to be settled before anything is counted.
	-->
	--> Earlier tests reach this event with raw buffers, and events that arrive with no listener bound
	--> are QUEUED and replayed the moment one is -- so attaching a listener and immediately counting
	--> credits this test with traffic it never sent. Attach first, let the replay land, then zero.
	-->
	--> The bucket those earlier events already spent from is cleared through PlayerRemoving, which
	--> dispatches via task.spawn, so it needs a moment of its own.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	local Received = 0
	local Disconnect = Server.RateLimited.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> An event with Rate 5 and Burst 10: ten arrive at once, the rest are refused.
	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)

	if Received ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Received} of 15 events arrived, expected the burst of 10.`)
	end

	--> One second of clock buys exactly five more tokens.
	Shared.AdvanceClock(1)

	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)
	Disconnect()

	if Received ~= 15 then
		ErrorPrint(`Failed "Rate limiting": {Received - 10} events arrived after a second, expected 5.`)
	end

	--> The polling path enqueues instead of dispatching, and is gated in the same place.
	Shared.AdvanceClock(10)

	for _ = 1, 15 do
		Client.RateLimitedPoll.Fire(1)
	end

	task.wait(0.4)

	local Polled = 0
	for _ in Server.RateLimitedPoll.Iter() do
		Polled += 1
	end

	if Polled ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Polled} of 15 polled events were queued, expected 10.`)
	end

	--> A refused INVOCATION still has to be answered. The caller is suspended with no timeout, so a
	--> silently dropped call would hang that coroutine until its slot was reused by an unrelated
	--> call -- which would then resume the wrong thread.
	Shared.AdvanceClock(10)
	Server.RateLimitedCall.On(function(_Player, Value)
		return Value
	end)

	local Succeeded, Refused = 0, 0
	for _ = 1, 4 do
		local Ok = pcall(function()
			return Client.RateLimitedCall.Invoke(1)
		end)

		if Ok then
			Succeeded += 1
		else
			Refused += 1
		end
	end

	if Succeeded ~= 2 or Refused ~= 2 then
		ErrorPrint(
			`Failed "Rate limiting": {Succeeded} invocations succeeded and {Refused} were refused, expected 2 and 2.`
		)
	end
end)

RunClosure("Invocation slots are recycled", function()
	--> The old allocator was a counter that wrapped at 255 and released a slot only on the error
	--> path, never on success. Two calls in flight across the wrap collided: the reused id was still
	--> occupied, so the collision check refused a legitimate call. A bitset hands out the first free
	--> slot instead, and a reply gives it straight back.

	Server.RemoteFunction.On(function(_Player, Value)
		task.wait(0.4)
		return Value
	end)

	local Completed, Refused = 0, 0
	for _ = 1, 40 do
		task.spawn(function()
			local Ok = pcall(function()
				return Client.RemoteFunction.Invoke(1)
			end)

			if Ok then
				Completed += 1
			else
				Refused += 1
			end
		end)
	end

	task.wait(1.5)

	--> Thirty-two slots exist, so eight of the forty must be turned away with an error rather than
	--> silently handed an id that belongs to another call.
	if Completed ~= 32 then
		ErrorPrint(`Failed "Invocation slots": {Completed} of 40 concurrent calls completed, expected 32.`)
	end

	if Refused ~= 8 then
		ErrorPrint(`Failed "Invocation slots": {Refused} calls were refused, expected 8.`)
	end

	--> And the slots came back: a call after the storm must simply work.
	local Success = pcall(function()
		return Client.RemoteFunction.Invoke(1)
	end)

	if not Success then
		ErrorPrint(`Failed "Invocation slots": a call after the burst was refused, so slots leaked.`)
	end
end)

RunClosure("Oversized unreliable payloads are dropped, not sent", function()
	--> Roblox drops an unreliable payload past ~900 bytes silently. The compiler refuses schemas that
	--> can never fit and warns about the ones that might not, but a bounded schema can still overflow
	--> at runtime -- a string longer than the game assumed -- and that packet would vanish with
	--> nobody told which event lost it.
	local Received = 0
	local Disconnect = Server.UnreliableOversize.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> Well under the limit: ordinary traffic must be untouched.
	Client.UnreliableOversize.Fire(string.rep("a", 32))
	task.wait(0.3)

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": a small payload arrived {Received} time(s), expected 1.`)
	end

	--> Past the limit: dropped at the send, with a warning naming the event.
	Client.UnreliableOversize.Fire(string.rep("a", 2000))
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": an oversized payload was sent anyway.`)
	end
end)

RunClosure("Decoding stops when the player leaves", function()
	--> Every listener that runs past this point is handed a Player already detached from the
	--> DataModel, and anything it does with them -- a leaderstats write, a save -- is work aimed at
	--> nobody. The loop condition now checks, so the rest of that packet is not decoded.
	local Received = 0
	local Disconnect = Server.ReliableClient.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	Shared.SetPlayerInGame(false)
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": {Received} event(s) were still dispatched.`)
	end

	--> And a present player is unaffected -- a guard that broke the normal path would be worse than
	--> the case it closes.
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": a present player received {Received}, expected 1.`)
	end
end)
