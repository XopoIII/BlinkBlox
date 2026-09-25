--!strict
--- Just enough of Roblox, on Lune, to load the other tools the Studio benchmark compares against:
--- zap's generated modules, ByteNet and Packet.
---
--- Environment.luau loads BlinkBlox's own modules, whose few needs are known. The other tools reach
--- for more: an instance tree they `require(script.Parent.X)` through, `Instance.new` for their
--- remotes, attributes, `HttpService`, `Enum`, and a `task` library they dispatch listeners through.
--- A `Universe` is what Roblox replicates -- the instance tree, the remotes, the one player -- and a
--- `World` is one side of it, server or client, with its own module cache, `_G` and RunService.
---
--- Modules keep the real global environment, as in Environment.luau: a chunk with a custom one is
--- never natively compiled. Roblox's globals arrive as locals prepended to each module's source.
---
--- `task` runs a spawned thread at once and queues a deferred one, and the benchmark drains that
--- queue inside the timed region it belongs to. Packet hands every listener to `task.defer`, so a
--- decode that did not drain it would be timed without calling anyone.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local World = {}

local function Signal()
	local Callbacks: { (...any) -> () } = {}
	local Self = {}

	function Self.Connect(_self, Callback: (...any) -> ())
		table.insert(Callbacks, Callback)
		return {
			Disconnect = function()
				local Index = table.find(Callbacks, Callback)
				if Index then
					table.remove(Callbacks, Index)
				end
			end,
		}
	end
	Self.Once = Self.Connect

	function Self.Fire(_self, ...)
		for _, Callback in table.clone(Callbacks) do
			Callback(...)
		end
	end

	function Self.Wait()
		error("The benchmark cannot wait on a signal")
	end

	return Self
end

--> An instance: its properties and children behind a metatable, so `script.Signal` finds a child and
--> assigning `Parent` moves it.
local Methods = {}
local Hidden: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local function Create(ClassName: string, Name: string?): any
	local State = {
		ClassName = ClassName,
		Properties = { Name = Name or ClassName, ClassName = ClassName } :: { [string]: any },
		Children = {} :: { any },
		Attributes = {} :: { [string]: any },
		AttributeChanged = Signal(),
		Changed = Signal(),
	}

	local Object = setmetatable({}, {
		__index = function(Self, Key)
			local Method = Methods[Key]
			if Method then
				return Method
			end
			if Key == "AttributeChanged" or Key == "Changed" then
				return State[Key]
			end
			local Value = State.Properties[Key]
			if Value ~= nil then
				return Value
			end
			for _, Child in State.Children do
				if Child.Name == Key then
					return Child
				end
			end
			return nil
		end,
		__newindex = function(Self, Key, Value)
			if Key == "Parent" then
				local Previous = State.Properties.Parent
				if Previous then
					local Siblings = Hidden[Previous].Children
					table.remove(Siblings, table.find(Siblings, Self))
				end
				if Value then
					table.insert(Hidden[Value].Children, Self)
				end
			end
			State.Properties[Key] = Value
			if Key == "Value" then
				State.Changed:Fire(Value)
			end
		end,
		__tostring = function()
			return State.Properties.Name
		end,
	})

	Hidden[Object] = State
	return Object
end

function Methods.IsA(Self, Queried: string): boolean
	return Hidden[Self].ClassName == Queried
end

function Methods.FindFirstChild(Self, Name: string)
	for _, Child in Hidden[Self].Children do
		if Child.Name == Name then
			return Child
		end
	end
	return nil
end

function Methods.WaitForChild(Self, Name: string)
	return assert(Methods.FindFirstChild(Self, Name), `{Self.Name} has no {Name}, and the benchmark cannot wait`)
end

function Methods.GetChildren(Self)
	return table.clone(Hidden[Self].Children)
end

function Methods.SetAttribute(Self, Name: string, Value: any)
	local State = Hidden[Self]
	State.Attributes[Name] = Value
	State.AttributeChanged:Fire(Name)
end

function Methods.GetAttribute(Self, Name: string)
	return Hidden[Self].Attributes[Name]
end

function Methods.Destroy(Self)
	Self.Parent = nil
end

function Methods.IsDescendantOf(_Self, _Ancestor)
	return true
end

export type Sent = { Buffer: buffer, Instances: { any }? }

export type Universe = {
	Native: boolean,
	Root: any,
	ReplicatedStorage: any,
	Players: any,
	Player: any,
	--> Every packet a client fired since the benchmark last took them.
	Outbox: { Sent },
	--> What a module's path is as an instance, for `require(script.X)` and for `script` itself.
	Modules: { [string]: any },
	Deferred: { { any } },
}

local function Remote(Universe: Universe, ClassName: string)
	local Object = Create(ClassName)
	local State = Hidden[Object]
	State.Properties.OnServerEvent = Signal()
	State.Properties.OnClientEvent = Signal()
	State.Properties.FireServer = function(_self, Buffer: buffer, Instances: { any }?)
		table.insert(Universe.Outbox, { Buffer = Buffer, Instances = Instances, Remote = Object } :: any)
	end
	--> The benchmark times a client sending to the server. What a server sends back goes nowhere.
	State.Properties.FireClient = function() end
	State.Properties.FireAllClients = function() end
	return Object
