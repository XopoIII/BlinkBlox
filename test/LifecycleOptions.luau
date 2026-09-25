--!strict
--- The compile-time half of test/Lifecycle.luau: what `ClientConnectTimeout` and `AutoStart` accept,
--- the member names they take from a schema, their TypeScript declarations, and `@profile`.
local Assertions = require("./Assertions")
local Attributes = require("@compiler/Modules/Attributes")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Parser = require("@compiler/Parser")

local RunClosure = Assertions.RunClosure

local EVENT = "event Ping { From: Client, Type: Reliable, Call: SingleSync, Rate: 10, Data: u8 }"

local function Parse(Source: string, Profile: string?): any
	return Parser.new(nil, nil, nil, Attributes.new(Profile)):Parse(Source)
end

--- Parses `Source` and expects it refused with `Code`, and with `Label` somewhere in what it says.
local function Refused(Source: string, Code: string, Label: string)
	local Success, Thrown = pcall(Parse, Source)
	if Success then
		error(`compiled, expected {Code}:\n{Source}`, 2)
	end

	local Text = tostring(Thrown)
	if not string.find(Text, `[{Code}]`, 1, true) or not string.find(Text, Label, 1, true) then
		error(`expected {Code} saying "{Label}", got:\n{Text}`, 2)
	end
end

RunClosure("ClientConnectTimeout takes a positive number of seconds and nothing else", function()
	for _, Value in { "0", "-1", "-0.5", "0.0" } do
		Refused(`option ClientConnectTimeout = {Value}\n{EVENT}`, "E2003", "Expected a positive number of seconds")
	end

	Refused(`option ClientConnectTimeout = "10"\n{EVENT}`, "E2002", `Expected "Number"`)
	Refused(`option ClientConnectTimeout = true\n{EVENT}`, "E2002", `Expected "Number"`)

	for Value, Expected in { ["0.5"] = 0.5, ["10"] = 10, ["0.05"] = 0.05 } do
		local Options = Parse(`option ClientConnectTimeout = {Value}\n{EVENT}`).Value.Options
		if Options.ClientConnectTimeout ~= Expected then
			error(`{Value} parsed as {Options.ClientConnectTimeout}`)
		end
	end
end)

RunClosure("AutoStart takes a boolean and nothing else", function()
	Refused(`option AutoStart = 0\n{EVENT}`, "E2002", `Expected "Boolean"`)
	Refused(`option AutoStart = "false"\n{EVENT}`, "E2002", `Expected "Boolean"`)

	local Off = Parse(`option AutoStart = false\n{EVENT}`).Value.Options
	local On = Parse(`option AutoStart = true\n{EVENT}`).Value.Options
	local Absent = Parse(EVENT).Value.Options
	if Off.AutoStart ~= false or On.AutoStart ~= true or Absent.AutoStart ~= nil then
		error(`parsed as {Off.AutoStart}, {On.AutoStart}, {Absent.AutoStart}`)
	end
end)

RunClosure("The lifecycle members are refused as declaration names where they exist", function()
	local function Event(Name: string): string
		return `event {Name} \{ From: Client, Type: Reliable, Call: SingleSync, Rate: 10, Data: u8 }`
	end

	Refused(Event("Remotes"), "E3005", `"Remotes" is the module's Remotes`)
	Refused(`option AutoStart = false\n{Event("Start")}`, "E3005", `"Start" is the module's Start`)
	Refused(`option ClientConnectTimeout = 1\n{Event("Connected")}`, "E3005", `"Connected" is the module's Connected`)
	Refused(`option Casing = Camel\n{Event("remotes")}`, "E3005", `"remotes" is the module's Remotes`)
	Refused(`option Casing = Snake\noption AutoStart = false\nscope start \{ {EVENT} }`, "E3005", "Start")

	--> Only where the option makes them members, and only for what becomes a key of the module.
	Parse(Event("Start"))
	Parse(Event("Connected"))
	Parse(`option AutoStart = true\n{Event("Start")}`)
	Parse(`struct Remotes \{ Value: u8 }\n{EVENT}`)
end)

RunClosure("@profile gates the lifecycle options like any other", function()
	local Source =
		`@profile("test")\noption AutoStart = false\n@profile("test")\noption ClientConnectTimeout = 2\n{EVENT}`
	local Showroom = Parse(Source, "test").Value.Options
	local Release = Parse(Source, "release").Value.Options
	if Showroom.AutoStart ~= false or Showroom.ClientConnectTimeout ~= 2 then
		error(`the test build got {Showroom.AutoStart}, {Showroom.ClientConnectTimeout}`)
	end
	if Release.AutoStart ~= nil or Release.ClientConnectTimeout ~= nil then
		error(`the release build got {Release.AutoStart}, {Release.ClientConnectTimeout}`)
	end
end)

RunClosure("The TypeScript declarations carry the lifecycle members where they exist", function()
	local REMOTES = ": { readonly Reliable: string; readonly Unreliable: string }\n"
	local Cases = {
		{ Options = "", Context = "Server", Has = { "Remotes" }, Lacks = { "Start", "Connected" } },
		{ Options = "", Context = "Client", Has = { "Remotes" }, Lacks = { "Start", "Connected" } },
		{
			Options = "option AutoStart = false\noption ClientConnectTimeout = 1",
			Context = "Server",
			Has = { "Remotes", "Start" },
			Lacks = { "Connected" },
		},
		{
			Options = "option AutoStart = false\noption ClientConnectTimeout = 1",
			Context = "Client",
			Has = { "Remotes", "Connected" },
			Lacks = { "Start" },
		},
		{
			Options = "option Casing = Snake\noption AutoStart = false",
			Context = "Server",
			Has = { "remotes", "start" },
			Lacks = { "Start" },
		},
	}

	local Lines = {
		Remotes = REMOTES,
		remotes = REMOTES,
		Start = ": () => void\n",
		start = ": () => void\n",
		Connected = ": boolean\n",
	}

	for _, Case in Cases do
		local Declaration = Generator.GenerateTypescript(Case.Context :: any, Isolated.Parse(`{Case.Options}\n{EVENT}`))
		for _, Name in Case.Has do
			if not string.find(Declaration, `export declare const {Name}{Lines[Name]}`, 1, true) then
				error(`the {Case.Context} declaration under "{Case.Options}" lacks {Name}:\n{Declaration}`)
			end
		end
		for _, Name in Case.Lacks do
			if string.find(Declaration, `export declare const {Name}:`, 1, true) then
				error(`the {Case.Context} declaration under "{Case.Options}" declares {Name}`)
			end
		end
	end
end)

return {}
