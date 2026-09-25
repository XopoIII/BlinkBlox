--!strict
--- Specs for `SetPacketDropHandler`: every packet the server refuses before decoding it, or cuts short
--- at the event cap, reaches the game's handler with a reason, a count and a detail.
---
--- Those refusals used to be warnings and nothing else: the game could see the output, not the
--- player, so a modified client sending malformed or oversized packets could be read about and never
--- acted on. Each reason is reported at most once a second per player, and `Refused` counts the
--- packets that report stands for.
---
--- The schema is this spec's own, on remotes nothing else shares (Isolated.luau), with limits small
--- enough to reach cheaply: a 256-byte packet, four events, two instances, and so the default budget
--- of eight full packets a second, 2048 bytes.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option MaxPacketSize = 256
option MaxEventsPerPacket = 4
option MaxInstancesPerPacket = 2

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
]]

local PACKET = 256
local BURST = 8 * PACKET

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "DROPS", false)
local Server = Pair.Server

type Report = { Reason: string, Refused: number, Detail: number }

local Received = 0
Server.Byte.On(function()
	Received += 1
end)

--> The remote's own dispatch goes through task.spawn, and so does the handler.
local function Settle()
	task.wait(0.2)
end

--> Forgets every count and report schedule the module keeps for the player, and moves the clock past
--> anything still refilling.
local function Reset()
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	Settle()
	Shared.AdvanceClock(10)
	Shared.DrainWarnings()
	Received = 0
end

--> Installs a handler that records what it is told, and returns the record.
local function Record(): { Report }
	local Reports: { Report } = {}
	Server.SetPacketDropHandler(function(_Player, Reason, Refused, Detail)
		table.insert(Reports, { Reason = Reason, Refused = Refused, Detail = Detail })
	end)
	return Reports
end

--> The reports of one reason, in order.
local function Only(Reports: { Report }, Reason: string): { Report }
	local Found = {}
	for _, Report in Reports do
		if Report.Reason == Reason then
			table.insert(Found, Report)
		end
	end
	return Found
end

--> `Count` Byte events back to back: index 0, then the value.
local function Events(Count: number): buffer
	local Packet = buffer.create(Count * 2)
	for Event = 0, Count - 1 do
		buffer.writeu8(Packet, Event * 2 + 1, Event)
	end
	return Packet
end

local function Warned(Fragment: string): number
	local Count = 0
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, Fragment, 1, true) then
			Count += 1
		end
	end
	return Count
end

--> Sends the same refused packet three times, a second's gap, then once more: one report counting 1
--> at once, and one counting the two held back and the one that made it.
local function Expect(Name: string, Reason: string, Detail: number, Send: () -> ())
	Reset()
	local Reports = Record()

	for _ = 1, 3 do
		Send()
	end
	Settle()
	Shared.AdvanceClock(1)
	Send()
	Settle()
	Server.SetPacketDropHandler(nil)

	local Found = Only(Reports, Reason)
	local First, Second = Found[1], Found[2]
	if #Found ~= 2 or First.Refused ~= 1 or Second.Refused ~= 3 then
		ErrorPrint(
			`Failed "{Name}": {#Found} report(s) counting {First and First.Refused} and {Second and Second.Refused}, expected 2 counting 1 and 3.`
		)
	end

	for _, Report in Found do
		if Report.Detail ~= Detail then
			ErrorPrint(`Failed "{Name}": the detail was {Report.Detail}, expected {Detail}.`)
		end
	end

	if Received ~= 0 then
		ErrorPrint(`Failed "{Name}": {Received} event(s) of a refused packet reached the listener.`)
	end

	if Warned("Dropped") ~= 0 then
		ErrorPrint(`Failed "{Name}": a warning was printed with a packet-drop handler installed.`)
	end
end

RunClosure("A malformed packet reaches the packet-drop handler", function()
	Expect("Malformed", "Malformed", 0, function()
		Pair.Feed(true, "not a buffer" :: any, {})
	end)
end)

RunClosure("An oversized packet reaches the packet-drop handler with its length", function()
	Expect("Oversized", "Oversized", PACKET + 44, function()
		Pair.Feed(true, buffer.create(PACKET + 44), {})
	end)
end)

