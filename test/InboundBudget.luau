--!strict
--- Specs for the per-player inbound budget: bytes a second a client's packets may cost the server,
--- charged before a packet is decoded.
---
--- Every other limit is per packet or per event. A client firing hundreds of well-formed packets a
--- frame passed all of them, and the server decoded every one. At the defaults the budget is eight
--- full packets a second and a burst of one second, with a packet never costing less than 128 bytes.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local Assertions = require("./Assertions")

local Client = Modules.Client
local Server = Modules.Server

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--> The defaults as a schema without the options gets them: 8 * MaxPacketSize a second, a burst of
--> the same, and 128 bytes charged for anything smaller.
local RATE = 65536
local FLOOR = 128
local SMALL_PER_BURST = RATE // FLOOR

--> The remote's own dispatch goes through task.spawn, so a replayed packet needs a moment to land.
local function Settle()
	task.wait(0.3)
end

--> Clears the budget through PlayerRemoving, as the rate-limit specs do, and moves the clock far
--> enough that nothing refilled before this point is still owed.
local function Reset()
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	task.wait(0.2)
	Shared.AdvanceClock(10)
	Shared.DrainWarnings()
end

--> Counted, not matched exactly: an earlier spec loads a second copy of the server module onto the
--> same mock remotes, and it keeps a budget of its own. The handler below is this module's alone, so
--> the exact counts are asserted on it.
local function BudgetWarnings(): number
	local Count = 0
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "inbound budget", 1, true) then
			Count += 1
		end
	end
	return Count
end

--> One real client packet, captured on its way out: a single `UnreliableClient` event, a few bytes.
local function CapturePacket(): (buffer, { any })
	local Remote = ClientEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	local Original = Remote.FireServer
	local Buffer: buffer?, Instances: { any }? = nil, nil

	Remote.FireServer = function(_self, Captured, CapturedInstances)
		Buffer, Instances = Captured, CapturedInstances
	end
	Client.UnreliableClient.Fire(1)
	Remote.FireServer = Original

	assert(Buffer and Instances, "the client did not send a packet")
	return Buffer, Instances
end

RunClosure("Honest traffic never reaches the inbound budget", function()
	--> Everything before this spec ran at the defaults, from a clock that barely moved. A budget
	--> warning anywhere in it means the default refuses traffic the suite considers legitimate.
	for _, Warning in Shared.Warnings do
		if string.find(Warning, "inbound budget", 1, true) then
			ErrorPrint(`Failed "Honest traffic": the suite was throttled: {Warning}`)
		end
	end
end)

RunClosure("The inbound budget admits a burst, refuses the rest, and refills", function()
	Reset()

	local Received = 0
	local Disconnect = Server.UnreliableClient.On(function()
		Received += 1
	end)

	local Reports: { { Event: string?, Refused: number } } = {}
	Server.SetRateLimitHandler(function(_Player, Event, Refused)
		table.insert(Reports, { Event = Event, Refused = Refused })
	end)

	local Packet, Instances = CapturePacket()
	local Remote = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE

	--> A small packet costs the floor, so a full burst is RATE / FLOOR of them and no more.
	for _ = 1, SMALL_PER_BURST + 88 do
		Remote.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	end
	Settle()

	local Burst = Received
	local BurstWarnings = BudgetWarnings()
	local BurstReports = #Reports

	--> A second refills a second of budget, and the refusals held back since the report are counted
	--> in the next one.
	Shared.AdvanceClock(1)
	Received = 0
	for _ = 1, SMALL_PER_BURST + 88 do
		Remote.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	end
	Settle()

	Disconnect()
	Server.SetRateLimitHandler(nil)

	if Burst ~= SMALL_PER_BURST then
		ErrorPrint(`Failed "Inbound burst": {Burst} small packets were decoded, expected {SMALL_PER_BURST}.`)
	end

	if BurstWarnings == 0 or BurstReports ~= 1 or Reports[1].Event ~= nil or Reports[1].Refused ~= 1 then
		ErrorPrint(
			`Failed "Inbound burst": {BurstWarnings} warning(s) and {BurstReports} report(s) for 88 refusals, `
				.. `expected a warning and one report, naming no event and counting 1.`
		)
	end

	if Received ~= SMALL_PER_BURST then
		ErrorPrint(
			`Failed "Inbound refill": {Received} packets were decoded after a second, expected {SMALL_PER_BURST}.`
		)
	end

	--> 87 held back from the first second, 1 that made the second report.
	local Second = Reports[2]
	if #Reports ~= 2 or not Second or Second.Refused ~= 88 then
		ErrorPrint(
			`Failed "Inbound refill": {#Reports} report(s), the last counting {Second and Second.Refused}, expected 2 and 88.`
		)
	end
end)

