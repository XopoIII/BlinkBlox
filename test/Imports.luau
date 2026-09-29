--!strict
--- Specs for the warning on a file imported more than once (W3036). The CLI case -- the warning is
--- printed and the build still succeeds -- is Sources/Invalid/RepeatedImport.blink; these cover
--- what that cannot: when it must NOT fire.
local Assertions = require("./Assertions")
local Attributes = require("@compiler/Modules/Attributes")
local Error = require("@compiler/Modules/Error")
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local DIRECTORY = "./Sources/Invalid/"
local REPEATED = 3036

--- The codes of the warnings `Parse` raises.
local function Warnings(Parse: () -> ()): { number }
	local Codes = {}
	local Previous = Error.OnEmit
	Error.OnEmit = function(Diagnostic)
		if Diagnostic.Severity == "Warning" then
			table.insert(Codes, Diagnostic.Code)
			return true
		end

		return nil
	end

	local Success, Failure = pcall(Parse)
	Error.OnEmit = Previous
	if not Success then
		error(Failure, 0)
	end

	return Codes
end

local function Count(Codes: { number }, Code: number): number
	local Found = 0
	for _, Each in Codes do
		if Each == Code then
			Found += 1
		end
	end

	return Found
end

RunClosure("A file of events imported twice warns once, at the second import", function()
	local Codes = Warnings(function()
		Parser.new(DIRECTORY, nil, nil, Attributes.new(nil)):Parse(table.concat({
			'import "./Imported/Pinged.blink"',
			'import "./Imported/Pinged.blink" as Again',
		}, "\n"))
	end)

	if Count(Codes, REPEATED) ~= 1 then
		ErrorPrint(`Expected one W{REPEATED}, got {Count(Codes, REPEATED)}.`)
	end
end)

RunClosure("A file of types imported twice does not warn", function()
	local Codes = Warnings(function()
		Parser.new(DIRECTORY, nil, nil, Attributes.new(nil)):Parse(table.concat({
			'import "./Imported/Shapes.blink"',
			'import "./Imported/Shapes.blink" as Again',
		}, "\n"))
	end)

	if Count(Codes, REPEATED) ~= 0 then
		ErrorPrint(`A types-only file warned W{REPEATED} on a second import.`)
	end
end)

--> The plugin's editor keeps one parser and parses on every pause in typing. What the previous parse
--> imported must not count against this one.
RunClosure("Parsing again with the same parser does not warn about the last parse's imports", function()
	local Reused = Parser.new(DIRECTORY, nil, nil, Attributes.new(nil))
	local Codes = Warnings(function()
		Reused:Parse('import "./Imported/Pinged.blink"')
		Reused:Parse('import "./Imported/Pinged.blink"')
	end)

	if Count(Codes, REPEATED) ~= 0 then
		ErrorPrint(`A reused parser warned W{REPEATED} for an import made once per parse.`)
	end
end)
