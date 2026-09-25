--!strict
--- Specs for `SetListenerErrorHandler`: a server listener that throws -- an event's, Sync or Async,
--- live or replayed from the queue, or a function's -- reaches the game's handler with the player, the
--- event, the error and a count.
---
--- The error used to surface with nobody named, so a game that wanted to know which player's packet
--- set off which listener wrapped every listener in a pcall of its own. A modified client can make a
--- listener throw on every packet, so the reports keep the once-a-second schedule of the others:
--- the first error is reported at once, and the ones after it in the same second are counted into the
--- next report.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event SyncMany { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event SyncSingle { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
event AsyncMany { From: Client, Type: Reliable, Call: ManyAsync, Data: u8 }
event AsyncSingle { From: Client, Type: Unreliable, Call: SingleAsync, Data: u8 }
event Late { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
event LateAsync { From: Client, Type: Reliable, Call: ManyAsync, Data: u8 }
function Ask { Yield: Coroutine, Data: u8, Return: u8 }
function BadReturn { Yield: Coroutine, Data: u8, Return: u8 }
]]

--> Event indices, in declaration order on each channel. Checked against the module below.
local RELIABLE = { SyncMany = 0, SyncSingle = 1, AsyncMany = 2, Late = 3, LateAsync = 4, Ask = 5, BadReturn = 6 }
local UNRELIABLE = { AsyncSingle = 0 }

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "LISTENERERRORS", false)
local Server = Pair.Server
local Source = require("@lune/fs").readFile("../Network/IsolatedLISTENERERRORSServer.luau")
for Name, Index in RELIABLE do
	assert(string.find(Source, `EventNames.Reliable[{Index}] = "{Name}"`, 1, true), `{Name} is not reliable {Index}`)
end
assert(string.find(Source, `EventNames.Unreliable[0] = "AsyncSingle"`, 1, true), "AsyncSingle is not unreliable 0")

type Report = { Player: any, Event: string, Failure: string, Count: number }

--> What ran and what surfaced. `Ran` counts the calls of each listener that did not throw.
local Ran: { [string]: number } = {}
local Raised: { string } = {}

--> Every listener throws on a value of 100 or more and counts the calls it survives.
local function Throwing(Name: string): (any, number) -> ()
	return function(_Player, Value)
		if Value >= 100 then
			error(`{Name} refused {Value}`, 0)
		end

		Ran[Name] = (Ran[Name] or 0) + 1
	end
end

for _, Name in { "SyncMany", "SyncSingle", "AsyncMany", "AsyncSingle" } do
	Server[Name].On(Throwing(Name))
end

Server.Ask.On(function(_Player, Value)
	if Value >= 100 then
		error(`Ask refused {Value}`, 0)
	end

	return Value + 1
end)

--> Returns a string where a u8 is promised: the reply's serialiser throws, not the listener.
Server.BadReturn.On(function(_Player, _Value)
	return "not a number" :: any
end)

--> The module's `task.spawn`: an error raised through `task.spawn(error, ...)` and an error thrown by
--> a pooled thread are both recorded rather than ending the run, which Lune does on any thread error.
Shared.Task.spawn = function(Function: any, ...): any
	if Function == error then
		table.insert(Raised, tostring((...)))
		return nil
	end

	if type(Function) == "thread" then
		local Resumed, Failure = coroutine.resume(Function, ...)
		if not Resumed then
			table.insert(Raised, tostring(Failure))
		end

		return Function
	end

	return task.spawn(Function, ...)
end

local function Settle()
	task.wait(0.2)
end

--> Forgets every count and schedule the module keeps for the player and clears what was seen.
local function Reset()
	Shared.SetPlayerInGame(true)
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	Settle()
	Shared.AdvanceClock(10)
	Shared.DrainWarnings()
	table.clear(Ran)
	table.clear(Raised)
	table.clear(Pair.Replies)
end

local function Record(): { Report }
	local Reports: { Report } = {}
	Server.SetListenerErrorHandler(function(Player, Event, Failure, Count)
		table.insert(Reports, { Player = Player, Event = Event, Failure = Failure, Count = Count })
	end)
	return Reports
end

