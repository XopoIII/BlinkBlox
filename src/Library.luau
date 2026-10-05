--!strict
--- The compiler as a library: a schema's text in, the generated modules' text out.
---
--- For code that runs the compiler inside Roblox -- a plugin, an editor, a build step in Studio --
--- rather than from the command line. It is the entry the Wally package exposes, and the same lexer,
--- parser and generator the CLI and the Studio plugin run.
local Attributes = require("./Modules/Attributes")
local Error = require("./Modules/Error")
local Generator = require("./Generator")
local OutputSize = require("./Modules/OutputSize")
local Parser = require("./Parser")
local Source = require("./Modules/Source")
local Version = require("./Modules/Version")

export type Options = {
	--- The `@profile` to compile under: "dev", "debug", "test" or "release" (the default).
	Profile: string?,
	--- The schemas an `import` may name, keyed by the path it writes: `import "Shared"` reads
	--- `Files.Shared`. Without it an import is read from ServerStorage.BLINK_CONFIGURATION_FILES
	--- inside Roblox, or from disk on Lune.
	Files: { [string]: string }?,
}

export type Output = {
	Server: string,
	Client: string,
	--- The module of exported types and their Read and Write functions.
	Types: string,
	--- Each warning the compile raised, rendered as the CLI prints it.
	Warnings: { string },
}

local Library = {}

--- The version of BlinkBlox that generates, as the modules' headers name it.
Library.VERSION = Version

--- Compiles `Schema`. A schema that does not compile raises its diagnostic, rendered as the CLI
--- prints it; warnings are returned rather than printed.
function Library.Compile(Schema: string, Options: Options?): Output
	local Given: Options = Options or {}
	local Profile = Given.Profile
	if Profile ~= nil and not Attributes.IsProfile(Profile) then
		error(`Unknown profile "{Profile}": expected dev, debug, test or release.`, 2)
	end

	local Warnings: { string } = {}
	local PreviousEmit = Error.OnEmit
	local PreviousFiles = Source.Files
	Error.OnEmit = function(Diagnostic)
		if Diagnostic.Severity == "Warning" then
			table.insert(Warnings, Diagnostic.Message)
			return true
		end

		return nil
	end
	Source.Files = Given.Files

	local Success, Result = pcall(function(): Output
		local Tree = Parser.new(nil, nil, nil, Attributes.new(Profile)):Parse(Schema)
		return {
			Server = Generator.Generate("Server", Tree),
			Client = Generator.Generate("Client", Tree),
			Types = Generator.GenerateShared(Tree),
			Warnings = Warnings,
		}
	end)

	Error.OnEmit = PreviousEmit
	Source.Files = PreviousFiles
	if not Success then
		error(Result, 0)
	end

	for _, Module in { { "server", Result.Server }, { "client", Result.Client } } do
		local Warning = OutputSize.Warning(Module[1], Module[2])
		if Warning then
			table.insert(Warnings, Warning)
		end
	end

	return Result
end

return Library
