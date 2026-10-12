--!strict
--- Specs for `option ExportRates` -- the rate limits the server enforces as a table the game reads.
---
--- The rates are read from all three modules a schema compiles to, and each is compared with the
--- number the schema below writes, or with the default the documentation gives where it writes
--- none. The server's own guards are then read back, so the table cannot say one thing while the
--- module enforces another.
local Assertions = require("./Assertions")
local Error = require("@compiler/Modules/Error")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local Modules = require("./Modules")
local Parser = require("@compiler/Parser")
local luau = require("@lune/luau")

local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option ExportRates = true
option DefaultRate = 7

event Report { From: Client, Type: Reliable, Call: SingleSync, Rate: 1, Burst: 4, Data: u8 }
event Tap { From: Client, Type: Reliable, Call: SingleSync, Rate: 0.5, Data: u8 }
event Gust { From: Client, Type: Reliable, Call: SingleSync, Rate: 2.5, Data: u8 }
event Plain { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
event State { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }
event Ticks { From: Server, Type: OrderedUnreliable, Call: SingleSync, Stream: { Rate: 10 }, Data: u8 }
function Ask { Yield: Coroutine, Rate: 2, Concurrency: 3, Data: u8, Return: u8 }
function Tell { From: Server, Yield: Coroutine, Data: u8, Return: u8 }

scope Inner {
	event Deep { From: Client, Type: Reliable, Call: SingleSync, Rate: 3, Burst: 6, Data: u8 }
}

scope Hollow {
	event Out { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }
}
]]

--- `Path` read from `Rates`, one key at a time, or nil where the path stops.
local function At(Rates: any, ...: string): any
	local Current = Rates
	for _, Key in { ... } do
		if type(Current) ~= "table" then
			return nil
		end
		Current = Current[Key]
	end
	return Current
end

--- The keys of `Table`, sorted and joined.
local function Keys(Table: any): string
	local Found = {}
	for Key in Table do
		table.insert(Found, Key)
	end
	table.sort(Found)
	return table.concat(Found, ",")
end

local function Check(Label: string, Rates: any, Casing: "Pascal" | "Snake")
	local function Word(Pascal: string): string
		return if Casing == "Pascal" then Pascal else string.lower(Pascal)
	end
	local Rate, Burst, Concurrency = Word("Rate"), Word("Burst"), Word("Concurrency")

	local Expected: { { Path: { string }, Value: any } } = {
		{ Path = { "Report", Rate }, Value = 1 },
		{ Path = { "Report", Burst }, Value = 4 },
		{ Path = { "Report", Concurrency }, Value = nil },
		--> No burst written: the least whole token count that holds a second of the rate, and never
		--> under one.
		{ Path = { "Tap", Rate }, Value = 0.5 },
		{ Path = { "Tap", Burst }, Value = 1 },
		{ Path = { "Gust", Rate }, Value = 2.5 },
		{ Path = { "Gust", Burst }, Value = 3 },
		--> No rate written: `option DefaultRate`, and the burst that follows from it.
		{ Path = { "Plain", Rate }, Value = 7 },
		{ Path = { "Plain", Burst }, Value = 7 },
		{ Path = { "Ask", Rate }, Value = 2 },
		{ Path = { "Ask", Burst }, Value = 2 },
		{ Path = { "Ask", Concurrency }, Value = 3 },
		{ Path = { "Inner", "Deep", Rate }, Value = 3 },
		{ Path = { "Inner", "Deep", Burst }, Value = 6 },
		--> What the server sends is limited by nothing, a stream's `Rate` is not a limit, and a scope
		--> holding only such declarations has nothing to say.
		{ Path = { "State" }, Value = nil },
		{ Path = { "Ticks" }, Value = nil },
		{ Path = { "Tell" }, Value = nil },
		{ Path = { "Hollow" }, Value = nil },
	}

	for _, Case in Expected do
		local Got = At(Rates, table.unpack(Case.Path))
		local Where = table.concat(Case.Path, ".")
		assert(Got == Case.Value, `{Label}: Rates.{Where} is {Got}, expected {Case.Value}`)
	end

	assert(table.isfrozen(Rates), `{Label}: Rates is not frozen`)
	assert(table.isfrozen(At(Rates, "Inner", "Deep")), `{Label}: Rates.Inner.Deep is not frozen`)

	local Listed = Keys(Rates)
	assert(Listed == "Ask,Gust,Inner,Plain,Report,Tap", `{Label}: Rates holds {Listed}`)
	local Fields = Keys(Rates.Report)
	assert(Fields == `{Burst},{Rate}`, `{Label}: Rates.Report holds {Fields}`)
end

RunClosure("ExportRates puts the enforced rates in the server, client and types modules", function()
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "RATES")
	Check("server", Pair.Server.Rates, "Pascal")
	Check("client", Pair.Client.Rates, "Pascal")

	local Shared = (luau.load(Generator.GenerateShared(Parser.new():Parse(SCHEMA))) :: any)()
	Check("types", Shared.Rates, "Pascal")

	--> The edit-mode stub table keeps the member, as it keeps every other.
	local Source = Generator.Generate("Server", Parser.new():Parse(SCHEMA))
	local _, Returned = string.gsub(Source, "\nReturns%.Rates = BLINK_RATES\n", "")
	local _, Stubbed = string.gsub(Source, "\n%s*Rates = BLINK_RATES,", "")
	local Members = Returned + Stubbed
	assert(Members == 2, `the server module names Rates {Members} times, expected 2 (returned and stubbed)`)
end)

