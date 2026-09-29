--!strict
--- Specs for how a module comes up: `option ClientConnectTimeout`, `option AutoStart` and the remote
--- names every module exports. Each builds its modules into a World (test/World.luau), where the
--- remotes exist only once a server has made them.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local World = require("./World")
local fs = require("@lune/fs")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure

local EVENTS = [[
event Announce {
    From: Server,
    Type: Reliable,
    Call: ManySync,
    Data: string(..64)
}

event Position {
    From: Server,
    Type: Unreliable,
    Call: SingleSync,
    Data: u16
}

event Ready {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Rate: 10,
    Data: u8
}

function Price {
    Yield: Coroutine,
    Rate: 10,
    Data: u8,
    Return: u16
}

function Confirm {
    From: Server,
    Yield: Coroutine,
    Data: u8,
    Return: boolean
}
]]

local function Expect(Condition: boolean, Message: string)
	if not Condition then
		error(Message, 2)
	end
end

local function Same(Got: any, Expected: any, What: string)
	if Got ~= Expected then
		error(`{What}: expected {Expected}, got {Got}`, 2)
	end
end

--- Writes one side of `Options .. EVENTS` and returns its path.
local function Build(Name: string, Options: string, Side: "Server" | "Client"): string
	local Tree = Isolated.Parse(`option RemoteScope = "{Name}"\n{Options}\n{EVENTS}`)
	local Path = `../Network/Lifecycle{Name}{Side}.luau`
	fs.writeFile(Path, Generator.Generate(Side, Tree))
	return Path
end

local function Count(Map: { [any]: any }): number
	local Total = 0
	for _ in Map do
		Total += 1
	end
	return Total
end

--- Runs every Heartbeat connection once, as a frame would.
local function Frame(Heartbeat: any)
	for _, Connection in Heartbeat.Connections do
		Connection(1 / 60)
	end
end

---- ClientConnectTimeout ----

