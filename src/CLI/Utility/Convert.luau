--!strict
--- `--from <tool>`: another tool's definitions in, a draft schema out.
---
--- The draft is written beside the definitions, under their name with `.blink` for an extension, and
--- what its reader still has to decide is printed after it. Nothing here asks a question: a draft
--- that would replace a file is refused unless `--yes` was given, so a script never waits on a prompt
--- no one can answer.

---- Imports ----

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local ByteNet = require("../../Convert/Stubs/ByteNet")
local Draft = require("../../Convert/Draft")
local Library = require("../../Library")
local Packet = require("../../Convert/Stubs/Packet")
local PathParser = require("../../Modules/Path")
local Print = require("../../Convert/Print")
local Sandbox = require("./Sandbox")
local Zap = require("../../Convert/Zap")

---- Settings ----

export type ConvertOptions = {
	Silent: boolean,
	YesToEverything: boolean,
	--> Print the draft on standard output and write nothing: `--check`.
	Check: boolean?,
}

type Tool = {
	--- The tool as its users write it, and the version the converter reads.
	Name: string,
	Version: string,
	--- Reads the definitions at a path. A config is parsed; a Luau module is run against a stub.
	Read: (Path: string) -> Draft.Draft,
}

---- Constants ----

local Utility = {}

--- Keyed by what follows `--from`.
local TOOLS: { [string]: Tool } = {
	zap = {
		Name = "zap",
		Version = Zap.VERSION,
		Read = function(Path)
			return Zap.Parse(fs.readFile(Path))
		end,
	},
	bytenet = {
		Name = ByteNet.NAME,
		Version = ByteNet.VERSION,
		Read = function(Path)
			return Sandbox.Record(Path, ByteNet)
		end,
	},
	packet = {
		Name = Packet.NAME,
		Version = Packet.VERSION,
		Read = function(Path)
			return Sandbox.Record(Path, Packet)
		end,
	},
}

---- Private Functions ----

local function Coloured(Color: stdio.Color, Text: string): string
	return `{stdio.color(Color)}{Text}{stdio.color("reset")}`
end

local function Refuse(Text: string): never
	stdio.ewrite(`{Coloured("red", Text)}\n`)
	return process.exit(1)
end

local function Known(): string
	local Names: { string } = {}
	for Name in TOOLS do
		table.insert(Names, Name)
	end

	table.sort(Names)
	return table.concat(Names, ", ")
end

--- Compiles the draft with the compiler itself: a draft that does not compile is the converter's
--- bug, and is said to be one instead of being left for its reader to find.
local function Compiles(Text: string): (boolean, { string })
	local Success, Result = pcall(Library.Compile, Text)
	if not Success then
		return false, { tostring(Result) }
	end

	return true, Result.Warnings
end

---- Public Functions ----

--- Whether `Name` is a tool `--from` reads, and the list of those that are.
function Utility.IsTool(Name: string?): (boolean, string)
	return Name ~= nil and TOOLS[string.lower(Name)] ~= nil, Known()
end

function Utility.Convert(ToolName: string, Path: string, Options: ConvertOptions)
	local Tool = TOOLS[string.lower(ToolName)]
	if not fs.isFile(Path) then
		Refuse(`No definitions at "{Path}".`)
	end

	local Read, Result = pcall(Tool.Read, Path)
	if not Read then
		Refuse(`{Path} could not be read as {Tool.Name} {Tool.Version} definitions: {Result}`)
	end

	local Text, Checklist = Print.Render(Result)
	local Compiled, Remarks = Compiles(Text)

	local Directory, Filename = PathParser.Components(Path)
	local Output = `{Directory or ""}{Filename or "Converted"}.blink`

	if Options.Check then
		--> Written, not printed: the draft ends in its own newline, and a second is not the draft.
		stdio.write(Text)
	else
		if fs.isFile(Output) and not Options.YesToEverything then
			Refuse(`{Output} already exists; pass --yes to replace it, or move it aside.`)
		end

		fs.writeFile(Output, Text)
	end

	if not Compiled then
		Refuse(
			"The draft does not compile. That is a fault in the converter: please report it, with the definitions.\n"
				.. Remarks[1]
		)
	end

	if Options.Silent then
		return
	end

	--> Under `--check` standard output is the draft and nothing else, so it can be piped to a file.
	local function Say(Line: string)
		if Options.Check then
			stdio.ewrite(`{Line}\n`)
		else
			print(Line)
		end
	end

	if not Options.Check then
		Say(Coloured("green", `Draft written to {PathParser.Normalise(Output)}.`))
	end

	Say(Coloured("yellow", "Before it is used:"))
	for _, Item in Checklist do
		Say(`  - {Item}`)
	end

	if #Remarks > 0 then
		Say(Coloured("yellow", "The compiler warns about the draft:"))
		for _, Warning in Remarks do
			Say(Warning)
		end
	end
end

---- Initialization ----

---- Connections ----

return Utility
