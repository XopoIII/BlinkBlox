--!strict
--- Specs for `option ExportLimits` -- the schema's bounds as a table the game reads -- and for what
--- else a number's modifiers reach: the schema signature, and the diagnostics for a bad modifier.
---
--- The limits are read from all three modules a schema compiles to, and each is compared with the
--- number the schema below writes, not with anything the compiler worked out.
local Assertions = require("./Assertions")
local Error = require("@compiler/Modules/Error")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local Parser = require("@compiler/Parser")
local Signature = require("@compiler/Modules/Signature")
local luau = require("@lune/luau")

local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option ExportLimits = true

struct CrawlHead { Id: u8, Back: boolean }
struct CrawlPacket { At: u16, Heads: CrawlHead[..16] }
struct Tally {
	Count: u8<saturate>(1..255),
	Name: string(3..20),
	Frame: u16<0.1, saturate>,
	["Odd Key"]: i8(-3..3),
}

event Crawls { From: Server, Type: Reliable, Call: SingleSync, Data: CrawlPacket }
event Pair { From: Client, Type: Reliable, Call: SingleSync, Data: (Code: u8(0..9), f32(-1..1)) }
function Ask { Yield: Coroutine, Data: u8(1..5), Return: string(..8) }

scope Inner {
	type Aim = f32(-0.5..0.5)
}

type Loose = f32(0..)
type Plain = u8
type Heading = vector(0..1)
map Scores = { [string(..4)]: u16(..999) }
enum Choice = "Kind" { One { Level: u8(1..3) }, Two {} }
]]

--- `Path` read from `Limits`, one key at a time, or nil where the path stops.
local function At(Limits: any, ...: string | number): any
	local Current = Limits
	for _, Key in { ... } do
		if type(Current) ~= "table" then
			return nil
		end
		Current = Current[Key]
	end
	return Current
end

local function Check(Label: string, Limits: any, Casing: "Pascal" | "Snake")
	local function Word(Pascal: string): string
		return if Casing == "Pascal" then Pascal else string.lower(Pascal)
	end
	local Min, Max, Step, Length = Word("Min"), Word("Max"), Word("Step"), Word("Length")

	local Expected: { { Path: { string | number }, Value: any } } = {
		{ Path = { "CrawlPacket", "Heads", Length, Min }, Value = 0 },
		{ Path = { "CrawlPacket", "Heads", Length, Max }, Value = 16 },
		{ Path = { "CrawlPacket", "Heads", Word("Element") }, Value = nil },
		{ Path = { "CrawlPacket", "At" }, Value = nil },
		{ Path = { "Crawls", "Heads", Length, Max }, Value = 16 },
		{ Path = { "Tally", "Count", Min }, Value = 1 },
		{ Path = { "Tally", "Count", Max }, Value = 255 },
		{ Path = { "Tally", "Count", Step }, Value = nil },
		{ Path = { "Tally", "Name", Min }, Value = 3 },
		{ Path = { "Tally", "Name", Max }, Value = 20 },
		{ Path = { "Tally", "Frame", Min }, Value = 0 },
		{ Path = { "Tally", "Frame", Max }, Value = 6553.5 },
		{ Path = { "Tally", "Frame", Step }, Value = 0.1 },
		{ Path = { "Tally", "Odd Key", Min }, Value = -3 },
		{ Path = { "Pair", "Code", Max }, Value = 9 },
		{ Path = { "Pair", 2, Min }, Value = -1 },
		{ Path = { "Pair", 2, Max }, Value = 1 },
		{ Path = { "Ask", "Data", Max }, Value = 5 },
		{ Path = { "Ask", "Return", Min }, Value = 0 },
		{ Path = { "Ask", "Return", Max }, Value = 8 },
		{ Path = { "Inner", "Aim", Min }, Value = -0.5 },
		{ Path = { "Loose", Min }, Value = 0 },
		{ Path = { "Loose", Max }, Value = math.huge },
		{ Path = { "Plain" }, Value = nil },
		{ Path = { "Heading", Max }, Value = 1 },
		{ Path = { "Scores", Word("Key"), Max }, Value = 4 },
		{ Path = { "Scores", Word("Value"), Max }, Value = 999 },
		{ Path = { "Choice", "One", "Level", Max }, Value = 3 },
		{ Path = { "Choice", "Two" }, Value = nil },
	}

	for _, Case in Expected do
		local Got = At(Limits, table.unpack(Case.Path))
		local Where = table.concat(Case.Path :: { any }, ".")
		assert(Got == Case.Value, `{Label}: Limits.{Where} is {Got}, expected {Case.Value}`)
	end

	assert(table.isfrozen(Limits), `{Label}: Limits is not frozen`)
	assert(table.isfrozen(At(Limits, "Tally", "Frame")), `{Label}: Limits.Tally.Frame is not frozen`)

	local Keys = {}
	for Key in Limits do
		table.insert(Keys, Key)
	end
	table.sort(Keys)
	local Listed = table.concat(Keys, ",")
	local Wanted = "Ask,Choice,CrawlPacket,Crawls,Heading,Inner,Loose,Pair,Scores,Tally"
	assert(Listed == Wanted, `{Label}: Limits holds {Listed}, expected {Wanted}`)
end