RunClosure("ExportRates states what the server's guards enforce", function()
	local Source = Generator.Generate("Server", Parser.new():Parse(SCHEMA))
	local Guards: { { Name: string, Rate: string, Burst: string } } = {
		{ Name = "Report", Rate = "1", Burst = "4" },
		{ Name = "Tap", Rate = "0.5", Burst = "1" },
		{ Name = "Gust", Rate = "2.5", Burst = "3" },
		{ Name = "Plain", Rate = "7", Burst = "7" },
		{ Name = "Ask", Rate = "2", Burst = "2" },
		{ Name = "Deep", Rate = "3", Burst = "6" },
	}

	local _, Total = string.gsub(Source, "RateAccept%(Player, %d+, ", "")
	assert(Total == #Guards, `the server module guards {Total} declarations by rate, expected {#Guards}`)
	for _, Guard in Guards do
		local Pattern = `RateAccept%(Player, %d+, {Guard.Rate}, {Guard.Burst}, "{Guard.Name}"%)`
		Pattern = string.gsub(Pattern, "%.5", "%%.5")
		assert(
			string.find(Source, Pattern),
			`the server module does not hold {Guard.Name} to {Guard.Rate} and {Guard.Burst}`
		)
	end
	assert(
		string.find(Source, 'ConcurrencyAccept%(Player, %d+, 3, "Ask"%)'),
		"the server module does not hold Ask to 3 at once"
	)
end)

RunClosure("ExportRates follows option Casing for its structural words", function()
	local Snake = "option Casing = Snake\n" .. SCHEMA
	local Pair = Isolated.Build(Isolated.Parse(Snake), "RATES_SNAKE")
	Check("server, snake", Pair.Server.rates, "Snake")
	assert(Pair.Server.Rates == nil, "a snake-cased module also returned Rates")
end)

RunClosure("ExportRates leaves out what nothing limits, and keeps a lone Concurrency", function()
	local Source = [[
option ExportRates = true
event Free { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
function Slow { Yield: Coroutine, Concurrency: 2, Data: u8, Return: u8 }
]]
	local Shared = (luau.load(Generator.GenerateShared(Parser.new():Parse(Source))) :: any)()
	assert(Keys(Shared.Rates) == "Slow", `Rates holds {Keys(Shared.Rates)}, expected Slow alone`)
	assert(Keys(Shared.Rates.Slow) == "Concurrency", `Rates.Slow holds {Keys(Shared.Rates.Slow)}`)
	assert(Shared.Rates.Slow.Concurrency == 2, `Rates.Slow.Concurrency is {Shared.Rates.Slow.Concurrency}`)

	--> A rate on what the server sends is a warning and is enforced nowhere, so it is not exported.
	local Hook = Error.OnEmit
	Error.OnEmit = function(Diagnostic)
		return Diagnostic.Severity == "Warning"
	end
	local Tree = Parser.new():Parse([[
option ExportRates = true
event Loud { From: Server, Type: Reliable, Call: SingleSync, Rate: 5, Data: u8 }
]])
	Error.OnEmit = Hook
	local Outbound = (luau.load(Generator.GenerateShared(Tree)) :: any)()
	assert(Keys(Outbound.Rates) == "", `Rates holds {Keys(Outbound.Rates)} for a schema that limits nothing`)
	assert(table.isfrozen(Outbound.Rates), "an empty Rates is not frozen")
end)

RunClosure("ExportRates declares its table in the TypeScript output", function()
	local Declaration = Generator.GenerateTypescript("Client", Parser.new():Parse(SCHEMA))
	for _, Line in
		{
			"export declare const Rates: {",
			"\treadonly Report: {\n\t\treadonly Rate: number;\n\t\treadonly Burst: number;\n\t};",
			"\t\treadonly Concurrency: number;",
			"\treadonly Inner: {\n\t\treadonly Deep: {",
		}
	do
		assert(string.find(Declaration, Line, 1, true), `the TypeScript output lacks "{Line}"`)
	end
	assert(not string.find(Declaration, "readonly State: {", 1, true), "the TypeScript Rates names a server event")
end)

RunClosure("Without ExportRates a module has no Rates and the name stays free", function()
	assert((Modules.Server :: any).Rates == nil, "Test.blink's server module has a Rates member")
	assert((Modules.Client :: any).Rates == nil, "Test.blink's client module has a Rates member")

	local Source = Generator.Generate("Server", Parser.new():Parse("type Rates = u8(1..2)\n"))
	assert(not string.find(Source, "BLINK_RATES", 1, true), "a module without the option declares BLINK_RATES")
end)

RunClosure("A declaration named after the Rates member is refused under the option", function()
	local Cases: { { Source: string, Message: string } } = {
		{ Source = "option ExportRates = true\ntype Rates = u8", Message = `"Rates" is the module's Rates` },
		{
			Source = "option ExportRates = true\noption Casing = Camel\nscope rates { type A = u8 }",
			Message = `"rates" is the module's Rates`,
		},
		--> One option does not reserve the other's member.
		{
			Source = "option ExportRates = true\noption ExportLimits = true\ntype Limits = u8",
			Message = `"Limits" is the module's Limits`,
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
		assert(Diagnostic, `"{Case.Source}" compiled, expected E3005`)
		assert(Diagnostic.Code == 3005, `"{Case.Source}" raised E{Diagnostic.Code}, expected E3005`)
		assert(
			string.find(Diagnostic.RawMessage .. Diagnostic.Message, Case.Message, 1, true),
			`"{Case.Source}" said:\n{Diagnostic.Message}\nexpected "{Case.Message}"`
		)
		assert(
			string.find(Diagnostic.Message, "option Export" .. string.match(Case.Message, "module's (%a+)"), 1, true),
			`"{Case.Source}" does not name the option that adds the member:\n{Diagnostic.Message}`
		)
	end

	Parser.new():Parse("option ExportLimits = true\ntype Rates = u8")
	Parser.new():Parse("option ExportRates = true\ntype Limits = u8")
end)

return {}
