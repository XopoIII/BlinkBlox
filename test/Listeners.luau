--!strict
--- Specs for how listeners are called: Async dispatch on pooled threads, and what a second listener
--- on a Single event does.
---
--- They live apart from Test.luau but run as part of the same suite, in the place they held there.
local Assertions = require("./Assertions")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server
local RunClosure = Assertions.RunClosure

--> Async dispatch runs on a pooled thread rather than a fresh one. The pool has exactly one thread,
--> so what has to hold is that a listener which YIELDS keeps the one it was given and the next
--> dispatch gets another -- otherwise a single slow listener would serialise every Async event in
--> the game behind it.
RunClosure("A yielding Async listener does not hold up the next dispatch", function()
	local Order: { number } = {}

	local Disconnect = Client.ReliableServerAsync.On(function(Value: number)
		table.insert(Order, Value)
		if Value == 1 then
			task.wait(0.2)
		end
		table.insert(Order, Value * 10)
	end)

	task.wait(1 / 30)
	table.clear(Order)

	Server.ReliableServerAsync.FireAll(1)
	Server.ReliableServerAsync.FireAll(2)
	task.wait(1 / 30)

	assert(table.find(Order, 2), "the second listener never ran while the first was yielding")
	assert(table.find(Order, 20), "the second listener did not finish while the first was yielding")
	assert(not table.find(Order, 10), "the yielding listener finished early, so it never yielded")

	--> And the thread it kept still comes back.
	task.wait(0.4)
	Disconnect()

	assert(table.find(Order, 10), "the yielding listener never resumed")
end)

--> Upstream #167. A Single event keeps one listener and a second `.On()` replaces it. That is the
--> intended behaviour and is not changing; what is new is that it says so, because the silence hid
--> something worse than the replacement itself.
RunClosure("A second listener on a Single event is reported, and the first one's disconnect stops working", function()
	local First, Second = 0, 0

	local DisconnectFirst = Client.ReliableServer.On(function()
		First += 1
	end)

	--> Let anything queued reach the first listener before the second one takes over.
	task.wait(1 / 30)
	Shared.DrainWarnings()

	local DisconnectSecond = Client.ReliableServer.On(function()
		Second += 1
	end)

	local Warned = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "already has a listener", 1, true) then
			Warned = true
			break
		end
	end

	if not Warned then
		DisconnectSecond()
		error("replacing a Single listener said nothing about it")
	end

	First, Second = 0, 0

	--> The replacement is what runs.
	Server.ReliableServer.FireAll(1)
	task.wait(1 / 30)
	assert(First == 0 and Second == 1, `expected only the newest listener to run, got {First} and {Second}`)

	--> And the hazard the warning names: the displaced listener's disconnect is guarded by an
	--> identity check that no longer matches, so calling it does nothing at all -- including not
	--> detaching the listener that replaced it.
	DisconnectFirst()

	Server.ReliableServer.FireAll(1)
	task.wait(1 / 30)
	assert(Second == 2, "the displaced listener's disconnect detached the wrong listener")

	DisconnectSecond()
end)

--> An event that arrives before its listener is queued and replayed when the listener connects. The
--> row was a table literal replayed with `table.unpack`, which stops at whatever border `#` finds:
--> for `(1, nil, nil, 4, nil)` that is 1, and the listener was handed only the first value.
RunClosure("A queued event keeps every value after a nil", function()
	Server.QueuedHoles.FireAll(1, nil, nil, 4, nil)
	task.wait(1 / 30)

	local Count, Fourth
	local Disconnect = Client.QueuedHoles.On(function(...)
		Count = select("#", ...)
		Fourth = select(4, ...)
	end)
	Disconnect()

	assert(Fourth == 4, `the queued event was replayed with {Count} value(s) and no 4`)
end)

