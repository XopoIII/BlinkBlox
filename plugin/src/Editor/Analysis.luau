--!strict
--- Parsing what is typed into the editor, and deciding which diagnostic it shows: the error of a
--- parse that failed, the first warning of one that succeeded, or none.
local Error = require("@compiler/Modules/Error")
local Parser = require("@compiler/Parser")

local Analysis = {}
Analysis.__index = Analysis

export type Analysis = typeof(setmetatable(
	{} :: {
		Parser: Parser.Parser,
		Report: (Diagnostic: Error.Class?) -> (),
		--- Set while `Run` parses, so a warning raised then is held rather than reported.
		Running: boolean,
		--- The first warning of the parse under way. Held until it ends, since a parse that goes
		--- on to fail replaces it with the error.
		Warning: Error.Class?,
	},
	Analysis
))

--- `Report` receives the diagnostic to show, or nil to clear it.
function Analysis.new(Report: (Diagnostic: Error.Class?) -> ()): Analysis
	return setmetatable({
		Parser = Parser.new(),
		Report = Report,
		Running = false,
		Warning = nil,
	}, Analysis)
end

--- Parses `Source`, returning its tree when it parses.
---
--- A failure has already been reported through `Emitted`. A success reports its first warning, or
--- clears what was shown. It used to clear it unconditionally, and Error.Warn reports through the
--- same hook as an error does, so every warning was set and then erased by the same parse: none was
--- ever shown in the editor, while each was printed to Output on every keystroke.
function Analysis.Run(self: Analysis, Source: string): Parser.Body?
	self.Warning = nil
	self.Running = true
	local Success, Result = pcall(function()
		return self.Parser:Parse(Source)
	end)
	self.Running = false

	if not Success then
		return nil
	end

	self.Report(self.Warning)
	return Result
end

--- The handler for Error.OnEmit. Returns true for a warning it holds, which is then not printed:
--- it is shown in the editor, and printed as well it would reach Output once per keystroke.
function Analysis.Emitted(self: Analysis, Diagnostic: Error.Class): boolean?
	if self.Running and Diagnostic.Severity == "Warning" then
		self.Warning = self.Warning or Diagnostic
		return true
	end

	self.Report(Diagnostic)
	return nil
end

return Analysis