RunClosure("ClientConnectTimeout returns a disconnected client once the timeout passes", function()
	local Place = World.new()
	local Path = Build("CCTNONE", "option ClientConnectTimeout = 0.3\noption ManualReplication = true", "Client")

	local Began = os.clock()
	local Client = World.Load(Place, Path, "Client")
	local Took = os.clock() - Began

	Same(Client.Connected, false, "Connected")
	Expect(Took >= 0.3 and Took < 0.8, `the require took {Took} seconds for a timeout of 0.3`)
	Same(#Place.Waits, 1, "WaitForChild calls")
	Same(Place.Waits[1].Name, "CCTNONE_BLINK_RELIABLE_REMOTE", "the remote waited for")
	Same(Place.Waits[1].Timeout, 0.3, "the timeout passed to WaitForChild")
	Same(Client.Remotes.Reliable, "CCTNONE_BLINK_RELIABLE_REMOTE", "Remotes.Reliable")
	Same(Client.Remotes.Unreliable, "CCTNONE_BLINK_UNRELIABLE_REMOTE", "Remotes.Unreliable")

	--> Every entry point keeps its shape and does nothing.
	Same(Client.Ready.Fire(7), nil, "Fire's result")
	Client.StepReplication()
	local Heard = 0
	local Disconnect = Client.Announce.On(function()
		Heard += 1
	end)
	Same(type(Disconnect), "function", "On's disconnect")
	Disconnect()

	local Invoked, Failure = pcall(Client.Price.Invoke, 1)
	Same(Invoked, false, "Invoke succeeding")
	Expect(string.find(tostring(Failure), "not connected", 1, true) ~= nil, `Invoke failed with "{Failure}"`)

	--> The server shows up late: the client stays as it was, and hears nothing.
	local Reliable = Place:Plant(Client.Remotes.Reliable, "RemoteEvent")
	Place:Plant(Client.Remotes.Unreliable, "UnreliableRemoteEvent")
	Same(Count(Reliable.OnClientEvent.Connections), 0, "connections to a late remote")
	Client.Ready.Fire(7)
	Client.StepReplication()
	Same(#Reliable.Sent, 0, "packets sent to a late remote")
	Same(Client.Connected, false, "Connected after the remotes appeared")
	Same(Heard, 0, "listener calls")
	Same(#Place.Warnings, 0, "warnings")
end)

RunClosure("ClientConnectTimeout connects at once to a server that is there", function()
	local Place = World.new()
	local Options = "option ClientConnectTimeout = 5\noption ManualReplication = true"
	local Server = World.Load(Place, Build("CCTUP", Options, "Server"), "Server")

	local Began = os.clock()
	local Client = World.Load(Place, Build("CCTUP", Options, "Client"), "Client")
	local Took = os.clock() - Began

	Same(Client.Connected, true, "Connected")
	Expect(Took < 1, `the require took {Took} seconds with both remotes in place`)
	Same(#Place.Waits, 2, "WaitForChild calls")
	Same(Place.Waits[1].Timeout, 5, "the first wait's timeout")
	Expect(Place.Waits[2].Timeout ~= nil and Place.Waits[2].Timeout <= 5, "the second wait is bounded by what is left")

	--> The exported names are the names of the instances the server made.
	for _, Channel in { "Reliable", "Unreliable" } do
		local Name = Server.Remotes[Channel]
		Same(Client.Remotes[Channel], Name, `the client's {Channel} name`)
		Expect(Place.Children[Name] ~= nil, `no instance is called {Name}`)
		Same(Place.Children[Name].Name, Name, `the {Channel} remote's name`)
	end
	Same(Count(Place.Children), 2, "remotes in ReplicatedStorage")

	--> And it talks.
	local Got: number? = nil
	Server.Ready.On(function(_Player, Value)
		Got = Value
	end)
	Client.Ready.Fire(42)
	Client.StepReplication()
	Same(Got, 42, "the value the server heard")
end)

RunClosure("ClientConnectTimeout connects to remotes that appear during the wait", function()
	local Place = World.new()
	local Options = "option ClientConnectTimeout = 3\noption ManualReplication = true"
	local ServerPath = Build("CCTLATE", Options, "Server")
	local ClientPath = Build("CCTLATE", Options, "Client")

	task.delay(0.1, function()
		World.Load(Place, ServerPath, "Server")
	end)

	local Began = os.clock()
	local Client = World.Load(Place, ClientPath, "Client")
	local Took = os.clock() - Began

	Same(Client.Connected, true, "Connected")
	Expect(Took >= 0.1 and Took < 1.5, `the require took {Took} seconds for remotes made after 0.1`)
end)

RunClosure("A client without ClientConnectTimeout has no Connected and waits unbounded", function()
	local Place = World.new()
	local Server = World.Load(Place, Build("CCTOFF", "option ManualReplication = true", "Server"), "Server")
	local Client = World.Load(Place, Build("CCTOFF", "option ManualReplication = true", "Client"), "Client")

	Same(Client.Connected, nil, "Connected")
	Same(#Place.Waits, 2, "WaitForChild calls")
	Same(Place.Waits[1].Timeout, 5, "the reliable wait's first timeout, after which it warns")
	Same(Place.Waits[2].Timeout, nil, "the unreliable wait's timeout")
	Same(#Place.Warnings, 0, "warnings")
	Same(Server.Remotes.Reliable, "CCTOFF_BLINK_RELIABLE_REMOTE", "Remotes.Reliable")
	Same(Server.Start, nil, "Start")
end)

RunClosure(
	"A client without ClientConnectTimeout says once why it waits, and connects when the server comes",
	function()
		local Place = World.new()
		local ServerPath = Build("CCTSLOW", "option ManualReplication = true", "Server")
		local ClientPath = Build("CCTSLOW", "option ManualReplication = true", "Client")

		task.delay(5.3, function()
			World.Load(Place, ServerPath, "Server")
		end)

		local Client = World.Load(Place, ClientPath, "Client")
		Same(Client.Connected, nil, "Connected")
		Same(#Place.Warnings, 1, "warnings")
		Expect(string.find(Place.Warnings[1], "ClientConnectTimeout", 1, true) ~= nil, `warned "{Place.Warnings[1]}"`)
	end
)

---- RemotesFolder ----

--- The folder the server made, and that nothing else was put in ReplicatedStorage.
local function FolderOf(Place: any, Name: string): any
	local Made = Place.Children[Name]
	Expect(Made ~= nil and Made.ClassName == "Folder", `no Folder called {Name} in ReplicatedStorage`)
	Same(Count(Place.Children), 1, "children of ReplicatedStorage")
	return Made
end

RunClosure("RemotesFolder puts both remotes in a folder, and the client finds them there", function()
	local Place = World.new()
	local Options = 'option RemotesFolder = "Net"\noption ManualReplication = true'
	local Server = World.Load(Place, Build("RFOPEN", Options, "Server"), "Server")
	local Client = World.Load(Place, Build("RFOPEN", Options, "Client"), "Client")

	local Made = FolderOf(Place, "Net")
	for _, Channel in { "Reliable", "Unreliable" } do
		Expect(Made.Children[Server.Remotes[Channel]] ~= nil, `the {Channel} remote is not in the folder`)
	end
	Same(#Place.Warnings, 0, "warnings")

	local Got: number? = nil
	Server.Ready.On(function(_Player, Value)
		Got = Value
	end)
	Client.Ready.Fire(7)
	Client.StepReplication()
	Same(Got, 7, "the value the server heard")
end)

RunClosure("RemotesFolder with ClientConnectTimeout waits for the folder within the timeout", function()
	local Place = World.new()
	local Options = 'option RemotesFolder = "Net"\noption ClientConnectTimeout = 3\noption ManualReplication = true'
	local ServerPath = Build("RFLATE", Options, "Server")
	local ClientPath = Build("RFLATE", Options, "Client")

	task.delay(0.1, function()
		World.Load(Place, ServerPath, "Server")
	end)
	local Client = World.Load(Place, ClientPath, "Client")
	Same(Client.Connected, true, "Connected")
	FolderOf(Place, "Net")

	local Alone = World.new()
	local Began = os.clock()
	local Stubbed = World.Load(
		Alone,
		Build("RFNONE", 'option RemotesFolder = "Net"\noption ClientConnectTimeout = 0.3', "Client"),
		"Client"
	)
	local Took = os.clock() - Began
	Same(Stubbed.Connected, false, "Connected with no server")
	Expect(Took >= 0.3 and Took < 0.8, `the require took {Took} seconds for a timeout of 0.3`)
end)

---- AutoStart ----

RunClosure("AutoStart = false creates nothing until Start, and Start twice changes nothing", function()
	local Place = World.new()
	local Heartbeat = Shared.Signal.new()
	local Server = World.Load(Place, Build("ASOFF", "option AutoStart = false", "Server"), "Server", Heartbeat)

	Same(#Place.Created, 0, "instances created at require")
	Same(Count(Place.Children), 0, "remotes at require")
	Same(Count(Heartbeat.Connections), 0, "Heartbeat connections at require")
	Same(type(Server.Start), "function", "Start")

	--> Before Start: sends go nowhere and say so once, an invocation fails at once.
	Server.Announce.Fire(Shared.Player, "early")
	Server.Announce.FireAll("early")
	Server.Position.Fire(Shared.Player, 3)
	Frame(Heartbeat)
	Same(#Place.Warnings, 1, "warnings for three sends before Start")
	Expect(string.find(Place.Warnings[1], "before Start()", 1, true) ~= nil, `warned "{Place.Warnings[1]}"`)

	local Invoked, Failure = pcall(Server.Confirm.Invoke, Shared.Player, 1)
	Same(Invoked, false, "Invoke before Start succeeding")
	Expect(string.find(tostring(Failure), "before Start()", 1, true) ~= nil, `Invoke failed with "{Failure}"`)

	Server.Start()
	Same(table.concat(Place.Created, ","), "RemoteEvent,UnreliableRemoteEvent", "instances created by Start")
	local Reliable = Place.Children[Server.Remotes.Reliable]
	local Unreliable = Place.Children[Server.Remotes.Unreliable]
	Expect(Reliable ~= nil and Reliable.ClassName == "RemoteEvent", "Start made no reliable remote")
	Expect(Unreliable ~= nil and Unreliable.ClassName == "UnreliableRemoteEvent", "Start made no unreliable remote")
	Expect(Reliable:GetAttribute("SchemaSignature") ~= nil, "the reliable remote carries no signature")
	Same(Count(Heartbeat.Connections), 1, "Heartbeat connections after Start")
	Same(Count(Reliable.OnServerEvent.Connections), 1, "reliable connections after Start")
	Same(Count(Unreliable.OnServerEvent.Connections), 1, "unreliable connections after Start")

	--> What was sent before Start stays dropped; what is sent after goes out.
	Server.Announce.Fire(Shared.Player, "late")
	Frame(Heartbeat)
	Same(#Reliable.Sent, 1, "reliable packets after Start")
	local Text = buffer.tostring(Reliable.Sent[1])
	Expect(string.find(Text, "late", 1, true) ~= nil, "the packet lacks the event sent after Start")
	Expect(string.find(Text, "early", 1, true) == nil, "an event sent before Start went out after it")
	Server.Position.Fire(Shared.Player, 3)
	Same(#Unreliable.Sent, 1, "unreliable packets after Start")

	Server.Start()
	Same(#Place.Created, 2, "instances created after a second Start")
	Same(Count(Heartbeat.Connections), 1, "Heartbeat connections after a second Start")
	Same(Count(Reliable.OnServerEvent.Connections), 1, "reliable connections after a second Start")
	Same(#Place.Warnings, 1, "warnings in all")
end)

RunClosure("AutoStart left on creates the remotes at require, as before", function()
	local Place = World.new()
	local Heartbeat = Shared.Signal.new()
	local Server = World.Load(Place, Build("ASON", "", "Server"), "Server", Heartbeat)

	Same(table.concat(Place.Created, ","), "RemoteEvent,UnreliableRemoteEvent", "instances created at require")
	Same(Count(Heartbeat.Connections), 1, "Heartbeat connections at require")
	Same(Server.Start, nil, "Start")
end)

RunClosure("The client module ignores AutoStart", function()
	local Place = World.new()
	local Options = "option AutoStart = false\noption ClientConnectTimeout = 0.1"
	local Client = World.Load(Place, Build("ASCLIENT", Options, "Client"), "Client")
	Same(Client.Start, nil, "the client's Start")
	Same(Client.Connected, false, "Connected with no server")
end)

---- One module per remote ----

RunClosure("A second VM requiring either module is refused, and made remotes are not archivable", function()
	--> Every World.Load is a VM of its own, with its own _G, as an Actor is: the scope guard cannot see
	--> the first copy, and only the claim on the remote stops the second from connecting to it too.
	local Place = World.new()
	local ServerPath = Build("ACTOR", "", "Server")
	local ClientPath = Build("ACTOR", "", "Client")
	World.Load(Place, ServerPath, "Server")

	local Reliable = Place.Children.ACTOR_BLINK_RELIABLE_REMOTE
	local Unreliable = Place.Children.ACTOR_BLINK_UNRELIABLE_REMOTE
	Same(Reliable.Archivable, false, "the reliable remote's Archivable")
	Same(Unreliable.Archivable, false, "the unreliable remote's Archivable")

	local Loaded, Failure = pcall(World.Load, Place, ServerPath, "Server")
	Same(Loaded, false, "a second server module loading")
	Expect(
		string.find(tostring(Failure), "another Luau VM", 1, true) ~= nil,
		`the second server failed with "{Failure}"`
	)
	Same(Count(Reliable.OnServerEvent.Connections), 1, "reliable server connections")

	World.Load(Place, ClientPath, "Client")
	Loaded, Failure = pcall(World.Load, Place, ClientPath, "Client")
	Same(Loaded, false, "a second client module loading")
	Expect(
		string.find(tostring(Failure), "another Luau VM", 1, true) ~= nil,
		`the second client failed with "{Failure}"`
	)
	Same(Count(Reliable.OnClientEvent.Connections), 1, "reliable client connections")
end)

require("./LifecycleOptions")
require("./LifecycleListeners")

return {}
