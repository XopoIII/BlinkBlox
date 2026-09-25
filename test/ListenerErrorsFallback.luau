--!strict
--- The rest of the `SetListenerErrorHandler` specs, on ListenerErrors.luau's pair: what happens with
--- no handler installed -- exactly what happened before it existed -- a handler that throws, a player
--- who has already left, and the member's spelling, stub and TypeScript type.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

type Report = { Player: any, Event: string, Failure: string, Count: number }

export type Kit = {
	Reset: () -> (),
	Record: () -> { Report },
	Send: (Name: string, ...number) -> (),
	Settle: () -> (),
	Reply: (Index: number, Id: number) -> { number }?,
	Raised: { string },
	Ran: { [string]: number },
	Ask: number,
}

return function(Pair: Isolated.Pair, Kit: Kit)
	local Server = Pair.Server

	RunClosure("Without a listener-error handler, listener errors surface as they did before it", function()
		Kit.Reset()

		Kit.Send("SyncMany", 100, 1)
		Kit.Send("AsyncMany", 120)
		Pair.Feed(true, buffer.fromstring(string.char(Kit.Ask, 3, 110)), {})
		Kit.Settle()

		--> The Sync error through `task.spawn(error, ...)`, the Async one thrown by its own thread, in
		--> the order they ran; the function's as its warning, word for word.
		local Raised = table.concat(Kit.Raised, " | ")
		if
			#Kit.Raised ~= 2
			or Kit.Raised[1] ~= "SyncMany refused 100"
			or not string.find(Kit.Raised[2], "AsyncMany refused 120", 1, true)
		then
			ErrorPrint(`Failed "No handler": raised [{Raised}], expected SyncMany's error and then AsyncMany's.`)
		end

		local Warnings = Shared.DrainWarnings()
		if #Warnings ~= 1 or Warnings[1] ~= `"Ask" encountered an error, Ask refused 110` then
			ErrorPrint(`Failed "No handler": warned [{table.concat(Warnings, " | ")}], expected Ask's warning alone.`)
		end

		local Failed = Kit.Reply(Kit.Ask, 3)
		if not Failed or #Failed ~= 3 or Failed[3] ~= 0 then
			ErrorPrint(`Failed "No handler": the call that threw was not answered with a failure.`)
		end

		if Kit.Ran.SyncMany ~= 1 then
			ErrorPrint(`Failed "No handler": the event after the throw ran {Kit.Ran.SyncMany} time(s), expected 1.`)
		end
	end)

	RunClosure("Removing the listener-error handler brings the old behaviour back", function()
		Kit.Reset()
		local Reports = Kit.Record()
		Server.SetListenerErrorHandler(nil)

		Kit.Send("SyncSingle", 100)
		Kit.Settle()

		if #Reports ~= 0 or #Kit.Raised ~= 1 or Kit.Raised[1] ~= "SyncSingle refused 100" then
			ErrorPrint(`Failed "Removed": {#Reports} report(s) and {#Kit.Raised} raised error(s), expected 0 and 1.`)
		end
	end)

	RunClosure("A listener-error handler that throws does not stop the server decoding", function()
		Kit.Reset()
		local Called = 0
		Server.SetListenerErrorHandler(function()
			Called += 1
			error("the game's handler failed", 0)
		end)

		Kit.Send("SyncMany", 100, 1, 2)
		Kit.Settle()
		Server.SetListenerErrorHandler(nil)

		--> The handler's own error surfaces on its own thread, which is all it may do.
		if Called ~= 1 or Kit.Ran.SyncMany ~= 2 then
			ErrorPrint(
				`Failed "Throwing handler": called {Called} time(s), {Kit.Ran.SyncMany} event(s) after it ran; expected 1 and 2.`
			)
		end

		--> Lune's coroutine.resume prefixes the message and appends a traceback, hence the search.
		if #Kit.Raised ~= 1 or not string.find(Kit.Raised[1], "the game's handler failed", 1, true) then
			ErrorPrint(
				`Failed "Throwing handler": raised [{table.concat(Kit.Raised, " | ")}], expected the handler's error alone.`
			)
		end
	end)

	RunClosure("A listener that throws after its player left is reported at once, each time", function()
		Kit.Reset()
		local Reports = Kit.Record()

		--> Both listeners wait past the player's departure, then throw.
		local Disconnect = Server.LateAsync.On(function(_Player, Value)
			task.wait(0.1)
			error(`left with {Value}`, 0)
		end)

		Kit.Send("LateAsync", 1, 2)
		Shared.SetPlayerInGame(false)
		Kit.Settle()
		Disconnect()
		Server.SetListenerErrorHandler(nil)
		Shared.SetPlayerInGame(true)

		if #Reports ~= 2 or Reports[1].Count ~= 1 or Reports[2].Count ~= 1 or Reports[2].Failure ~= "left with 2" then
			ErrorPrint(
				`Failed "Departed": {#Reports} report(s), expected two counting 1 each, the second "left with 2".`
			)
		end
	end)

	RunClosure(
		"SetListenerErrorHandler follows Casing, is stubbed in edit mode, and is a no-op on the client",
		function()
			local Schema = "event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }"
			for Casing, Name in
				{
					Pascal = "SetListenerErrorHandler",
					Camel = "setListenerErrorHandler",
					Snake = "set_listener_error_handler",
				}
			do
				local Tree = Isolated.Parse(`option Casing = {Casing}\n{Schema}`)
				for _, Context in { "Server", "Client" } do
					local Source = Generator.Generate(Context :: any, Tree)
					if not string.find(Source, `{Name} = SetListenerErrorHandler,`, 1, true) then
						ErrorPrint(`Failed "Casing": the {Casing} {Context} module does not export {Name}.`)
					end

					if not string.find(Source, `{Name} = NOOP,`, 1, true) then
						ErrorPrint(`Failed "Casing": the {Casing} {Context} edit-mode stub has no {Name}.`)
					end
				end
			end

			--> The client's listeners are unchanged: their errors are raised, and nothing is reported.
			local Client = Generator.Generate("Client", Isolated.Parse(Schema))
			if string.find(Client, "ListenerFailed(", 1, true) or string.find(Client, "RunListener", 1, true) then
				ErrorPrint(`Failed "Client": the client module reports listener errors.`)
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

			if type(Stub.SetListenerErrorHandler) ~= "function" then
				ErrorPrint(
					`Failed "Edit mode": SetListenerErrorHandler is {type(Stub.SetListenerErrorHandler)} in the stub.`
				)
			else
				Stub.SetListenerErrorHandler(function() end)
			end
		end
	)

	Shared.Task.spawn = nil :: any
end
