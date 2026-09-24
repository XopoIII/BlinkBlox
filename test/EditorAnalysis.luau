--!strict
--- Specs for which diagnostic the plugin editor shows as a schema is typed.
---
--- Editor/Analysis.luau parses through the compiler and reports through Error.OnEmit, both of which
--- run on Lune, so it is checked here rather than only by typing in Studio.
local Analysis = require("@compiler/../plugin/src/Editor/Analysis")
local Assertions = require("./Assertions")
local Error = require("@compiler/Modules/Error")
local Harness = require("./Harness")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--> An unbounded string on an unreliable event parses, with a warning that it may not fit.
local WARNS = [[
event Chat {
    From: Client,
    Type: Unreliable,
    Call: SingleSync,
    Data: string,
}
]]

local CLEAN = "type Byte = u8"
local BROKEN = "type = u8"

RunClosure("The editor shows a warning, and an error over it, and clears both", function()
	--> What the editor is showing: a table of reports would not hold the nil that clears it.
	local Shown: Error.Class? = nil
	local Editor = Analysis.new(function(Diagnostic)
		Shown = Diagnostic
	end)

	local Previous = Error.OnEmit
	Error.OnEmit = function(Diagnostic)
		return Editor:Emitted(Diagnostic)
	end

	local function Last(): Error.Class?
		return Shown
	end

	--> A warning used to be reported and then cleared by the same successful parse.
	local Tree = Editor:Run(WARNS)
	local Warned = Last()
	if not Tree or not Warned or Warned.Severity ~= "Warning" then
		ErrorPrint(
			`Failed "Editor warnings": a parse with a warning showed {if Warned then Warned.Severity else "nothing"}.`
		)
	end

	--> A parse that fails shows its error, not a warning held from before it.
	if Editor:Run(BROKEN) ~= nil or not Last() or (Last() :: Error.Class).Severity ~= "Error" then
		ErrorPrint(`Failed "Editor warnings": a failed parse did not show its error.`)
	end

	if not Editor:Run(CLEAN) or Last() ~= nil then
		ErrorPrint(`Failed "Editor warnings": a clean parse did not clear what was shown.`)
	end

	Error.OnEmit = Previous
end)