end

--> Mirrors a directory as ModuleScripts and Folders: a directory with an `init.luau` is that module,
--> and the rest of its entries are its children, as Rojo builds it.
local function Mount(Universe: Universe, Path: string, Parent: any): any
	local Name = string.match(Path, "([^/]+)$") :: string
	local Object
	if fs.isDir(Path) then
		local Init = `{Path}/init.luau`
		Object = Create(if fs.isFile(Init) then "ModuleScript" else "Folder", Name)
		if fs.isFile(Init) then
			Universe.Modules[Init] = Object
		end
		for _, Entry in fs.readDir(Path) do
			local Child = `{Path}/{Entry}`
			if Entry ~= "init.luau" and (fs.isDir(Child) or string.sub(Entry, -5) == ".luau") then
				Mount(Universe, Child, Object)
			end
		end
	else
		Object = Create("ModuleScript", string.sub(Name, 1, -6))
		Universe.Modules[Path] = Object
	end
	Hidden[Object].Path = Path
	Object.Parent = Parent
	return Object
end

--- A fresh universe. `Mounts` are the directories required from, relative to the benchmark.
function World.Universe(Native: boolean, Mounts: { string }): Universe
	local Root = Create("DataModel", "game")
	local ReplicatedStorage = Create("ReplicatedStorage")
	ReplicatedStorage.Parent = Root

	local Players = Create("Players")
	local Player = Create("Player", "Player")
	Hidden[Player].Properties.UserId = 1
	Player.Parent = Players
	Hidden[Players].Properties.PlayerAdded = Signal()
	Hidden[Players].Properties.PlayerRemoving = Signal()
	Hidden[Players].Properties.LocalPlayer = Player
	Hidden[Players].Properties.GetPlayers = function()
		return { Player }
	end

	local Universe: Universe = {
		Native = Native,
		Root = Root,
		ReplicatedStorage = ReplicatedStorage,
		Players = Players,
		Player = Player,
		Outbox = {},
		Modules = {},
		Deferred = {},
	}

	for _, Path in Mounts do
		Mount(Universe, Path, ReplicatedStorage)
	end

	return Universe
end

local function Resume(Thread: thread, ...)
	local Success, Error = coroutine.resume(Thread, ...)
	if not Success then
		error(debug.traceback(Thread, tostring(Error)), 0)
	end
end

local function Task(Universe: Universe)
	local Task = {}

	function Task.spawn(Callback: any, ...): thread
		local Thread = if type(Callback) == "thread" then Callback else coroutine.create(Callback)
		Resume(Thread, ...)
		return Thread
	end

	function Task.defer(Callback: any, ...): thread
		local Thread = if type(Callback) == "thread" then Callback else coroutine.create(Callback)
		table.insert(Universe.Deferred, table.pack(Thread, ...))
		return Thread
	end

	function Task.delay(_Seconds: number, Callback: any, ...): thread
		--> Only invocation timeouts are delayed, and the benchmark invokes nothing.
		return if type(Callback) == "thread" then Callback else coroutine.create(Callback)
	end

	function Task.cancel(_Thread: thread) end

	function Task.wait()
		error("The benchmark cannot wait")
	end

	return table.freeze(Task)
end

--- Runs every deferred thread, and whatever those defer in turn.
function World.Drain(Universe: Universe)
	local Deferred = Universe.Deferred
	local Index = 1
	while Index <= #Deferred do
		local Entry = Deferred[Index]
		Resume(Entry[1], table.unpack(Entry, 2, (Entry :: any).n))
		Index += 1
	end
	table.clear(Deferred)
end

--> Only what the tools touch while loading: zap builds CFrames for its special cases, and Packet
--> lists Enums and a Vector3 among its statics.
local function Value(Kind: string)
	return setmetatable({}, {
		__index = function(Self, Key)
			local Member = { Kind = Kind, Name = Key }
			rawset(Self, Key, Member)
			return Member
		end,
	})
end

local CFrame = {
	Angles = function(...)
		return { Kind = "CFrame", ... }
	end,
	new = function(...)
		return { Kind = "CFrame", ... }
	end,
}

local function Constructor(Kind: string)
	return {
		new = function(...)
			return { Kind = Kind, ... }
		end,
		fromRGB = function(...)
			return { Kind = Kind, ... }
		end,
	}
end

local PRELUDE =
	"local game, script, require, task, warn, _G, Instance, CFrame, Vector3, Vector2, Color3, Enum, workspace = ...\n"

