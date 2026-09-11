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
local task = require("@lune/task")

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
	Environment.task = task
	Environment.typeof = MockTypeof
	Environment.require = function()
		error("require is not supported")
	end

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

return {
	Client = Client,
	Server = Server,

	--> Exposed because a spec that wants a module under different globals -- edit mode, say -- has
	--> to load its own copy rather than reuse the pair above.
	MockRequire = MockRequire,
}