RunClosure("ExportLimits puts the schema's bounds in the server, client and types modules", function()
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "LIMITS")
	Check("server", Pair.Server.Limits, "Pascal")
	Check("client", Pair.Client.Limits, "Pascal")

	local Shared = (luau.load(Generator.GenerateShared(Parser.new():Parse(SCHEMA))) :: any)()
	Check("types", Shared.Limits, "Pascal")

	--> The edit-mode stub table keeps the member, as it keeps every other.
	local Source = Generator.Generate("Server", Parser.new():Parse(SCHEMA))
	local _, Members = string.gsub(Source, "\n%s*Limits = BLINK_LIMITS,", "")
	assert(Members == 2, `the server module names Limits {Members} times, expected 2 (returned and stubbed)`)
end)

RunClosure("ExportLimits follows option Casing for its structural words", function()
	local Snake = "option Casing = Snake\n" .. SCHEMA
	local Pair = Isolated.Build(Isolated.Parse(Snake), "LIMITS_SNAKE")
	Check("server, snake", Pair.Server.limits, "Snake")
	assert(Pair.Server.Limits == nil, "a snake-cased module also returned Limits")
end)

RunClosure("ExportLimits declares its table in the TypeScript output", function()
	local Declaration = Generator.GenerateTypescript("Client", Parser.new():Parse(SCHEMA))
	for _, Line in
		{
			"export declare const Limits: {",
			'\t\treadonly "Odd Key": {',
			"\t\t\treadonly Step: number;",
			"\t\treadonly 2: {",
		}
	do
		assert(string.find(Declaration, Line, 1, true), `the TypeScript output lacks "{Line}"`)
	end
end)

RunClosure("Without ExportLimits a module has no Limits and the name stays free", function()
	assert((Modules.Server :: any).Limits == nil, "Test.blink's server module has a Limits member")
	assert((Modules.Client :: any).Limits == nil, "Test.blink's client module has a Limits member")

	local Source = Generator.Generate("Server", Parser.new():Parse("type Limits = u8(1..2)\n"))
	assert(not string.find(Source, "BLINK_LIMITS", 1, true), "a module without the option declares BLINK_LIMITS")
end)

RunClosure("A scale is part of the signature, and saturate is not", function()
	local function Sign(Type: string): string
		local Source = `event E \{ From: Client, Type: Reliable, Call: SingleSync, Data: {Type} }`
		return Signature.Of(Parser.new():Parse(Source))
	end

	assert(Sign("u16<0.1>") ~= Sign("u16<0.01>"), "u16<0.1> and u16<0.01> signed alike")
	assert(Sign("u16<0.1>") ~= Sign("u16"), "u16<0.1> and u16 signed alike")
	assert(Sign("u16<saturate>") == Sign("u16"), "saturate changed the signature, and it reaches no byte")
	assert(Sign("u16<0.1, saturate>") == Sign("u16<saturate, 0.1>"), "the order of modifiers changed the signature")
end)

RunClosure("A bad number modifier is refused with what is wrong", function()
	local Cases: { { Source: string, Code: number, Message: string } } = {
		{ Source = "type A = u16<0>", Code = 3032, Message = `"0" is not a positive step` },
		{ Source = "type A = u16<-0.5>", Code = 3032, Message = `"-0.5" is not a positive step` },
		{ Source = "type A = u16<fast>", Code = 3032, Message = `Expected a scale such as 0.1, or "saturate"` },
		{ Source = "type A = f32<0.1>", Code = 3032, Message = `Only an integer takes a scale` },
		{ Source = "type A = u16<0.1, 0.2>", Code = 3032, Message = `A number has one scale` },
		{ Source = "type A = u8<saturate, saturate>", Code = 3032, Message = `Repeated saturate` },
		{ Source = "type A = u16<0.1>(0..0.05)", Code = 3009, Message = `0.05 is not a multiple of the scale 0.1` },
		{ Source = "type A = u8<0.5>(0..200)", Code = 3009, Message = `Expected a range within (0..127.5)` },
		{
			Source = "option ExportLimits = true\ntype Limits = u8",
			Code = 3005,
			Message = `"Limits" is the module's Limits`,
		},
		{
			Source = "option ExportLimits = true\noption Casing = Camel\nscope limits { type A = u8 }",
			Code = 3005,
			Message = `"limits" is the module's Limits`,
		},
	}

	for _, Case in Cases do
		local Raised: Error.Class? = nil
		local Hook = Error.OnEmit
		Error.OnEmit = function(Diagnostic)
			if Diagnostic.Severity == "Error" and not Raised then
				Raised = Diagnostic
			end
			return Diagnostic.Severity == "Warning"
		end
		pcall(function()
			Parser.new():Parse(Case.Source)
		end)
		Error.OnEmit = Hook

		local Diagnostic = Raised :: Error.Class?
		assert(Diagnostic, `"{Case.Source}" compiled, expected E{Case.Code}`)
		assert(Diagnostic.Code == Case.Code, `"{Case.Source}" raised E{Diagnostic.Code}, expected E{Case.Code}`)
		assert(
			string.find(Diagnostic.RawMessage .. Diagnostic.Message, Case.Message, 1, true),
			`"{Case.Source}" said:\n{Diagnostic.Message}\nexpected "{Case.Message}"`
		)
	end

	--> A field, type or event may still be called `saturate`: it is a word only inside brackets.
	Parser.new():Parse("type saturate = u8\nstruct S { saturate: saturate }")
end)

return {}
