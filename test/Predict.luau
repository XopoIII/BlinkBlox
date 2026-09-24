--!strict
--- Specs for Predict, which hands an event to this side's own listeners without going near a remote
--- (upstream issue #59). It has to behave as the network would, queue included, so every case here is
--- one where a predicted event and a received one could have been told apart.
---
--- They live apart from Guards.luau, where the first of them started, but run as part of the suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

RunClosure("Predict delivers to local listeners", function()
	--> Upstream issue #59. Predict hands an event to this side's own listeners without touching a
	--> remote, so receiving code can be driven directly from a test or a story.
	local Received: number?
	local Disconnect = Server.ReliableClient.On(function(_Player, Value)
		Received = Value
	end)

	Server.ReliableClient.Predict(Shared.Player, 42)

	if Received ~= 42 then
		ErrorPrint(`Failed "Predict": listener received {tostring(Received)}, expected 42.`)
	end

	Disconnect()

	--> It mirrors the receive path rather than only calling listeners: with none attached the event
	--> waits in the queue, exactly as a networked one would, and arrives when a listener connects.
	Server.ReliableClient.Predict(Shared.Player, 7)

	local Queued: number?
	local DisconnectQueued = Server.ReliableClient.On(function(_Player, Value)
		Queued = Value
	end)

	if Queued ~= 7 then
		ErrorPrint(`Failed "Predict": a queued event arrived as {tostring(Queued)}, expected 7.`)
	end

	DisconnectQueued()

	--> And it stays local: nothing may reach the wire. A listener takes the event, so it is not left
	--> in the queue for whichever spec connects to this event next.
	local Delivered = 0
	local Watch = Shared.Bridge:Connect(function()
		Delivered += 1
	end)
	local DisconnectWatched = Server.ReliableClient.On(function() end)

	Server.ReliableClient.Predict(Shared.Player, 1)
	task.wait(0.2)
	Watch.Disconnect()
	DisconnectWatched()

	if Delivered ~= 0 then
		ErrorPrint(`Failed "Predict": {Delivered} packet(s) went over the wire.`)
	end
end)

RunClosure("Predict queues a Many event that has no listener yet", function()
	--> A Many event received with no listener bound waits in the queue for the first `.On`. Predict
	--> skipped that and delivered to nobody, so the event a test predicted before connecting its
	--> listener was simply gone -- while the same event from the network would have arrived.
	for _, Case in
		{
			{ Name = "ManyReliableSync", Event = Client.ManyReliableSync },
			{
				Name = "ManyReliableAsync",
				Event = Client.ManyReliableAsync,
			},
		}
	do
		Case.Event.Predict(9)

		local Received: number?
		local Disconnect = Case.Event.On(function(Value)
			Received = Value
		end)

		--> An Async listener is spawned; give it the frame it runs in.
		task.wait()
		Disconnect()

		if Received ~= 9 then
			ErrorPrint(`Failed "Predict queues": {Case.Name} delivered {tostring(Received)}, expected 9.`)
		end
	end
end)

RunClosure("Predict reaches every listener of a Many event", function()
	local Calls = 0
	local First = Client.ManyReliableSync.On(function()
		Calls += 1
	end)
	local Second = Client.ManyReliableSync.On(function()
		Calls += 1
	end)

	Client.ManyReliableSync.Predict(3)
	First()
	Second()

	if Calls ~= 2 then
		ErrorPrint(`Failed "Predict reaches every listener": {Calls} listener call(s), expected 2.`)
	end
end)