--> One packet of events, each `{ Index, Value }`, or of calls, each `{ Index, Id, Value }`.
local function Packet(Rows: { { number } }): buffer
	local Bytes = {}
	for _, Row in Rows do
		for _, Byte in Row do
			table.insert(Bytes, Byte)
		end
	end

	local Buffer = buffer.create(#Bytes)
	for Offset, Byte in Bytes do
		buffer.writeu8(Buffer, Offset - 1, Byte)
	end
	return Buffer
end

local function Send(Name: string, ...: number)
	local Rows = {}
	for _, Value in { ... } do
		table.insert(Rows, { RELIABLE[Name], Value })
	end
	Pair.Feed(true, Packet(Rows), {})
end

local function Expect(Label: string, Reports: { Report }, Expected: { { any } })
	local Seen = {}
	for _, Report in Reports do
		table.insert(Seen, `{Report.Event} "{Report.Failure}" x{Report.Count}`)
	end

	local Wanted = {}
	for _, Row in Expected do
		table.insert(Wanted, `{Row[1]} "{Row[2]}" x{Row[3]}`)
	end

	local Match = #Seen == #Wanted
	for Position, Line in Wanted do
		Match = Match and Seen[Position] == Line
	end

	for _, Report in Reports do
		Match = Match and Report.Player == Shared.Player
	end

	if not Match then
		ErrorPrint(
			`Failed "{Label}": reported [{table.concat(Seen, ", ")}], expected [{table.concat(Wanted, ", ")}] for the player.`
		)
	end
end

local function Quiet(Label: string)
	local Warnings = Shared.DrainWarnings()
	if #Raised ~= 0 or #Warnings ~= 0 then
		ErrorPrint(
			`Failed "{Label}": with a handler installed, {#Raised} error(s) and {#Warnings} warning(s) surfaced: {table.concat(
				Raised,
				"; "
			)} {table.concat(Warnings, "; ")}`
		)
	end
end

RunClosure("A Sync listener that throws reports the player, the event, the error and a count", function()
	Reset()
	local Reports = Record()

	--> One packet: a throw, then an event that goes through, on each Sync call mode.
	Send("SyncMany", 100, 1)
	Send("SyncSingle", 150, 2)
	Settle()

	Expect(
		"Sync",
		Reports,
		{ { "SyncMany", "SyncMany refused 100", 1 }, { "SyncSingle", "SyncSingle refused 150", 1 } }
	)
	if Ran.SyncMany ~= 1 or Ran.SyncSingle ~= 1 then
		ErrorPrint(
			`Failed "Sync": the event after the throw ran {Ran.SyncMany} and {Ran.SyncSingle} time(s), expected 1.`
		)
	end
	Quiet("Sync")

	--> Listeners that do not throw report nothing.
	Send("SyncMany", 3, 4)
	Send("SyncSingle", 5)
	Settle()
	Server.SetListenerErrorHandler(nil)

	if #Reports ~= 2 or Ran.SyncMany ~= 3 or Ran.SyncSingle ~= 2 then
		ErrorPrint(
			`Failed "Sync, no throw": {#Reports} report(s) and runs {Ran.SyncMany}/{Ran.SyncSingle}, expected 2 and 3/2.`
		)
	end
end)

RunClosure("Errors inside one second are counted into the next report, per event", function()
	Reset()
	local Reports = Record()

	--> Two throws within the second: one report, at once, counting the first.
	Send("SyncMany", 101)
	Send("SyncMany", 102)
	Send("SyncSingle", 103)
	Settle()
	Expect(
		"Window",
		Reports,
		{ { "SyncMany", "SyncMany refused 101", 1 }, { "SyncSingle", "SyncSingle refused 103", 1 } }
	)

	--> Still inside it: counted, not reported.
	Shared.AdvanceClock(0.5)
	Send("SyncMany", 104)
	Settle()

	--> Past it: the next throw is reported, standing for itself and the two held back.
	Shared.AdvanceClock(0.6)
	Send("SyncMany", 105)
	Send("SyncSingle", 106)
	Settle()
	Server.SetListenerErrorHandler(nil)

	Expect("Window", Reports, {
		{ "SyncMany", "SyncMany refused 101", 1 },
		{ "SyncSingle", "SyncSingle refused 103", 1 },
		{ "SyncMany", "SyncMany refused 105", 3 },
		{ "SyncSingle", "SyncSingle refused 106", 1 },
	})
	Quiet("Window")
end)

RunClosure("An Async listener that throws is reported, Many and Single, reliable and unreliable", function()
	Reset()
	local Reports = Record()

	Send("AsyncMany", 120, 7)
	Pair.Feed(false, Packet({ { UNRELIABLE.AsyncSingle, 130 } }), {})
	Pair.Feed(false, Packet({ { UNRELIABLE.AsyncSingle, 8 } }), {})
	Settle()
	Server.SetListenerErrorHandler(nil)

	Expect("Async", Reports, {
		{ "AsyncMany", "AsyncMany refused 120", 1 },
		{ "AsyncSingle", "AsyncSingle refused 130", 1 },
	})
	if Ran.AsyncMany ~= 1 or Ran.AsyncSingle ~= 1 then
		ErrorPrint(
			`Failed "Async": the listeners that did not throw ran {Ran.AsyncMany}/{Ran.AsyncSingle} time(s), expected 1/1.`
		)
	end
	Quiet("Async")
end)

RunClosure("A queued event replayed to a listener that throws is reported, and the queue carries on", function()
	Reset()
	local Reports = Record()

	--> Nothing listens yet, so both rows of each are queued and replayed when `.On` binds.
	Send("Late", 140, 9)
	Send("LateAsync", 141, 10)
	Settle()
	local DisconnectLate = Server.Late.On(Throwing("Late"))
	local DisconnectAsync = Server.LateAsync.On(Throwing("LateAsync"))
	Settle()
	DisconnectLate()
	DisconnectAsync()
	Server.SetListenerErrorHandler(nil)

	Expect("Replay", Reports, { { "Late", "Late refused 140", 1 }, { "LateAsync", "LateAsync refused 141", 1 } })
	if Ran.Late ~= 1 or Ran.LateAsync ~= 1 then
		ErrorPrint(`Failed "Replay": the row after the throw ran {Ran.Late}/{Ran.LateAsync} time(s), expected 1/1.`)
	end
	Quiet("Replay")
end)

--> The reply the server wrote to the player for `Index` and `Id`, as bytes.
local function Reply(Index: number, Id: number): { number }?
	Server.StepReplication()
	for _, Sent in Pair.Replies do
		local Length = buffer.len(Sent.Buffer)
		local Offset = 0
		while Offset + 3 <= Length do
			local Bytes = { buffer.readu8(Sent.Buffer, Offset), buffer.readu8(Sent.Buffer, Offset + 1) }
			local Flag = buffer.readu8(Sent.Buffer, Offset + 2)
			table.insert(Bytes, Flag)
			if Flag == 1 then
				table.insert(Bytes, buffer.readu8(Sent.Buffer, Offset + 3))
			end

			if Bytes[1] == Index and Bytes[2] == Id then
				return Bytes
			end

			Offset += #Bytes
		end
	end

	return nil
end

RunClosure("A function listener that throws is answered with a failure and reported", function()
	Reset()
	local Reports = Record()

	Pair.Feed(true, Packet({ { RELIABLE.Ask, 7, 100 }, { RELIABLE.Ask, 8, 4 }, { RELIABLE.BadReturn, 9, 1 } }), {})
	Settle()
	Server.SetListenerErrorHandler(nil)

	local Failed, Answered, Unserialised = Reply(RELIABLE.Ask, 7), Reply(RELIABLE.Ask, 8), Reply(RELIABLE.BadReturn, 9)
	local Shown =
		`{Failed and table.concat(Failed, ",")} / {Answered and table.concat(Answered, ",")} / {Unserialised and table.concat(
			Unserialised,
			","
		)}`
	if
		not Failed
		or #Failed ~= 3
		or Failed[3] ~= 0
		or not Answered
		or #Answered ~= 4
		or Answered[4] ~= 5
		or not Unserialised
		or #Unserialised ~= 3
		or Unserialised[3] ~= 0
	then
		ErrorPrint(`Failed "Function": the replies were {Shown}, expected a failure, an answer of 5, a failure.`)
	end

	if #Reports ~= 2 or Reports[1].Event ~= "Ask" or Reports[1].Failure ~= "Ask refused 100" then
		ErrorPrint(`Failed "Function": {#Reports} report(s), expected Ask's error first.`)
	end

	local Serialiser = Reports[2]
	if
		not Serialiser
		or Serialiser.Event ~= "BadReturn"
		or Serialiser.Count ~= 1
		or Serialiser.Player ~= Shared.Player
	then
		ErrorPrint(`Failed "Function": the return serialiser's failure was not reported under BadReturn.`)
	end
	Quiet("Function")
end)

require("./ListenerErrorsFallback")(Pair, {
	Reset = Reset,
	Record = Record,
	Send = Send,
	Settle = Settle,
	Reply = Reply,
	Raised = Raised,
	Ran = Ran,
	Ask = RELIABLE.Ask,
})

return {}
