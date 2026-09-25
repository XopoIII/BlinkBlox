--!strict
--- Specs for where the lifecycle options meet `SetListenerErrorHandler`: a client that timed out on
--- its remotes returns the edit-mode stubs, which must carry the setter too, and a server under
--- `AutoStart = false` connects its remotes only in `Start`, which must still route a listener's error
--- to a handler installed before it.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local World = require("./World")
local fs = require("@lune/fs")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure

local EVENTS = [[
event Ready {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}

event Moved {
    From: Client,
    Type: Unreliable,
    Call: ManyAsync,
    Data: u8
}

function Price {
    Yield: Coroutine,
    Data: u8,
    Return: u16
}
]]

local function Same(Got: any, Expected: any, What: string)
	if Got ~= Expected then
		error(`{What}: expected {Expected}, got {Got}`, 2)
	end
end

local function Build(Name: string, Options: string, Side: "Server" | "Client"): string
	local Tree = Isolated.Parse(`option RemoteScope = "{Name}"\n{Options}\n{EVENTS}`)
	local Path = `../Network/LifecycleListeners{Name}{Side}.luau`
	fs.writeFile(Path, Generator.Generate(Side, Tree))
	return Path
end

type Report = { Player: any, Event: string, Failure: string, Count: number }

RunClosure("A client that timed out on its remotes stubs SetListenerErrorHandler", function()
	for _, Case in
		{
			{ Casing = "Pascal", Name = "SetListenerErrorHandler" },
			{ Casing = "Snake", Name = "set_listener_error_handler" },
		}
	do
		local Place = World.new()
		local Options = `option ClientConnectTimeout = 0.1\noption Casing = {Case.Casing}`
		local Client = World.Load(Place, Build(`LLSTUB{Case.Casing}`, Options, "Client"), "Client")

		Same(Client[if Case.Casing == "Snake" then "connected" else "Connected"], false, `{Case.Casing}: Connected`)
		Same(type(Client[Case.Name]), "function", `{Case.Casing}: {Case.Name}`)
		Same(Client[Case.Name](function() end), nil, `{Case.Casing}: {Case.Name}'s result`)
		Same(Client[Case.Name](nil), nil, `{Case.Casing}: {Case.Name}(nil)'s result`)
		Same(#Place.Warnings, 0, `{Case.Casing}: warnings`)
	end
end)

RunClosure("An AutoStart = false server reports listener errors after Start", function()
	local Place = World.new()
	local Options = "option AutoStart = false\noption ClientConnectTimeout = 5\noption ManualReplication = true"
	local Server = World.Load(Place, Build("LLSTART", Options, "Server"), "Server")
	Shared.SetPlayerInGame(true)

	--> Installed before Start, as a game's bootstrap would, next to the listeners.
	local Reports: { Report } = {}
	Server.SetListenerErrorHandler(function(Player, Event, Failure, Count)
		table.insert(Reports, { Player = Player, Event = Event, Failure = Failure, Count = Count })
	end)
	Server.Ready.On(function(_Player, Value)
		error(`Ready refused {Value}`, 0)
	end)
	Server.Moved.On(function(_Player, Value)
		error(`Moved refused {Value}`, 0)
	end)
	Server.Price.On(function(_Player, Value): number
		error(`Price refused {Value}`, 0)
	end)

	Server.Start()
	local Client = World.Load(Place, Build("LLSTART", Options, "Client"), "Client")
	Same(Client.Connected, true, "Connected")

	Client.Ready.Fire(7)
	Client.StepReplication()
	Client.Moved.Fire(8)
	task.wait(0.1)
	Same(#Reports, 2, "reports after two throwing events")
	table.sort(Reports, function(A, B)
		return A.Event < B.Event
	end)
	for Index, Expected in
		{ { Event = "Moved", Failure = "Moved refused 8" }, { Event = "Ready", Failure = "Ready refused 7" } }
	do
		local Report = Reports[Index]
		Same(Report.Player, Shared.Player, `{Expected.Event}: the player`)
		Same(Report.Event, Expected.Event, `report {Index}: the event`)
		Same(Report.Failure, Expected.Failure, `{Expected.Event}: the failure`)
		Same(Report.Count, 1, `{Expected.Event}: the count`)
	end

	--> A function's error is reported too, and its caller is still answered with a failure.
	local Answered: boolean? = nil
	local Failure = ""
	task.spawn(function()
		local Invoked, Reason = pcall(Client.Price.Invoke, 9)
		Answered, Failure = Invoked, tostring(Reason)
	end)
	Client.StepReplication()
	task.wait(0.1)
	Server.StepReplication()
	task.wait(0.1)

	Same(#Reports, 3, "reports after the function threw")
	Same(Reports[3].Event, "Price", "the function's report")
	Same(Reports[3].Failure, "Price refused 9", "the function's failure")
	Same(Reports[3].Count, 1, "the function's count")
	Same(Answered, false, "the invocation succeeding")
	Same(Failure ~= "", true, "the invocation's failure is empty")

	--> With a handler installed nothing reaches the output.
	Same(#Place.Warnings, 0, "warnings")
end)

RunClosure("The TypeScript declarations carry SetListenerErrorHandler beside the lifecycle members", function()
	local HANDLER = ": (handler?: (player: Player, event: string, failure: string, count: number) => void) => void\n"
	local Options = "option AutoStart = false\noption ClientConnectTimeout = 1\noption Casing = Camel"
	for _, Case in
		{ { Context = "Server", Member = "start: () => void" }, { Context = "Client", Member = "connected: boolean" } }
	do
		local Declaration = Generator.GenerateTypescript(Case.Context :: any, Isolated.Parse(`{Options}\n{EVENTS}`))
		for _, Line in { `setListenerErrorHandler{HANDLER}`, `{Case.Member}\n`, "remotes: { readonly" } do
			if not string.find(Declaration, `export declare const {Line}`, 1, true) then
				error(`the {Case.Context} declaration lacks "{Line}":\n{Declaration}`)
			end
		end
	end
end)

return {}
