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