RunClosure("A packet with too many instances reaches the packet-drop handler with its count", function()
	Expect("Instances", "Instances", 3, function()
		Pair.Feed(true, Events(1), { 1, 2, 3 })
	end)
end)

RunClosure("A packet cut at the event cap reaches the packet-drop handler with the events decoded", function()
	Reset()
	local Reports = Record()

	Pair.Feed(true, Events(6), {})
	Settle()
	Server.SetPacketDropHandler(nil)

	local Found = Only(Reports, "Events")
	if #Found ~= 1 or Found[1].Refused ~= 1 or Found[1].Detail ~= 4 then
		ErrorPrint(`Failed "Events": {#Found} report(s), expected one counting 1 with a detail of 4.`)
	end

	if Received ~= 4 then
		ErrorPrint(`Failed "Events": {Received} of six events were delivered, expected the first 4.`)
	end
end)

RunClosure("Packets over the inbound budget reach the packet-drop handler, not the rate-limit handler", function()
	Reset()
	local Reports = Record()

	local Legacy = 0
	Server.SetRateLimitHandler(function()
		Legacy += 1
	end)

	--> Eight full packets spend the burst; the ninth is reported at once and the tenth held back. A
	--> second refills eight more, and the ninth after them is reported with the one held back.
	local Full = buffer.create(PACKET)
	for _ = 1, BURST // PACKET + 2 do
		Pair.Feed(true, Full, {})
	end
	Settle()
	Shared.AdvanceClock(1)
	for _ = 1, BURST // PACKET + 1 do
		Pair.Feed(true, Full, {})
	end
	Settle()

	Server.SetPacketDropHandler(nil)
	Server.SetRateLimitHandler(nil)

	local Found = Only(Reports, "Budget")
	local First, Second = Found[1], Found[2]
	if #Found ~= 2 or First.Refused ~= 1 or Second.Refused ~= 2 then
		ErrorPrint(
			`Failed "Budget": {#Found} report(s) counting {First and First.Refused} and {Second and Second.Refused}, expected 2 counting 1 and 2.`
		)
	end

	for _, Report in Found do
		if Report.Detail ~= PACKET then
			ErrorPrint(`Failed "Budget": the detail was {Report.Detail}, expected the packet's {PACKET} bytes.`)
		end
	end

	if Legacy ~= 0 or Warned("inbound budget") ~= 0 then
		ErrorPrint(`Failed "Budget": the rate-limit handler or the warning heard a refusal the drop handler took.`)
	end
end)

RunClosure(
	"Without a packet-drop handler, refusals warn as before and Budget reaches the rate-limit handler",
	function()
		Reset()

		local Legacy: { { Event: string?, Refused: number } } = {}
		Server.SetRateLimitHandler(function(_Player, Event, Refused)
			table.insert(Legacy, { Event = Event, Refused = Refused })
		end)

		Pair.Feed(true, "not a buffer" :: any, {})
		Pair.Feed(true, buffer.create(PACKET + 1), {})
		Pair.Feed(true, Events(1), { 1, 2, 3 })
		Pair.Feed(true, Events(6), {})
		Settle()

		local Name = Shared.Player.Name
		local Expected = {
			`Dropped a malformed packet from {Name}.`,
			`Dropped an oversized packet from {Name}.`,
			`Dropped a packet with too many instances from {Name}.`,
			`Dropped the rest of a packet from {Name}, too many events.`,
		}
		local Warnings = table.concat(Shared.DrainWarnings(), "\n")
		for _, Text in Expected do
			if not string.find(Warnings, `[BlinkBlox]: {Text}`, 1, true) then
				ErrorPrint(`Failed "Legacy warnings": "{Text}" was not printed.`)
			end
		end

		local Full = buffer.create(PACKET)
		for _ = 1, BURST // PACKET + 1 do
			Pair.Feed(true, Full, {})
		end
		Settle()
		Server.SetRateLimitHandler(nil)

		if #Legacy ~= 1 or Legacy[1].Event ~= nil or Legacy[1].Refused ~= 1 then
			ErrorPrint(`Failed "Legacy budget": {#Legacy} rate-limit report(s), expected one with no event counting 1.`)
		end

		if Warned("over the inbound budget") ~= 1 then
			ErrorPrint(`Failed "Legacy budget": the budget warning was not printed once.`)
		end
	end
)

