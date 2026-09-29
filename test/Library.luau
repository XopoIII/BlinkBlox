--!strict
--- Specs for src/Library.luau, the entry the Wally package exposes: a schema's text in, the modules'
--- text out, warnings returned rather than printed, imports read from the files it is handed.
local Assertions = require("./Assertions")
local Error = require("@compiler/Modules/Error")
local Harness = require("./Harness")
local Library = require("@compiler/Library")
local Source = require("@compiler/Modules/Source")
local luau = require("@lune/luau")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

local SCHEMA = [[
import "Shared"
event Chat {
    From: Client,
    Type: Unreliable,
    Call: SingleSync,
    Rate: 5,
    Data: string
}
event Place {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: Shared.Point
}
]]

RunClosure("Library.Compile returns three modules that load, and its warnings", function()
	local Hook = Error.OnEmit
	local Output = Library.Compile(SCHEMA, { Files = { Shared = "export type Point = Vector2" } })

	for _, Name in { "Server", "Client", "Types" } do
		local Text = (Output :: any)[Name] :: string
		Check(Name, #Text > 0, "empty")
		Check(Name, (pcall(luau.compile, Text)), "does not compile as Luau")
	end

	--> An unbounded string on an unreliable event may not fit.
	Check("Warnings", #Output.Warnings == 1, `{#Output.Warnings} warnings`)
	Check("Hooks", Error.OnEmit == Hook and Source.Files == nil, "a global hook was left behind")
end)

RunClosure("Library.Compile raises a schema's error and leaves no hook behind", function()
	local Hook = Error.OnEmit
	local Success, Failure = pcall(Library.Compile, "type = u8")
	Check("Error", not Success, "a broken schema compiled")
	Check("Error", string.find(tostring(Failure), "E", 1, true) ~= nil, `raised "{Failure}"`)
	Check("Hooks", Error.OnEmit == Hook and Source.Files == nil, "a global hook was left behind")

	local Profiled = pcall(Library.Compile, "type Byte = u8", { Profile = "beta" })
	Check("Profile", not Profiled, "an unknown profile was taken")
end)
