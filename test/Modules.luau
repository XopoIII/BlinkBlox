--!strict
--- Loads the generated network modules against mocked Roblox globals, so that more than one spec
--- file can drive the same pair without compiling or loading them twice.
---
--- Requires `Harness.Prepare()` to have run: the modules this loads do not exist until then.
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local function MockTypeof(a: any)
	local TypeofA = typeof(a)
	if TypeofA == "table" and a.__typeof then
		return a.__typeof
	end

	return TypeofA
end

local function MockRequire(Path: string, Environment)
	local Source = fs.readFile(Path)
	local Bytecode = luau.compile(Source, {
		optimizationLevel = 1,
		debugLevel = 2,
	})

	Environment._G = {}
	Environment.os = Shared.Os
	Environment.task = Shared.Task
	Environment.typeof = MockTypeof
	--> Lune has no global `Vector3`, so until this was passed in no spec could run a vector's
	--> serialiser at all -- the magnitude assert was emitted and never executed.
	Environment.Vector3 = roblox.Vector3
	--> Likewise `CFrame`: every CFrame serialiser was emitted and none had ever run.
	Environment.CFrame = roblox.CFrame

	--> Records what the module warns about before passing it on, so a spec can assert on it. The
	--> generated code reports several things through `warn` and nothing else, and none of that was
	--> checkable before.
	Environment.warn = function(...)
		table.insert(Shared.Warnings, table.concat({ ... }, " "))
		warn(...)
	end
	Environment.require = function()
		error("require is not supported")
	end

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

--> The SERVER first, and the order matters now that the client checks the schema signature the
--> server publishes on the remote. In a game that ordering is not a choice: the server creates the
--> remotes and the client's WaitForChild does not return until it has. Here the mock remotes are
--> plain tables that exist from the start, so the order has to be stated.
local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

return {
	Client = Client,
	Server = Server,

	--> Exposed because a spec that wants a module under different globals -- edit mode, say -- has
	--> to load its own copy rather than reuse the pair above.
	MockRequire = MockRequire,
}
