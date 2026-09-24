--!strict
--- Specs for `Concurrency`: how many of one player's calls to a function the server runs at once.
---
--- `Rate` bounds how many calls start a second. A listener that waits -- a DataStore request, an
--- invocation back to the client -- holds each of them open for as long as the wait, so a steady
--- stream of calls becomes a pile of suspended threads that no rate stops. `ConcurrentCall` in
--- Test.blink allows two: a third that arrives while two are running is answered with a failure at
--- once, and a call that is answered, successfully or not, makes room for the next.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server
local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--- Starts `Count` calls at once and returns a table the outcomes fill in as they settle.
local function Invoke(Count: number): { Succeeded: number, Refused: number }
	local Outcome = { Succeeded = 0, Refused = 0 }
	for _ = 1, Count do
		task.spawn(function()
			local Ok = pcall(Client.ConcurrentCall.Invoke, 1)
			if Ok then
				Outcome.Succeeded += 1
			else
				Outcome.Refused += 1
			end
		end)
	end

	return Outcome
end

RunClosure("A function runs at most its Concurrency of one player's calls at once", function()
	Shared.AdvanceClock(10)
	Shared.DrainWarnings()

	local Reports: { { Event: string?, Refused: number } } = {}
	Server.SetRateLimitHandler(function(_Player, Event, Refused)
		table.insert(Reports, { Event = Event, Refused = Refused })
	end)

	--> Every listener waits until the gate opens, so the calls it accepts stay running.
	local Open = false
	Server.ConcurrentCall.On(function(_Player, Value)
		while not Open do
			task.wait()
		end

		return Value
	end)

	local First = Invoke(4)
	task.wait(0.3)

	if First.Refused ~= 2 or First.Succeeded ~= 0 then
		ErrorPrint(
			`Failed "Concurrency": with two running, {First.Refused} of four calls were refused and {First.Succeeded} answered; expected 2 refused and none answered yet.`
		)
	end

	Open = true
	task.wait(0.3)

	if First.Succeeded ~= 2 then
		ErrorPrint(
			`Failed "Concurrency": {First.Succeeded} of the two running calls were answered once the gate opened.`
		)
	end

	--> Both answered, so both places are free again.
	local Second = Invoke(2)
	task.wait(0.3)

	if Second.Succeeded ~= 2 or Second.Refused ~= 0 then
		ErrorPrint(
			`Failed "Concurrency": after two answers, {Second.Succeeded} of two new calls succeeded and {Second.Refused} were refused.`
		)
	end

	Server.SetRateLimitHandler(nil)
	local Warned = Shared.DrainWarnings()
	local Reported = Reports[1]
	if #Reports ~= 1 or not Reported or Reported.Event ~= "ConcurrentCall" or Reported.Refused ~= 1 then
		ErrorPrint(`Failed "Concurrency": expected one report for ConcurrentCall, got {#Reports}.`)
	elseif #Warned ~= 1 or not string.find(Warned[1], "already has 2 calls running", 1, true) then
		ErrorPrint(`Failed "Concurrency": expected one warning about the running calls, got {#Warned}.`)
	end
end)

RunClosure("A call that fails still makes room for the next", function()
	--> The failure reply is the answer, and the one place a count could leak is a path that answers
	--> without giving the call back. Two failures, then two calls, must all get through.
	Shared.AdvanceClock(10)
	local Fail = true
	Server.ConcurrentCall.On(function(_Player, Value)
		if Fail then
			error("refused by the game", 0)
		end

		return Value
	end)

	local Failed = Invoke(2)
	task.wait(0.3)
	Fail = false
	local After = Invoke(2)
	task.wait(0.3)
	Shared.DrainWarnings()

	if Failed.Refused ~= 2 or After.Succeeded ~= 2 then
		ErrorPrint(
			`Failed "Concurrency release": {Failed.Refused} of two failing calls failed, then {After.Succeeded} of two calls succeeded; expected 2 and 2.`
		)
	end
end)
