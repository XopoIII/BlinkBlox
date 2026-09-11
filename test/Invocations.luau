--!strict
--- Specs for an invocation that is never answered.
---
--- There was no timeout at all until now, and the failure it left behind was quiet: the caller hung
--- forever and its slot in the invocation bitset stayed claimed, so after thirty-two of them `Invoke`
--- refused every further call for the lifetime of the session. Nothing reported either half.
---
--- This was survivable while the callee was always the SERVER, because the server always answers --
--- every refusal path writes a three-byte failure reply for exactly that reason. It stops being
--- survivable the moment a client can be the callee, since a client that never replies is ordinary:
--- it left, it crashed, it was exploited.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

--> Test.blink sets `option InvocationTimeout = 3`, and nothing anywhere listens to NeverAnswered.
local TIMEOUT = 3

do
	local Name = "An invocation nobody answers fails its caller instead of hanging"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	Shared.DrainWarnings()

	local Finished = false
	local Succeeded: boolean?

	task.spawn(function()
		Succeeded = pcall(function()
			return Client.NeverAnswered.Invoke(1)
		end)
		Finished = true
	end)

	--> Comfortably past the timeout, and still bounded: a spec that waited forever for a fix to
	--> hanging would be its own joke.
	local Waited = 0
	while not Finished and Waited < TIMEOUT + 2 do
		Waited += task.wait(0.1)
	end

	if not Finished then
		ErrorPrint(`Failed "{Name}": the caller was still suspended {Waited} seconds later.`)
		return {}
	end

	if Succeeded ~= false then
		ErrorPrint(`Failed "{Name}": the call returned instead of failing, with nobody having answered it.`)
		return {}
	end

	local Warned = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "never answered", 1, true) then
			Warned = true
			break
		end
	end

	if not Warned then
		ErrorPrint(`Failed "{Name}": it failed the caller without saying why.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> The other half, and the one that actually bites: the slot has to come back. Without this the
	--> bitset leaks a bit per lost call and the thirty-third refuses outright.
	local Name = "A timed-out invocation returns its slot"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	--> More calls than the bitset holds (32), spaced so that earlier ones time out while later ones
	--> are still being made. At one call per 0.15s against a 3s timeout, twenty are outstanding at any
	--> moment -- comfortably inside the bitset IF slots come back, and past it at the thirty-third call
	--> if they do not.
	-->
	--> Exhaustion surfaces as an ERROR out of Invoke, not a warning, so that is what this collects.
	local Exhausted: string?
	for _ = 1, 40 do
		task.spawn(function()
			local _, Thrown = pcall(function()
				return Client.NeverAnswered.Invoke(1)
			end)

			if Thrown and string.find(tostring(Thrown), "already awaiting", 1, true) then
				Exhausted = tostring(Thrown)
			end
		end)

		task.wait(0.15)
	end

	if Exhausted then
		ErrorPrint(`Failed "{Name}": the invocation slots ran out, so they are not being returned: {Exhausted}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

return {}
