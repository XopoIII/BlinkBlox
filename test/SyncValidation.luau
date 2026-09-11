--!strict
--- Specs for what SyncValidation actually does, as opposed to what its warning used to say.
---
--- Ziffix on the devforum thread: "SingleSync is described as allowing only synchronous callbacks,
--- but after adding multiple callbacks that yield the thread, no error is thrown." That is a correct
--- observation. The check does not fire when a listener yields; it fires when the NEXT packet
--- arrives and finds the previous decode still suspended inside one. A yield with no traffic behind
--- it is never reported at all.
---
--- The part nobody was told about is what happens when it does fire. `coroutine.close` ends the
--- suspended decode, so every event still unread in that earlier packet is discarded. The spec below
--- is that loss, demonstrated: three events are sent, two arrive, and the missing one is the one
--- that was sitting behind the yield.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

do
	local Name = "A yield in a Sync listener discards the rest of its packet, and says so"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Received: { number } = {}
	local Yielded = false

	local Disconnect = Client.ReliableServer.On(function(Value: number)
		table.insert(Received, Value)

		--> Only the first one yields. A Sync listener runs ON the decode thread, so this suspends the
		--> decode of everything after it in the same packet.
		if not Yielded then
			Yielded = true
			task.wait(0.2)
		end
	end)

	--> Flush whatever the event queued while nothing was listening.
	task.wait(1 / 30)
	table.clear(Received)
	Shared.DrainWarnings()

	--> Two events, one frame, therefore one packet. The first yields; the second is left unread
	--> behind it.
	Server.ReliableServer.FireAll(1)
	Server.ReliableServer.FireAll(2)
	task.wait(1 / 30)

	--> A second packet. Its arrival is what runs the check, finds the decode above still suspended,
	--> warns, and closes it -- taking the unread 2 with it.
	Server.ReliableServer.FireAll(3)
	task.wait(1 / 30)

	--> Long enough that the yield above would have finished if it had been allowed to.
	task.wait(0.4)
	Disconnect()

	local Warned = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "discarded", 1, true) then
			Warned = true
			break
		end
	end

	if not Warned then
		ErrorPrint(`Failed "{Name}": nothing warned that the packet had been discarded.`)
		return {}
	end

	if table.find(Received, 2) then
		ErrorPrint(`Failed "{Name}": the event behind the yield survived, so this proves nothing.`)
		return {}
	end

	if not table.find(Received, 1) or not table.find(Received, 3) then
		ErrorPrint(`Failed "{Name}": expected 1 and 3 to arrive, got {#Received} event(s).`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

return {}