--> A Many event dispatches by walking its list of listeners. Disconnecting removed from that same
--> list, so a listener that disconnected itself during dispatch -- the usual shape of a "once" --
--> shifted the next listener into the index the loop had just passed, and that one never ran.
RunClosure("A listener that disconnects itself does not cost the next one the event", function()
	local Seen: { string } = {}
	local DisconnectFirst: () -> ()
	DisconnectFirst = Client.ManyReliableSync.On(function()
		table.insert(Seen, "first")
		DisconnectFirst()
	end)
	local DisconnectSecond = Client.ManyReliableSync.On(function()
		table.insert(Seen, "second")
	end)

	Server.ManyReliableSync.FireAll(1)
	task.wait(1 / 30)
	DisconnectSecond()

	assert(#Seen == 2, `one fire reached {table.concat(Seen, " and ")}, expected first and second`)
end)

--> A Sync listener runs inside the pcall that guards decoding, so a listener that threw used to be
--> reported as a packet that could not be decoded: blamed on the sender, and the rest of the packet
--> dropped along with every listener after it. The listener's error is its own now, raised on a thread
--> of its own, and decoding carries on.
RunClosure("A Sync listener that throws costs nothing but its own call", function()
	local Raised: { string } = {}
	Shared.Task.spawn = function(Function, ...)
		if Function == error then
			table.insert(Raised, tostring((...)))
			return nil :: any
		end

		return task.spawn(Function, ...)
	end

	local Second = 0
	local DisconnectFirst = Client.ManyReliableSync.On(function()
		error("a bug in the game")
	end)
	local DisconnectSecond = Client.ManyReliableSync.On(function()
		Second += 1
	end)

	Shared.DrainWarnings()
	--> Two events in one frame, so one packet.
	Server.ManyReliableSync.FireAll(1)
	Server.ManyReliableSync.FireAll(2)
	task.wait(1 / 30)

	DisconnectFirst()
	DisconnectSecond()
	Shared.Task.spawn = nil :: any

	for _, Warning in Shared.DrainWarnings() do
		assert(
			not string.find(Warning, "could not be decoded", 1, true),
			`the listener's error was reported as: {Warning}`
		)
	end

	assert(Second == 2, `the listener after the one that threw ran {Second} time(s), expected 2`)
	assert(#Raised == 2 and string.find(Raised[1], "a bug in the game", 1, true), "the listener's error was not raised")
end)

--> Connecting replays the queue to the new listener. The network path guards a Sync listener's call,
--> and the replay did not: a listener that threw on a queued event threw out of `.On`, after it had
--> been bound and before the queue was cleared. The caller never got its disconnect, the events after
--> the failing one were never delivered, and the next `.On` was handed the same queue again.
RunClosure("A Sync listener that throws on a queued event still connects, and the queue is spent once", function()
	local Raised: { string } = {}
	Shared.Task.spawn = function(Function, ...)
		if Function == error then
			table.insert(Raised, tostring((...)))
			return nil :: any
		end

		return task.spawn(Function, ...)
	end

	Server.QueuedHoles.FireAll(1, nil, nil, 4, nil)
	Server.QueuedHoles.FireAll(2, nil, nil, 4, nil)
	task.wait(1 / 30)

	local Seen: { number } = {}
	local Connected, Disconnect = pcall(Client.QueuedHoles.On, function(Value: number)
		table.insert(Seen, Value)
		if Value == 1 then
			error("a bug in the game")
		end
	end)
	Shared.Task.spawn = nil :: any

	assert(Connected, `connecting threw: {Disconnect}`)
	Disconnect()

	assert(#Seen == 2, `the queue replayed {#Seen} of 2 events`)
	assert(#Raised == 1 and string.find(Raised[1], "a bug in the game", 1, true), "the listener's error was not raised")

	local Again = 0
	local DisconnectAgain = Client.QueuedHoles.On(function()
		Again += 1
	end)
	DisconnectAgain()

	assert(Again == 0, `a second listener was replayed {Again} event(s) the first had already been given`)
end)

--> A dispatch walks the list of listeners it started with, which is what lets a listener disconnect
--> itself safely. It also meant that a listener disconnected by an EARLIER one in the same dispatch
--> still ran. RBXScriptSignal skips it, and so does every Luau signal written after it.
RunClosure("A listener disconnected by another during dispatch does not run", function()
	local Seen: { string } = {}
	local DisconnectSecond: () -> ()
	local DisconnectFirst = Client.ManyReliableSync.On(function()
		table.insert(Seen, "first")
		DisconnectSecond()
	end)
	DisconnectSecond = Client.ManyReliableSync.On(function()
		table.insert(Seen, "second")
	end)
	local DisconnectThird = Client.ManyReliableSync.On(function()
		table.insert(Seen, "third")
	end)

	Server.ManyReliableSync.FireAll(1)
	task.wait(1 / 30)
	DisconnectFirst()
	DisconnectThird()

	local Order = table.concat(Seen, ", ")
	assert(Order == "first, third", `one fire reached {Order}, expected first, third`)
end)