RunClosure("The inbound budget is one per player, shared by both remotes", function()
	Reset()

	local Packet, Instances = CapturePacket()
	for _ = 1, SMALL_PER_BURST do
		ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	end
	Settle()

	--> The unreliable remote spent the whole burst, so the reliable one has nothing left either.
	local Received = 0
	local Disconnect = Server.ReliableClient.On(function()
		Received += 1
	end)

	local Reliable = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
	local Spy = Reliable.OnServerEvent:Connect(function() end)
	Client.ReliableClient.Fire(1)
	task.wait(1 / 30)
	Settle()

	Spy.Disconnect()
	Disconnect()

	if Received ~= 0 then
		ErrorPrint(`Failed "Shared budget": a reliable packet was decoded after the unreliable remote spent the burst.`)
	end

	if BudgetWarnings() == 0 then
		ErrorPrint(`Failed "Shared budget": the refused reliable packet was not reported.`)
	end
end)

RunClosure("The inbound budget charges a packet by its size", function()
	Reset()

	--> The index of ReliableClient, from a packet the client really sends.
	local ClientRemote = ClientEnvironment.Instances.BLINK_RELIABLE_REMOTE
	local Original = ClientRemote.FireServer
	local Captured: buffer?
	ClientRemote.FireServer = function(_self, Buffer: buffer)
		Captured = Buffer
	end
	Client.ReliableClient.Fire(1)
	task.wait(1 / 30)
	ClientRemote.FireServer = Original
	assert(Captured, "no ReliableClient packet was sent to take the index from")

	--> Counted by the event each one opens with, since the junk after it is reported at most once a
	--> second and so cannot be counted by its reports.
	local Decoded = 0
	local Disconnect = Server.ReliableClient.On(function()
		Decoded += 1
	end)

	--> Packets of the largest size a packet may have: eight of them spend the burst exactly. Each one
	--> that is decoded delivers its event and then fails on the junk; the ninth is refused before
	--> anyone reads it.
	local Junk = buffer.fromstring(string.rep("\255", 8192))
	buffer.writeu8(Junk, 0, buffer.readu8(Captured, 0))
	buffer.writeu8(Junk, 1, 1)
	for _ = 1, 9 do
		ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE.OnServerEvent:Fire(Shared.Player, Junk, {})
	end
	Settle()
	Disconnect()

	if Decoded ~= 8 then
		ErrorPrint(`Failed "Charged by size": {Decoded} of nine full-size packets were decoded, expected 8.`)
	end

	if BudgetWarnings() == 0 then
		ErrorPrint(`Failed "Charged by size": the ninth packet was not refused over the budget.`)
	end
end)

RunClosure("A packet-drop handler takes the inbound budget's reports from the rate-limit handler", function()
	--> Since 0.37.0 a game that installs a packet-drop handler hears about Budget there, with the
	--> packet's length, and the rate-limit handler and the warning no longer do. Without one, the
	--> spec above still holds: a warning and the rate-limit handler with `Event` nil.
	Reset()

	local Drops: { { Reason: string, Refused: number, Detail: number } } = {}
	Server.SetPacketDropHandler(function(_Player, Reason, Refused, Detail)
		table.insert(Drops, { Reason = Reason, Refused = Refused, Detail = Detail })
	end)

	local Legacy = 0
	Server.SetRateLimitHandler(function()
		Legacy += 1
	end)

	local Packet, Instances = CapturePacket()
	local Remote = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	for _ = 1, SMALL_PER_BURST + 5 do
		Remote.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	end
	Settle()

	Server.SetPacketDropHandler(nil)
	Server.SetRateLimitHandler(nil)

	local First = Drops[1]
	if #Drops ~= 1 or First.Reason ~= "Budget" or First.Refused ~= 1 or First.Detail ~= buffer.len(Packet) then
		ErrorPrint(
			`Failed "Budget to the drop handler": {#Drops} report(s), expected one Budget report counting 1 with the packet's {buffer.len(
				Packet
			)} bytes.`
		)
	end

	--> The warning may still come from the second copy of the server module an earlier spec loaded
	--> onto these remotes, which has no handler; this module's rate-limit handler must stay silent.
	if Legacy ~= 0 then
		ErrorPrint(`Failed "Budget to the drop handler": the rate-limit handler was called {Legacy} time(s).`)
	end
end)

RunClosure("A player who leaves takes their inbound budget with them", function()
	Reset()

	local Packet, Instances = CapturePacket()
	local Remote = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	for _ = 1, SMALL_PER_BURST do
		Remote.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	end
	Settle()

	--> No clock moves: only PlayerRemoving can have refilled it.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	task.wait(0.2)
	Shared.DrainWarnings()

	local Received = 0
	local Disconnect = Server.UnreliableClient.On(function()
		Received += 1
	end)
	Remote.OnServerEvent:Fire(Shared.Player, Packet, Instances)
	Settle()
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Budget on leave": a returning player's packet was refused on an old budget.`)
	end

	--> Leave the budget full for whatever runs next.
	Reset()
end)