--> The prelude goes after the directives, which count only above the first line of code, and never
--> inside a block comment, whose lines would not start with `--`.
--> Also says whether the module asks to be natively compiled. A Roblox server compiles only the ones
--> that do, where Lune's `codegenEnabled` compiles everything: left alone, a tool that never declares
--> `--!native` -- Packet does not, and ByteNet does in 7 of its 35 files -- would be timed natively
--> here and interpreted in a game.
local function Prepare(Source: string, Native: boolean): (string, boolean)
	local Lines = string.split(Source, "\n")
	local Index = 1
	local Declared = false
	while Lines[Index] do
		local Line = Lines[Index]
		if string.sub(Line, 1, 3) == "--!" then
			if string.match(Line, "^%-%-!native%s*$") then
				Declared = true
				if not Native then
					table.remove(Lines, Index)
					continue
				end
			end
		elseif Line ~= "" and (string.sub(Line, 1, 2) ~= "--" or string.sub(Line, 1, 3) == "--[") then
			break
		end
		Index += 1
	end

	table.insert(Lines, Index, PRELUDE)
	return table.concat(Lines, "\n"), Declared
end

local function Normalise(Path: string): string
	local Parts = {}
	for _, Part in string.split(Path, "/") do
		if Part == ".." and #Parts > 0 and Parts[#Parts] ~= ".." then
			table.remove(Parts)
		elseif Part ~= "." and Part ~= "" then
			table.insert(Parts, Part)
		end
	end
	return table.concat(Parts, "/")
end

export type World = {
	Require: (Path: string) -> any,
	Heartbeat: any,
}

--- One side of `Universe`. Its modules see `RunService:IsServer()` as `IsServer`.
function World.new(Universe: Universe, IsServer: boolean): World
	local Heartbeat = Signal()
	local RunService = {
		Heartbeat = Heartbeat,
		PostSimulation = Heartbeat,
		PreSimulation = Signal(),
		Stepped = Signal(),
		RenderStepped = Signal(),
		IsServer = function()
			return IsServer
		end,
		IsClient = function()
			return not IsServer
		end,
		IsRunning = function()
			return true
		end,
		IsStudio = function()
			return false
		end,
	}

	local Services = {
		RunService = RunService,
		ReplicatedStorage = Universe.ReplicatedStorage,
		Players = Universe.Players,
		HttpService = {
			JSONEncode = function(_self, Value: any)
				return serde.encode("json", Value)
			end,
			JSONDecode = function(_self, Value: string)
				return serde.decode("json", Value)
			end,
		},
	}

	local Game = {
		GetService = function(_self, Name: string)
			return assert(Services[Name], `No mock for the {Name} service`)
		end,
	}

	local Instance = {
		new = function(ClassName: string, Parent: any?)
			local Object = if ClassName == "RemoteEvent" or ClassName == "UnreliableRemoteEvent"
				then Remote(Universe, ClassName)
				else Create(ClassName)
			if Parent then
				Object.Parent = Parent
			end
			return Object
		end,
	}

	local Globals = {}
	local Cache: { [string]: any } = {}
	local Loading: { [string]: boolean } = {}
	local Task = Task(Universe)
	local Enum = Value("Enum")
	local Warn = function() end

	local Require: (Target: any, From: string?) -> any
	local function Load(Path: string): any
		if Cache[Path] ~= nil then
			return Cache[Path]
		end
		assert(not Loading[Path], `{Path} requires itself`)
		Loading[Path] = true

		local Source, Declared = Prepare(fs.readFile(Path), Universe.Native)
		local Bytecode = luau.compile(Source, {
			optimizationLevel = 2,
			debugLevel = 1,
		})
		local Chunk = luau.load(Bytecode, {
			debugName = Path,
			codegenEnabled = Universe.Native and Declared,
		})

		local Script = Universe.Modules[Path] or Create("ModuleScript", Path)
		local function LocalRequire(Target: any)
			return Require(Target, Path)
		end

		local Result = Chunk(
			Game,
			Script,
			LocalRequire,
			Task,
			Warn,
			Globals,
			Instance,
			CFrame,
			Constructor("Vector3"),
			Constructor("Vector2"),
			Constructor("Color3"),
			Enum,
			Universe.Root
		)
		Cache[Path] = Result
		Loading[Path] = nil
		return Result
	end

	function Require(Target: any, From: string?): any
		if type(Target) ~= "string" then
			local Path = Hidden[Target] and Hidden[Target].Path
			if Path and fs.isDir(Path) then
				Path = `{Path}/init.luau`
			end
			return Load((assert(Path, `Cannot require {Target}`)))
		end

		local Base = if From then string.match(From, "^(.*)/[^/]*$") or "." else "."
		local Path = Normalise(`{Base}/{Target}`)
		if string.sub(Path, -5) == ".luau" and fs.isFile(Path) then
			return Load(Path)
		elseif fs.isFile(`{Path}.luau`) then
			return Load(`{Path}.luau`)
		end
		return Load(`{Path}/init.luau`)
	end

	return {
		Require = function(Path: string)
			return Require(Normalise(Path))
		end,
		Heartbeat = Heartbeat,
	}
end

return World
