--!strict
--- What the documentation says about the generated code, held against the goldens.
---
--- "Compared with hand-written buffers" quotes the reader the compiler writes for an event, and says a
--- generated module has no classes and no metatables. Both are claims about emitted text, which
--- nothing else in the docs checks: a changed guard would leave the page showing code the compiler no
--- longer writes. So a ```luau fence marked `golden="<path>"` must be found in that golden, line for
--- line, and no golden may reach for a metatable.
local Harness = require("./Harness")
local fs = require("@lune/fs")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local DOCS = "../docs/src/content/docs"
local GOLDENS = "./Golden"

local METATABLES = { "setmetatable", "getmetatable", "__index" }

type Excerpt = {
	Where: string,
	Golden: string,
	Lines: { string },
}

local function CollectFiles(Directory: string, Pattern: string, Into: { string })
	for _, Name in fs.readDir(Directory) do
		local Path = `{Directory}/{Name}`
		if fs.isDir(Path) then
			CollectFiles(Path, Pattern, Into)
		elseif string.match(Name, Pattern) then
			table.insert(Into, Path)
		end
	end
end

--- A file's lines without their indentation or blank lines: an excerpt is quoted at the margin, and
--- the code it quotes sits wherever the generator nested it.
local function Trimmed(Text: string): { string }
	local Lines: { string } = {}
	for _, Line in string.split(Text, "\n") do
		local Stripped = string.match(Line, "^%s*(.-)%s*$") :: string
		if Stripped ~= "" then
			table.insert(Lines, Stripped)
		end
	end

	return Lines
end

local function Extract(File: string, Text: string): { Excerpt }
	local Excerpts: { Excerpt } = {}
	local Lines = string.split(Text, "\n")

	local Index = 1
	while Index <= #Lines do
		local Golden = string.match(Lines[Index], '^%s*```luau.*golden="([^"]+)"')
		if Golden then
			local Start = Index
			local Body: { string } = {}
			Index += 1
			while Index <= #Lines and not string.match(Lines[Index], "^%s*```%s*$") do
				table.insert(Body, Lines[Index])
				Index += 1
			end

			table.insert(Excerpts, {
				Where = `{(string.gsub(File, "^%.%./", ""))}:{Start}`,
				Golden = Golden,
				Lines = Trimmed(table.concat(Body, "\n")),
			})
		end
		Index += 1
	end

	return Excerpts
end

--- Whether `Needle`'s lines appear in `Haystack` one after another.
local function Contains(Haystack: { string }, Needle: { string }): boolean
	for Start = 1, #Haystack - #Needle + 1 do
		local Matches = true
		for Offset = 1, #Needle do
			if Haystack[Start + Offset - 1] ~= Needle[Offset] then
				Matches = false
				break
			end
		end

		if Matches then
			return true
		end
	end

	return false
end

PrettyPrint("blue", "Checking the generated code the documentation quotes...")

local Failures: { string } = {}

local Pages: { string } = {}
CollectFiles(DOCS, "%.mdx?$", Pages)
table.sort(Pages)

local Checked = 0
for _, Page in Pages do
	for _, Excerpt in Extract(Page, fs.readFile(Page)) do
		Checked += 1
		local Path = `{GOLDENS}/{Excerpt.Golden}`
		if not fs.isFile(Path) then
			table.insert(Failures, `{Excerpt.Where} quotes {Excerpt.Golden}, which is not a golden.`)
		elseif #Excerpt.Lines == 0 then
			table.insert(Failures, `{Excerpt.Where} quotes nothing.`)
		elseif not Contains(Trimmed(fs.readFile(Path)), Excerpt.Lines) then
			table.insert(Failures, `{Excerpt.Where} is no longer what {Excerpt.Golden} contains.`)
		end
	end
end

if Checked == 0 then
	table.insert(Failures, "No quoted excerpts were found; the extractor is broken.")
end

local Modules: { string } = {}
CollectFiles(GOLDENS, "%.luau$", Modules)
table.sort(Modules)

for _, Module in Modules do
	local Text = fs.readFile(Module)
	for _, Word in METATABLES do
		if string.find(Text, Word, 1, true) then
			table.insert(Failures, `{Module} uses {Word}; the docs say a generated module has no metatables.`)
		end
	end
end

if #Failures > 0 then
	ErrorPrint(`{#Failures} claim(s) about the generated code no longer hold:\n\n{table.concat(Failures, "\n")}`)
end

OkPrint(
	`All {Checked} quoted excerpts are in their goldens, and none of {#Modules} generated modules uses a metatable.`
)

return {}
