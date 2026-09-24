--!strict
--- A server and client built from a schema of a spec's own, wired to remotes no other spec shares.
---
--- The pair every other spec drives is Test.blink's, bridged through Shared.Bridge, with listeners
--- and handlers that specs install and replace as they go. A spec that needs to see exactly which
--- bytes the client sent, or to feed the server bytes of its own, builds its pair here instead: the
--- modules get a remote scope of their own, so their remotes are stubs that capture what the client
--- fires and pass the server only what the spec feeds it.
local Attributes = require("@compiler/Modules/Attributes")
local ClientEnvironment = require("./Client")
local Error = require("@compiler/Modules/Error")
local Generator = require("@compiler/Generator")
local Modules = require("./Modules")
local Parser = require("@compiler/Parser")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local fs = require("@lune/fs")

export type Packet = { Buffer: buffer, Instances: { any } }

export type Pair = {
	Tree: any,
	Server: any,
	Client: any,
	--- Every packet the client fired on the reliable channel, oldest first.
	Sent: { Packet },
	--- Hands the server a packet as though `Shared.Player` sent it.
	Feed: (Reliable: boolean, Buffer: buffer, Instances: { any }?) -> (),
}

--- One remote for both sides: the server finds it and sets its signature on it, the client finds it
--- and reads that signature back, and what the client fires lands in `Sent` rather than anywhere else.
local function Remote(ClassName: string, Sent: { Packet })
	local Stored: { [string]: any } = {}
	return {
		SetAttribute = function(_self, Name: string, Value: any)
			Stored[Name] = Value
		end,
		GetAttribute = function(_self, Name: string): any
			return Stored[Name]
		end,
		IsA = function(_self, Queried: string)
			return Queried == ClassName
		end,
		FireServer = function(_self, Buffer: buffer, Instances: { any })
			local Copy = buffer.create(buffer.len(Buffer))
			buffer.copy(Copy, 0, Buffer)
			table.insert(Sent, { Buffer = Copy, Instances = table.clone(Instances) })
		end,
		FireClient = function() end,
		FireAllClients = function() end,
		OnServerEvent = Shared.Signal.new(),
		OnClientEvent = Shared.Signal.new(),
	}
end

--- The `warn` these modules get: recorded like every module's, not printed. The specs that use them
--- feed thousands of packets meant to fail, and each would otherwise be a line of output.
local function Quiet(...)
	table.insert(Shared.Warnings, table.concat({ ... }, " "))
end

--- Parses `Source` with its imports resolved from `Directory`, silencing its warnings: they belong
--- to the spec that compiles the schema for real, not to every spec that builds it again.
local function Parse(Source: string, Directory: string?, File: string?): any
	local Hook = Error.OnEmit
	Error.OnEmit = function(Diagnostic)
		return Diagnostic.Severity == "Warning"
	end

	local Success, Tree = pcall(function()
		return Parser.new(Directory, File, nil, Attributes.new(nil)):Parse(Source)
	end)

	Error.OnEmit = Hook
	if not Success then
		error(Tree, 0)
	end

	return Tree
end

--- Builds the pair. `Scope` names its remotes, and must be unique among the pairs a run builds.
--- `Client` is false for a spec that only feeds the server.
local function Build(Tree: any, Scope: string, WithClient: boolean?): Pair
	local Options = table.clone(Tree.Value.Options)
	Options.RemoteScope = Scope
	Options.ManualReplication = true

	local Built = table.clone(Tree)
	Built.Value = table.clone(Tree.Value)
	Built.Value.Options = Options

	local Sent: { Packet } = {}
	local Reliable = Remote("RemoteEvent", Sent)
	local Unreliable = Remote("UnreliableRemoteEvent", {})
	for _, Environment in { ServerEnvironment, ClientEnvironment } do
		Environment.Instances[`{Scope}_BLINK_RELIABLE_REMOTE`] = Reliable
		Environment.Instances[`{Scope}_BLINK_UNRELIABLE_REMOTE`] = Unreliable
	end

	local Path = `../Network/Isolated{Scope}`
	fs.writeFile(`{Path}Server.luau`, Generator.Generate("Server", Built))
	local Server = Modules.MockRequire(`{Path}Server.luau`, {
		game = ServerEnvironment.game,
		Color3 = ServerEnvironment.Color3,
		DateTime = ServerEnvironment.DateTime,
		BrickColor = ServerEnvironment.BrickColor,
		warn = Quiet,
	})

	local Client = nil
	if WithClient ~= false then
		fs.writeFile(`{Path}Client.luau`, Generator.Generate("Client", Built))
		Client = Modules.MockRequire(`{Path}Client.luau`, {
			game = ClientEnvironment.game,
			Color3 = ClientEnvironment.Color3,
			DateTime = ClientEnvironment.DateTime,
			BrickColor = ClientEnvironment.BrickColor,
			warn = Quiet,
		})
	end

	return {
		Tree = Built,
		Server = Server,
		Client = Client,
		Sent = Sent,
		Feed = function(IsReliable: boolean, Buffer: buffer, Instances: { any }?)
			local Target = if IsReliable then Reliable else Unreliable
			Target.OnServerEvent:Fire(Shared.Player, Buffer, Instances or {})
		end,
	}
end

return {
	Parse = Parse,
	Build = Build,
}
