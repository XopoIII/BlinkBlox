--!strict
--- Every ```blink block in the documentation, compiled.
---
--- The docs used to carry examples the parser had never accepted -- `export struct X = {`, a struct
--- field written with `=` -- and nothing noticed, because nothing ran them. Each block is now parsed
--- and generated for both sides, and the generated modules must load as Luau.
---
--- A fence can opt out with one word in its meta:
---   `fragment`  a snippet that is not a whole schema (a lone type, or one using another block's type)
---   `error`     an example of something the compiler refuses; it must FAIL to compile
local Attributes = require("@compiler/Modules/Attributes")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local DOCS = "../docs/src/content/docs"

type Example = {
	File: string,
	Line: number,
	Source: string,
	Words: { [string]: true },
}

local function CollectFiles(Directory: string, Into: { string })
	for _, Name in fs.readDir(Directory) do
		local Path = `{Directory}/{Name}`
		if fs.isDir(Path) then
			CollectFiles(Path, Into)
		elseif string.match(Name, "%.mdx?$") then
			table.insert(Into, Path)
		end
	end
end

--- The words of a fence's meta, with quoted values (`title="..."`) removed first so a title can
--- never switch a block's mode by accident.
local function MetaWords(Meta: string): { [string]: true }
	local Words: { [string]: true } = {}
	local Stripped = string.gsub(Meta, '%w+="[^"]*"', "")
	for Word in string.gmatch(Stripped, "[%w%-]+") do
		Words[Word] = true
	end

	return Words
end

local function Extract(File: string, Text: string): { Example }
	local Examples: { Example } = {}
	local Lines = string.split(Text, "\n")

	local Index = 1
	while Index <= #Lines do
		local Indent, Meta = string.match(Lines[Index], "^(%s*)```blink(.*)$")
		if Indent and Meta then
			local Start = Index
			local Body: { string } = {}
			Index += 1
			while Index <= #Lines and not string.match(Lines[Index], "^%s*```%s*$") do
				--> Fences nested in a component are indented; the schema inside them is not.
				local Line = Lines[Index]
				if string.sub(Line, 1, #Indent) == Indent then
					Line = string.sub(Line, #Indent + 1)
				end
				table.insert(Body, Line)
				Index += 1
			end

			table.insert(Examples, {
				File = File,
				Line = Start,
				Source = table.concat(Body, "\n"),
				Words = MetaWords(Meta),
			})
		end
		Index += 1
	end

	return Examples
end

local function Compile(Source: string)
	local Tree = Parser.new(nil, nil, nil, Attributes.new(nil)):Parse(Source)
	local Outputs = {
		Generator.Generate("Server", Tree),
		Generator.Generate("Client", Tree),
	}
	if Tree.Value.Options.TypesOutput then
		table.insert(Outputs, Generator.GenerateShared(Tree))
	end

	--> A module that generates but does not load is still a broken example; this is what caught
	--> fields named after Luau keywords.
	for _, Output in Outputs do
		luau.compile(Output)
	end
end

PrettyPrint("blue", "Compiling documentation examples...")

if not fs.isDir(DOCS) then
	ErrorPrint(`Documentation not found at {DOCS}.`)
end

local Files: { string } = {}
CollectFiles(DOCS, Files)
table.sort(Files)
--> The README is the first example most people read.
table.insert(Files, "../README.md")

--> Every failure is collected before reporting, so one run lists everything a docs change broke.
local Failures: { string } = {}
local Checked = 0
for _, File in Files do
	for _, Example in Extract(File, fs.readFile(File)) do
		local Where = `{(string.gsub(Example.File, "^%.%./", ""))}:{Example.Line}`
		if Example.Words.fragment then
			continue
		end

		Checked += 1
		local Success, Failure = pcall(Compile, Example.Source)
		if Example.Words.error then
			if Success then
				table.insert(Failures, `{Where} is marked "error" but compiled.`)
			end
		elseif not Success then
			table.insert(Failures, `{Where} does not compile:\n{Failure}`)
		end
	end
end

if #Failures > 0 then
	ErrorPrint(`{#Failures} documentation example(s) misbehave:\n\n{table.concat(Failures, "\n\n")}`)
end

if Checked == 0 then
	ErrorPrint("No documentation examples were found; the extractor is broken.")
end

OkPrint(`All {Checked} documentation examples behave as marked.`)

return {}
