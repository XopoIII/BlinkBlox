--!strict
--- Specs for who reports a rate refusal: the warning when no rate-limit handler is installed, the
--- handler alone when one is.
---
--- The packet-drop path already went quiet once a handler was installed, while a rate refusal printed
--- its warning whatever the game had installed: a game that reported refusals itself saw each one
--- twice, once in its own report and once in the output.
---
--- The schema is this spec's own, on remotes nothing else shares (Isolated.luau), so every warning
--- drained here is this module's and the counts are exact.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Limited { From: Client, Type: Reliable, Call: ManySync, Rate: 1, Burst: 1, Data: u8 }
]]

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "RATE_WARNINGS", false)
local Server = Pair.Server

local Received = 0
Server.Limited.On(function()
	Received += 1
end)

--> The remote's own dispatch goes through task.spawn, and so does the handler.
local function Settle()
	task.wait(0.2)
end

--> Forgets the player's buckets and report schedule, and moves the clock past any refill.
local function Reset()
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	Settle()
	Shared.AdvanceClock(10)
	Shared.DrainWarnings()
	Received = 0
end

--> Three `Limited` events in three packets: the burst of one takes the first, the second is refused
--> and reported at once, and the third is refused and held for the next report.
local function Flood()
	for _ = 1, 3 do
		local Packet = buffer.create(2)
		buffer.writeu8(Packet, 1, 7)
		Pair.Feed(true, Packet, {})
	end
	Settle()
end

local function RateWarnings(): number
	local Count = 0
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "Rate limited event", 1, true) then
			Count += 1
		end
	end
	return Count
end

RunClosure("Without a rate-limit handler, a rate refusal is warned about", function()
	Reset()
	Flood()

	local Expected = `[BlinkBlox]: Rate limited event "Limited" from {Shared.Player.Name}, 1 refused.`
	local Warnings = Shared.DrainWarnings()
	local Found = 0
	for _, Warning in Warnings do
		if Warning == Expected then
			Found += 1
		end
	end

	if Received ~= 1 then
		ErrorPrint(`Failed "Rate warning": {Received} of three events were delivered, expected 1.`)
	end

	if Found ~= 1 or #Warnings ~= 1 then
		ErrorPrint(`Failed "Rate warning": {#Warnings} warning(s), expected exactly "{Expected}".`)
	end
end)

RunClosure("A rate-limit handler owns the report of a rate refusal, and nothing is warned", function()
	Reset()
	local Reports: { { Event: string?, Refused: number } } = {}
	Server.SetRateLimitHandler(function(_Player, Event, Refused)
		table.insert(Reports, { Event = Event, Refused = Refused })
	end)

	Flood()
	Server.SetRateLimitHandler(nil)

	local Warned = RateWarnings()
	local First = Reports[1]
	if #Reports ~= 1 or First.Event ~= "Limited" or First.Refused ~= 1 then
		ErrorPrint(`Failed "Rate handler": {#Reports} report(s), expected one for "Limited" counting 1.`)
	end

	if Warned ~= 0 then
		ErrorPrint(`Failed "Rate handler": the handler took the report and {Warned} warning(s) were printed.`)
	end
end)