RunClosure("A packet-drop handler that throws does not stop the server decoding", function()
	--> Lune prints the two errors this raises, on the handler's own threads. That output is expected.
	Reset()
	local Called = 0
	Server.SetPacketDropHandler(function()
		Called += 1
		error("the game's handler failed")
	end)

	Pair.Feed(true, "not a buffer" :: any, {})
	Pair.Feed(true, Events(6), {})
	Settle()
	Pair.Feed(true, Events(2), {})
	Settle()
	Server.SetPacketDropHandler(nil)

	if Called ~= 2 then
		ErrorPrint(`Failed "Throwing handler": it was called {Called} time(s), expected 2.`)
	end

	if Received ~= 6 then
		ErrorPrint(`Failed "Throwing handler": {Received} events were delivered, expected 4 and then 2.`)
	end
end)

RunClosure("SetPacketDropHandler follows Casing, and is stubbed in edit mode and typed for TypeScript", function()
	for Casing, Name in
		{ Pascal = "SetPacketDropHandler", Camel = "setPacketDropHandler", Snake = "set_packet_drop_handler" }
	do
		local Tree = Isolated.Parse(`option Casing = {Casing}\n{SCHEMA}`)
		for _, Context in { "Server", "Client" } do
			local Source = Generator.Generate(Context :: any, Tree)
			if not string.find(Source, `{Name} = SetPacketDropHandler,`, 1, true) then
				ErrorPrint(`Failed "Casing": the {Casing} {Context} module does not export {Name}.`)
			end

			if not string.find(Source, `{Name} = NOOP,`, 1, true) then
				ErrorPrint(`Failed "Casing": the {Casing} {Context} edit-mode stub has no {Name}.`)
			end

			local Declaration = Generator.GenerateTypescript(Context :: any, Tree)
			if
				not string.find(
					Declaration,
					`export declare const {Name}: (handler?: (player: Player, reason:`,
					1,
					true
				)
			then
				ErrorPrint(`Failed "TypeScript": the {Casing} {Context} declaration does not type {Name}.`)
			end
		end
	end

	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	local Stub = Modules.MockRequire("../Network/Server.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	if type(Stub.SetPacketDropHandler) ~= "function" then
		ErrorPrint(`Failed "Edit mode": SetPacketDropHandler is {type(Stub.SetPacketDropHandler)} in the stub.`)
	else
		Stub.SetPacketDropHandler(function() end)
	end
end)

RunClosure("MaxInstancesPerPacket may be 0, and then every packet carrying one is dropped", function()
	--> Zero says the game's clients send no Instance at all; the server may still send them. A
	--> client-sent Instance beside it is a compile error, E3031 (see Sources/Invalid).
	local Zero = Isolated.Build(
		Isolated.Parse([[
option MaxInstancesPerPacket = 0

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Point { From: Server, Type: Reliable, Call: ManySync, Data: Instance }
]]),
		"ZEROINSTANCES",
		false
	)

	Reset()
	local Delivered = 0
	Zero.Server.Byte.On(function()
		Delivered += 1
	end)

	local Reports: { Report } = {}
	Zero.Server.SetPacketDropHandler(function(_Player, Reason, Refused, Detail)
		table.insert(Reports, { Reason = Reason, Refused = Refused, Detail = Detail })
	end)

	Zero.Feed(true, Events(1), { 1 })
	Zero.Feed(true, Events(1), {})
	Settle()

	local Found = Only(Reports, "Instances")
	if #Found ~= 1 or Found[1].Detail ~= 1 or Delivered ~= 1 then
		ErrorPrint(
			`Failed "Zero instances": {#Found} report(s) and {Delivered} delivery, expected the packet with an instance refused and the other delivered.`
		)
	end
end)
