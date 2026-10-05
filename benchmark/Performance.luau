local fs = require("@lune/fs")
local runtime = require("../.lune/libs/runtime")
local stdio = require("@lune/stdio")

--> This run stands in for a release bundle, and says so itself: darklua would have replaced both
--> globals with literals, so they are set here the way it sets them -- before anything under src/ is
--> required. `src/Modules/Version.luau` reads `_G.VERSION` once, as it loads, and stays the only
--> reader; set any later, the label would reach nothing. `PERFORMANCE` is this benchmark's own
--> label for the modules it generates and no release's version, and `_G.RELEASE` is what makes the
--> generator time release output rather than debug output.
_G.RELEASE = true
_G.VERSION = "PERFORMANCE"

local Attributes = require("../src/Modules/Attributes")
local Error = require("../src/Modules/Error")
local Generator = require("../src/Generator")
local Lexer = require("../src/Lexer")
local Parser = require("../src/Parser")

--> Test.blink draws a dozen warnings on purpose. Rendered, they would be printed on every one of the
--> thousand parses, and the benchmark would time the renderer and the terminal instead of the parser.
Error.OnEmit = function(Diagnostic)
	return Diagnostic.Severity == "Warning"
end

local Source = fs.readFile("../test/Sources/Test.blink")
local SourceLexer = Lexer.new()
--> A parser per parse, as the CLI makes one per compile.
local function NewParser()
	return Parser.new("../test/Sources/", "Test.blink", nil, Attributes.new(nil))
end

local AbstractSyntaxTree = NewParser():Parse(Source)

local function Format(Time: number): string
	local Suffix = "seconds"
	if Time < 1E-6 then
		Time *= 1E+9
		Suffix = "ns"
	elseif Time < 0.001 then
		Time *= 1E+6
		Suffix = "us"
	elseif Time < 1 then
		Time *= 1000
		Suffix = "ms"
	end

	return `{stdio.color("green")}{string.format("%.2f", Time)} {Suffix}{stdio.color("reset")}`
end

local function Percentile(Samples: { number }, Percent: number): number
	local Index = (#Samples * Percent) // 1
	Index = math.max(Index, 1)
	return Samples[Index]
end

local WARMUP = 20

local function BenchmarkClosure(Title: string, Closure: () -> ())
	print(`Benchmarking: {Title}`)
	stdio.write("Running")

	--> Untimed: the first runs pay for filling caches and growing tables the later ones reuse.
	for _ = 1, WARMUP do
		Closure()
	end

	local Times = {}
	for Index = 1, 1_000 do
		stdio.write(`\rRunning [{stdio.color("green")}{Index}{stdio.color("reset")}/1000]`)

		local Start = os.clock()
		Closure()

		local Elapsed = (os.clock() - Start)
		table.insert(Times, Elapsed)
	end

	table.sort(Times, function(a, b)
		return a < b
	end)

	stdio.write(`\r-------- {stdio.color("yellow")}{Title}{stdio.color("reset")} --------\n`)
	print(`Median: {Format(Percentile(Times, 0.5))}`)
	print(`0th Percentile: {Format(Times[1])}`)
	print(`90th Percentile: {Format(Percentile(Times, 0.9))}`)
	print(`95th Percentile: {Format(Percentile(Times, 0.95))}`)
	print(`99th Percentile: {Format(Percentile(Times, 0.99))}`)
end

runtime.notice("These timings")

BenchmarkClosure("Lex", function()
	SourceLexer:Initialize(Source)

	while true do
		local Token = SourceLexer:GetNextToken()
		if Token.Type == "EndOfFile" then
			break
		end
	end
end)

BenchmarkClosure("Parse", function()
	NewParser():Parse(Source)
end)

BenchmarkClosure("Generate server", function()
	Generator.Generate("Server", AbstractSyntaxTree)
end)

BenchmarkClosure("Generate client", function()
	Generator.Generate("Client", AbstractSyntaxTree)
end)

runtime.notice("These timings")
