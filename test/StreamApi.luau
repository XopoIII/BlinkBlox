--!strict
--- Specs for a stream's surface outside the wire: its members follow `Casing`, the edit-mode stub
--- keeps them, and the TypeScript declarations type both sides. The scheduler is Streams.luau's, the
--- packets StreamPackets.luau's.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local Shared = require("./Shared")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Heads {
	From: Server,
	Type: OrderedUnreliable,
	Call: SingleSync,
	Stream: { Rate: 10, Fast: 20 },
	Data: u8[..16]
}
]]

--- Each casing's spelling of the server's four members.
local CASINGS = {
	Pascal = { "Set", "Clear", "Urgent", "SetFast" },
	Camel = { "set", "clear", "urgent", "setFast" },
	Snake = { "set", "clear", "urgent", "set_fast" },
}

--- The TypeScript lines each side declares, `%s` standing for the members in order.
local SERVER_TYPES = {
	"%s: (Value: number[]) => void",
	"%s: () => void",
	"%s: () => void",
	"%s: (Fast: boolean) => void",
}

RunClosure("A stream's members follow Casing, are stubbed in edit mode and typed for TypeScript", function()
	for Casing, Members in CASINGS do
		local Tree = Isolated.Parse(`option Casing = {Casing}\n{SCHEMA}`)
		local Server = Generator.Generate("Server" :: any, Tree)
		local Client = Generator.Generate("Client" :: any, Tree)
		local ServerTypes = Generator.GenerateTypescript("Server" :: any, Tree)
		local ClientTypes = Generator.GenerateTypescript("Client" :: any, Tree)

		for Index, Member in Members do
			if not string.find(Server, `{Member} = function(`, 1, true) then
				ErrorPrint(`Failed "Casing": the {Casing} server does not export {Member}.`)
			end

			if not string.find(Server, `{Member} = NOOP`, 1, true) then
				ErrorPrint(`Failed "Casing": the {Casing} server's edit-mode stub has no {Member}.`)
			end

			local Line = string.format(SERVER_TYPES[Index], Member)
			if not string.find(ServerTypes, Line, 1, true) then
				ErrorPrint(`Failed "TypeScript": the {Casing} server declaration lacks "{Line}".`)
			end

			--> The client has none of them: it only listens.
			if string.find(Client, `%f[%w_]{Member} = `) then
				ErrorPrint(`Failed "Casing": the {Casing} client exports the server's {Member}.`)
			end
		end

		--> The Fire family is replaced, not kept beside Set.
		if string.find(ServerTypes, "(Player: Player", 1, true) then
			ErrorPrint(`Failed "TypeScript": the {Casing} server declaration still types a Fire.`)
		end

		local On = if Casing == "Pascal" then "On" else "on"
		local Listener = `{On}: (Listener: (Value: number[] | undefined, ServerTime: number) => void) => (() => void)`
		if not string.find(ClientTypes, Listener, 1, true) then
			ErrorPrint(`Failed "TypeScript": the {Casing} client declaration lacks "{Listener}".`)
		end
	end
end)

RunClosure("A stream's edit-mode stub can be driven without remotes", function()
	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	--> Sources/Stream.blink, compiled by the suite: Camel casing, one stream at the top and one scoped.
	local Stub = Modules.MockRequire("../Network/StreamServer.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	for _, Stream in { Stub.Heads, Stub.World.Clock } do
		for _, Member in CASINGS.Camel do
			local Kind = type(Stream[Member])
			assert(Kind == "function", `the stub's {Member} is {Kind}, expected a function`)
		end

		Stream.set({})
		Stream.urgent()
		Stream.setFast(true)
		Stream.clear()
	end
end)

return {}
