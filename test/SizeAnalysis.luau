--!strict
--- Specs for src/Modules/Size.luau, the compile-time size analysis behind the unreliable-size
--- diagnostics: that its numbers agree with the bytes the emitter really writes, and that an unbounded
--- measurement names the token a diagnostic should underline.
---
--- They live apart from Test.luau but run as part of the same suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Parser = require("@compiler/Parser")
local Size = require("@compiler/Modules/Size")
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Client = Modules.Client

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

RunClosure("Static size analysis matches the emitter", function()
	--> src/Modules/Size.luau predicts how many bytes a type occupies; src/Generator/Prefabs.luau
	--> decides it. Nothing links the two, so the analysis can drift out of agreement with the
	--> compiler it describes and the only symptom would be a wrong diagnostic -- either a schema
	--> refused for no reason, or an oversize unreliable event let through.
	-->
	--> Every exported type carries a `.Write` that returns the exact bytes it produced, so the
	--> prediction can simply be checked against reality.
	local Source = fs.readFile("./Sources/Test.blink")
	local Tree = Parser.new("./Sources/", "Test.blink"):Parse(Source)

	local ByName = {}
	for _, Declaration in Tree.Value.Declarations do
		ByName[Declaration.Name] = Declaration
	end

	local Samples: { { Name: string, Value: any } } = {
		{ Name = "SizeByte", Value = 7 },
		{ Name = "SizeFixedString", Value = "abcdefgh" },
		{ Name = "SizeBoundedString", Value = "hello" },
		{ Name = "SizeBoundedString", Value = "" },
		{ Name = "SizeFixedArray", Value = { 1, 2, 3, 4 } },
		{ Name = "SizeBoundedArray", Value = { 1, 2, 3 } },
		{ Name = "SizeBoundedArray", Value = {} },
		{ Name = "SizeOptionalByte", Value = nil },
		{ Name = "SizeOptionalByte", Value = 5 },
		{ Name = "SizeStruct", Value = { A = 1, B = true, C = 2 } },
		{ Name = "SizeEnum", Value = "B" },
		{ Name = "SizeFlags", Value = { F1 = true, F3 = true } },
		{ Name = "SizeMap", Value = { [1] = 2, [3] = 4 } },
		{ Name = "Buffer", Value = buffer.create(10) },
		{ Name = "ExactBuffer", Value = buffer.create(9) },
		{ Name = "BoundedBuffer", Value = buffer.create(256) },
		{ Name = "MultiDimensionalArray", Value = { { { 1, 2 }, { 3 } }, { { 4 } } } },
		{ Name = "PlainCFrame", Value = roblox.CFrame.new(1, 2, 3) },
		{ Name = "QuatCFrame", Value = roblox.CFrame.new(1, 2, 3) },
		{ Name = "QuatHalfCFrame", Value = roblox.CFrame.new(1, 2, 3) },
		{ Name = "PackedBooleans", Value = table.create(1000, true) },
		{ Name = "PackedRanged", Value = table.create(9, false) },
		{ Name = "PackedFixed", Value = table.create(10, true) },
		{
			Name = "PackedBeside",
			Value = { A = true, List = { true }, B = true, Fixed = { true, false, true }, C = 1 },
		},
	}

	for _, Sample in Samples do
		local Declaration = ByName[Sample.Name]
		if not Declaration then
			ErrorPrint(`Failed "Static size analysis": Test.blink has no exported type "{Sample.Name}".`)
		end

		local Measured = Size.Sealed(Declaration)
		local Length = buffer.len(Client[Sample.Name].Write(Sample.Value))

		if Length < Measured.Min or Length > Measured.Max then
			ErrorPrint(
				`Failed "Static size analysis": {Sample.Name} serialised to {Length} bytes, `
					.. `outside the predicted {Measured.Min}..{Measured.Max}.`
			)
		end
	end
end)

RunClosure("An unbounded measurement names its culprit", function()
	--> The secondary label on "may exceed the packet limit" comes from `Culprit`. Each case is the
	--> declaration and the token text the label has to land on; `nil` there would drop the label.
	local Cases: { { Name: string, Source: string, Expect: string } } = {
		{ Name = "string", Source = "struct T { Text: string }", Expect = "string" },
		{ Name = "array", Source = "struct T { List: u8[] }", Expect = "[]" },
		{ Name = "map", Source = "struct T { Scores: map {[u8]: u16} }", Expect = "u8" },
	}

	for _, Case in Cases do
		local Tree = Parser.new():Parse(Case.Source)
		local Measured = Size.Sealed(Tree.Value.Declarations[1])

		local Culprit = Measured.Culprit
		if not Measured.Unbounded or not Culprit or Culprit.Value ~= Case.Expect then
			ErrorPrint(
				`Failed "Culprit": a {Case.Name} field pointed at {if Culprit then `"{Culprit.Value}"` else "nothing"}, `
					.. `expected "{Case.Expect}".`
			)
		end
	end
end)
