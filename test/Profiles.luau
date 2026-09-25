--!strict
--- Specs for `@profile`: what each profile compiles, and what it refuses.
---
--- These parse source strings directly under a chosen profile. The CLI half -- the flag, and the
--- default a build gets without it -- is in test/CommandLine.luau.
local Attributes = require("@compiler/Modules/Attributes")
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")
local Signature = require("@compiler/Modules/Signature")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local function Parse(Source: string, Profile: string?)
	return Parser.new(nil, nil, nil, Attributes.new(Profile)):Parse(Source)
end

local function Names(Source: string, Profile: string?): string
	local Found: { string } = {}
	for _, Declaration in Parse(Source, Profile).Value.Declarations do
		table.insert(Found, (Declaration :: any).Name)
	end

	table.sort(Found)
	return table.concat(Found, ",")
end

local function ExpectNames(Name: string, Source: string, Profile: string?, Expected: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Success, Result = pcall(Names, Source, Profile)
	if not Success then
		ErrorPrint(`Failed "{Name}": the schema did not compile: {Result}`)
	elseif Result ~= Expected then
		ErrorPrint(`Failed "{Name}": expected declarations "{Expected}", got "{Result}".`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function ExpectRefusal(Name: string, Source: string, Profile: string?, Code: number)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Success, Thrown = pcall(Parse, Source, Profile)
	if Success then
		ErrorPrint(`Failed "{Name}": the schema compiled, expected E{Code}.`)
	elseif not string.find(tostring(Thrown), `[E{Code}]`, 1, true) then
		ErrorPrint(`Failed "{Name}": expected E{Code}, got "{Thrown}" instead.`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function Event(Name: string, Data: string?): string
	local Field = if Data then `,\n    Data: {Data}` else ""
	return `event {Name} \{\n    From: Client,\n    Type: Reliable,\n    Call: SingleSync{Field}\n}\n`
end

local GATED = table.concat({
	`@profile("dev")\nstruct Money \{ Amount: u32 }`,
	`@profile("dev")\n{Event("GiveMoney", "Money")}`,
	Event("Ping", "u8"),
}, "\n")

---- What each profile keeps ----

ExpectNames("A build without a profile leaves dev declarations out", GATED, nil, "Ping")
ExpectNames("The release profile leaves dev declarations out", GATED, "release", "Ping")
ExpectNames("The dev profile keeps them", GATED, "dev", "GiveMoney,Money,Ping")
ExpectNames("A profile other than the one marked leaves them out", GATED, "test", "Ping")

ExpectNames(
	"A scope's profile covers everything inside it",
	`@profile("dev")\nscope Debug \{\n{Event("Pause")}}\n{Event("Ping")}`,
	"release",
	"Ping"
)

--> The option block reads ahead of the declarations, so an attribute in front of the first
--> declaration is read there. It has to survive the hand-over.
ExpectNames(
	"An attribute right after the option block reaches its declaration",
	`option Casing = Camel\n@profile("dev")\n{Event("GiveMoney")}{Event("Ping")}`,
	"release",
	"Ping"
)

---- What each profile applies ----

do
	PrettyPrint("cyan", "Testing: A gated option applies only under its profile...", true)

	local Source = `@profile("dev")\noption WriteValidations = true\n{Event("Ping")}`
	local Release = Parse(Source, "release").Value.Options
	local Dev = Parse(Source, "dev").Value.Options

	if Release.WriteValidations ~= nil or Dev.WriteValidations ~= true then
		ErrorPrint(
			`Failed: expected the option only under dev, got {Release.WriteValidations} and {Dev.WriteValidations}.`
		)
	end

	OkPrint(`Test "A gated option applies only under its profile" passed!`)
end

ExpectNames(
	"One option may be set once per profile",
	`@profile("dev")\noption MaxPacketSize = 4096\n@profile("release")\noption MaxPacketSize = 1024\n{Event("Ping")}`,
	"dev",
	"Ping"
)

---- What is refused, under every profile ----

--> Refused whichever profile is active: a schema that compiled under one and not the other would be
--> found broken by whoever ran the other build.
for _, Profile in { "release", "dev" } do
	ExpectRefusal(
		`An option set with and without a profile clashes (under {Profile})`,
		`option MaxPacketSize = 4096\n@profile("dev")\noption MaxPacketSize = 1024\n{Event("Ping")}`,
		Profile,
		3024
	)
end

ExpectRefusal(
	"A compiled declaration cannot name an excluded one",
	`@profile("dev")\nstruct Money \{ Amount: u32 }\n{Event("Ping", "Money")}`,
	"release",
	3027
)

ExpectRefusal("A misspelt profile is refused", `@profile("prod")\n{Event("Ping")}`, "release", 3026)
ExpectRefusal("An unknown attribute is refused", `@deprecated("x")\n{Event("Ping")}`, "release", 3025)
ExpectRefusal("An attribute with nothing after it is refused", `{Event("Ping")}@profile("dev")\n`, "release", 3028)
ExpectRefusal("A statement takes one profile", `@profile("dev")\n@profile("test")\n{Event("Ping")}`, "release", 3028)

---- The signature ----

do
	PrettyPrint("cyan", "Testing: Builds under different profiles refuse each other...", true)

	--> A client built dev and a server built release disagree about which events exist, and must
	--> refuse each other at startup rather than decode one event as another.
	local Dev = Signature.Of(Parse(GATED, "dev"))
	local Release = Signature.Of(Parse(GATED, "release"))
	if Dev == Release then
		ErrorPrint(`Failed: the dev and release builds both signed as {Dev}.`)
	end

	--> And a schema with no attributes must sign the same under every profile, or the flag would cry
	--> wolf on every game that never used it.
	local Plain = Event("Ping", "u8")
	if Signature.Of(Parse(Plain, "dev")) ~= Signature.Of(Parse(Plain, "release")) then
		ErrorPrint("Failed: a schema without attributes signed differently under two profiles.")
	end

	OkPrint(`Test "Builds under different profiles refuse each other" passed!`)
end

---- A parser used again ----

--> The plugin's editor keeps one parser for the document and parses it again on every change. What
--> the attributes of one parse leave behind must not reach the next.
do
	PrettyPrint("cyan", "Testing: A parser used again forgets the excluded declarations...", true)

	--> Each excluded declaration holds the tree it came from, so a record that outlived its parse
	--> kept every earlier tree alive.
	local Reused = Parser.new(nil, nil, nil, Attributes.new("release"))
	for _ = 1, 3 do
		Reused:Parse(GATED)
	end

	local Kept = 0
	for _ in Reused.Attributes.Excluded do
		Kept += 1
	end

	if Kept ~= 2 then
		ErrorPrint(`Failed: three parses of two excluded declarations left {Kept} recorded.`)
	end

	OkPrint(`Test "A parser used again forgets the excluded declarations" passed!`)
end

do
	PrettyPrint("cyan", "Testing: A parse that failed inside an attribute does not carry it over...", true)

	--> Half-typed, as an editor sees a document mid-keystroke: the attribute has opened its
	--> statement and the statement never closes.
	local Reused = Parser.new(nil, nil, nil, Attributes.new("release"))
	local Failed = pcall(function()
		Reused:Parse(`@profile("dev")\nevent Broken \{\n    From: Client,\n`)
	end)

	local Success, Tree = pcall(function()
		return Reused:Parse(Event("Ping", "u8"))
	end)

	local Found = if Success then #Tree.Value.Declarations else -1
	if Failed then
		ErrorPrint("Failed: the half-typed schema parsed.")
	elseif Found ~= 1 then
		ErrorPrint(`Failed: the next parse compiled {Found} declaration(s), expected the one it holds.`)
	end

	OkPrint(`Test "A parse that failed inside an attribute does not carry it over" passed!`)
end
