--!strict
--- The end-to-end half of the schema signature: a client built from one schema, required against a
--- server built from another, has to refuse rather than decode.
---
--- Drift.blink and DriftStale.blink differ by one event declared ahead of the other, which is the
--- ordinary consequence of adding an event and recompiling one side. `Alpha` is index 1 in one and
--- index 0 in the other; nothing else about them differs, and both are perfectly valid schemas.
---
--- Without the check the mismatched pair loads cleanly and then misbehaves quietly, which is what
--- several devforum reports were: `invalid argument #3 to 'writeu8'`, or a listener firing with data
--- belonging to some other event.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")

local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local MockRequire = Modules.MockRequire

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local function LoadServer(Path: string)
	return MockRequire(Path, {
		game = ServerEnvironment.game,
		Color3 = ServerEnvironment.Color3,
		DateTime = ServerEnvironment.DateTime,
		BrickColor = ServerEnvironment.BrickColor,
	})
end

local function LoadClient(Path: string)
	return MockRequire(Path, {
		game = ClientEnvironment.game,
		Color3 = ClientEnvironment.Color3,
		DateTime = ClientEnvironment.DateTime,
		BrickColor = ClientEnvironment.BrickColor,
	})
end

--> Each pair writes the signature onto the same mock remote, so the store has to be cleared between
--> them or the previous server's value would answer for the next.
local function ClearSignature()
	Shared.Attributes.BLINK_RELIABLE_REMOTE = {}
end

do
	local Name = "A matching pair loads"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	ClearSignature()
	LoadServer("../Network/DriftServer.luau")

	local Loaded, Thrown = pcall(LoadClient, "../Network/DriftClient.luau")
	if not Loaded then
		ErrorPrint(`Failed "{Name}": a client and server from the SAME schema refused each other: {Thrown}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> The assertion. Without the signature check this pcall succeeds, and the stale client then
	--> decodes index 1 as an event that no longer lives there.
	local Name = "A client built from a different schema refuses to load"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	ClearSignature()
	LoadServer("../Network/DriftServer.luau")

	local Loaded, Thrown = pcall(LoadClient, "../Network/DriftStaleClient.luau")
	if Loaded then
		ErrorPrint(`Failed "{Name}": the mismatched client loaded, and would have decoded the wrong events.`)
		return {}
	end

	local Message = tostring(Thrown)
	if not string.find(Message, "different schema", 1, true) then
		ErrorPrint(`Failed "{Name}": it refused, but not for this reason: {Message}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> A server that never wrote the attribute -- one built before this check existed. The client has
	--> to say which of the two problems it is, because "no signature" and "wrong signature" call for
	--> completely different fixes.
	local Name = "A server that publishes no signature is reported as such"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	ClearSignature()

	local Loaded, Thrown = pcall(LoadClient, "../Network/DriftClient.luau")
	if Loaded then
		ErrorPrint(`Failed "{Name}": the client accepted a server that published nothing.`)
		return {}
	end

	local Message = tostring(Thrown)
	if not string.find(Message, "did not publish", 1, true) then
		ErrorPrint(`Failed "{Name}": it refused, but not for this reason: {Message}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

--> Put the real pair's signature back, since the specs above have been overwriting the store that
--> the modules loaded by Modules.luau share.
ClearSignature()
LoadServer("../Network/Server.luau")

return {}
