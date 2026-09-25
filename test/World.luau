--!strict
--- A ReplicatedStorage that starts empty, for the specs of how a module comes up (Lifecycle.luau).
---
--- The mocks every other spec uses plant both remotes before anything is required, and their
--- WaitForChild is FindFirstChild. Neither can show a client waiting for remotes that never come, or a
--- server creating them only once started. Here a remote exists only once a server module has made
--- it with `Instance.new` and parented it, WaitForChild honours its timeout on the real clock, and
--- every call either makes is recorded.
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

export type Remote = {
	Name: string,
	ClassName: string,
	--- Every packet sent through this remote, from either side.
	Sent: { buffer },
	OnServerEvent: any,
	OnClientEvent: any,
	[string]: any,
}

export type World = {
	--- Children of ReplicatedStorage, by name.
	Children: { [string]: Remote },
	--- Every `Instance.new` call, in order, by class name.
	Created: { string },
	--- Every WaitForChild call: the name asked for and the timeout given.
	Waits: { { Name: string, Timeout: number? } },
	--- Every warning either module raised.
	Warnings: { string },
	ReplicatedStorage: any,
	--- Makes a remote appear, as a server elsewhere would.
	Plant: (self: World, Name: string, ClassName: string, Signature: string?) -> Remote,
}

local function NewRemote(World: World, ClassName: string): Remote
	local Attributes: { [string]: any } = {}
	local Fields: { [string]: any } = {
		Name = ClassName,
		ClassName = ClassName,
		Sent = {},
		OnServerEvent = Shared.Signal.new(),
		OnClientEvent = Shared.Signal.new(),
	}

	local Remote = {}
	Fields.SetAttribute = function(_self, Name: string, Value: any)
		Attributes[Name] = Value
	end
	Fields.GetAttribute = function(_self, Name: string): any
		return Attributes[Name]
	end
	Fields.IsA = function(_self, Queried: string): boolean
		return Queried == ClassName
	end
	--> A loopback: what the client fires reaches the server's connections, and the other way round.
	Fields.FireServer = function(_self, Buffer: buffer, Instances: { any })
		table.insert(Fields.Sent, Buffer)
		Fields.OnServerEvent:Fire(Shared.Player, Buffer, Instances)
	end
	Fields.FireClient = function(_self, _Player: any, Buffer: buffer, Instances: { any })
		table.insert(Fields.Sent, Buffer)
		Fields.OnClientEvent:Fire(Buffer, Instances)
	end
	Fields.FireAllClients = function(_self, Buffer: buffer, Instances: { any })
		table.insert(Fields.Sent, Buffer)
		Fields.OnClientEvent:Fire(Buffer, Instances)
	end

	return setmetatable(Remote, {
		__index = Fields,
		__newindex = function(_self, Key: string, Value: any)
			Fields[Key] = Value
			if Key == "Parent" and Value == World.ReplicatedStorage then
				World.Children[Fields.Name] = Remote :: any
			end
		end,
	}) :: any
end

local function new(): World
	local World: World = {
		Children = {},
		Created = {},
		Waits = {},
		Warnings = {},
		ReplicatedStorage = nil,
		Plant = nil :: any,
	}

	World.ReplicatedStorage = {
		FindFirstChild = function(_self, Name: string): Remote?
			return World.Children[Name]
		end,
		WaitForChild = function(_self, Name: string, Timeout: number?): Remote?
			table.insert(World.Waits, { Name = Name, Timeout = Timeout })
			local Started = os.clock()
			while World.Children[Name] == nil do
				if Timeout and os.clock() - Started >= Timeout then
					return nil
				end
				task.wait(1 / 120)
			end
			return World.Children[Name]
		end,
	}

	function World.Plant(self: World, Name: string, ClassName: string, Signature: string?): Remote
		local Remote = NewRemote(self, ClassName)
		Remote.Name = Name
		Remote:SetAttribute("SchemaSignature", Signature)
		Remote.Parent = self.ReplicatedStorage
		return Remote
	end

	return World
end

--- Loads a generated module into the world as one side. `Heartbeat` is the side's own, driven by the
--- spec rather than by a clock.
local function Load(World: World, Path: string, Side: "Server" | "Client", Heartbeat: any?): any
	local Services = {
		ReplicatedStorage = World.ReplicatedStorage,
		RunService = {
			Heartbeat = Heartbeat or Shared.Signal.new(),
			IsClient = function(_self)
				return Side == "Client"
			end,
			IsServer = function(_self)
				return Side == "Server"
			end,
			IsRunning = function(_self)
				return true
			end,
		},
		Players = {
			PlayerRemoving = Shared.Signal.new(),
			MaxPlayers = 1,
			GetPlayers = function(_self)
				return { Shared.Player }
			end,
		},
	}

	return Modules.MockRequire(Path, {
		game = {
			GetService = function(_self, Name: string)
				return assert((Services :: any)[Name], `No service "{Name}" in this world.`)
			end,
		},
		Instance = {
			new = function(ClassName: string)
				table.insert(World.Created, ClassName)
				return NewRemote(World, ClassName)
			end,
		},
		warn = function(...)
			table.insert(World.Warnings, table.concat({ ... }, " "))
		end,
	})
end

return {
	new = new,
	Load = Load,
}
