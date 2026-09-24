--!strict
--- Specs for the one-byte event index: each channel holds 256 declarations and not one more.
---
--- A 257th used to compile and go out with the first one's index, so the receiver decoded it as that
--- event. The limit is per channel -- reliable events and functions share one, unreliable events of
--- both kinds the other -- and counts what the generator numbers: imported declarations included,
--- profile-excluded ones not.
local Attributes = require("@compiler/Modules/Attributes")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

--> Scratch space for the import specs; test/Network is ignored by git.
local SCRATCH = "./Network/Channels/"

local function Parse(Source: string, Profile: string?, Directory: string?)
	return Parser.new(Directory, nil, nil, Attributes.new(Profile)):Parse(Source)
end

--- `Count` declarations named `{Prefix}1..`, each on the channel `Kind` picks.
local function Declarations(Prefix: string, Count: number, Kind: "Reliable" | "Unreliable" | "Function"): string
	local Lines: { string } = {}
	for Index = 1, Count do
		local Name = `{Prefix}{Index}`
		if Kind == "Function" then
			table.insert(Lines, `function {Name} \{ Yield: Coroutine, Data: u8, Return: u8 }`)
		else
			table.insert(Lines, `event {Name} \{ From: Client, Type: {Kind}, Call: SingleSync, Data: u8 }`)
		end
	end

	return table.concat(Lines, "\n") .. "\n"
end

local function ExpectCompiles(Name: string, Source: string, Check: ((Server: string) -> string?)?)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Success, Result = pcall(function()
		local Tree = Parse(Source)
		local Server = Generator.Generate("Server", Tree)
		luau.compile(Server)
		luau.compile(Generator.Generate("Client", Tree))
		return if Check then Check(Server) else nil
	end)

	if not Success then
		ErrorPrint(`Failed "{Name}": the schema did not compile: {Result}`)
	elseif Result then
		ErrorPrint(`Failed "{Name}": {Result}`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function ExpectRefusal(Name: string, Source: string, Label: string, Profile: string?, Directory: string?)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Success, Thrown = pcall(Parse, Source, Profile, Directory)
	local Text = tostring(Thrown)
	if Success then
		ErrorPrint(`Failed "{Name}": the schema compiled, expected E3030.`)
	elseif not string.find(Text, "[E3030]", 1, true) then
		ErrorPrint(`Failed "{Name}": expected E3030, got "{Text}" instead.`)
	elseif not string.find(Text, Label, 1, true) then
		ErrorPrint(`Failed "{Name}": expected the diagnostic to say "{Label}", got "{Text}".`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

---- The boundary ----

--> Both channels full at once, and the reliable one filled by events and functions together: the
--> last of each must still get an index of its own.
ExpectCompiles(
	"Each channel holds exactly 256",
	Declarations("R", 200, "Reliable") .. Declarations("F", 56, "Function") .. Declarations("U", 256, "Unreliable"),
	function(Server: string): string?
		if not string.find(Server, `EventNames.Reliable[255] = "F56"`, 1, true) then
			return "the 256th reliable declaration was not given index 255"
		elseif not string.find(Server, `EventNames.Unreliable[255] = "U256"`, 1, true) then
			return "the 256th unreliable event was not given index 255"
		elseif string.find(Server, "EventNames.Reliable[256]", 1, true) then
			return "an index past one byte was emitted"
		end

		return nil
	end
)

ExpectRefusal(
	"A 257th reliable event is refused",
	Declarations("R", 257, "Reliable"),
	"This is number 257 on its channel"
)

ExpectRefusal(
	"Functions share the reliable channel's count",
	Declarations("R", 200, "Reliable") .. Declarations("F", 57, "Function"),
	"Too many reliable events and functions"
)

ExpectRefusal(
	"A 257th unreliable event is refused",
	Declarations("U", 256, "Unreliable")
		.. `event Late \{ From: Client, Type: OrderedUnreliable, Call: SingleSync, Data: u8 }\n`,
	"Too many unreliable events"
)

ExpectRefusal(
	"Declarations inside a scope count",
	Declarations("R", 200, "Reliable") .. `scope Inner \{\n{Declarations("S", 57, "Reliable")}}\n`,
	"This is number 257 on its channel"
)

---- What counts ----

--> An excluded declaration is never generated, so it takes no index: a release build of a schema
--> with dev-only events past the limit is a schema that fits.
ExpectCompiles(
	"A declaration left out by its profile takes no index",
	Declarations("R", 256, "Reliable")
		.. `@profile("dev")\nevent Debug \{ From: Client, Type: Reliable, Call: SingleSync, Data: u8 }\n`
)

ExpectRefusal(
	"The same schema under the profile that keeps it is refused",
	Declarations("R", 256, "Reliable")
		.. `@profile("dev")\nevent Debug \{ From: Client, Type: Reliable, Call: SingleSync, Data: u8 }\n`,
	"Too many reliable events and functions",
	"dev"
)

--> An import takes indices like anything written in the file, and the file that imports it has no
--> span inside it -- so an overflow that lands inside it is pinned on the import itself.
do
	if not fs.isDir(SCRATCH) then
		fs.writeDir(SCRATCH)
	end
	fs.writeFile(`{SCRATCH}Imported.blink`, Declarations("I", 100, "Reliable"))

	ExpectRefusal(
		"An import that brings a channel past 256 is refused at the import",
		`{Declarations("R", 157, "Reliable")}import "./Imported"\n`,
		"This import brings the channel past 256",
		nil,
		SCRATCH
	)

	fs.removeDir(SCRATCH)
end
