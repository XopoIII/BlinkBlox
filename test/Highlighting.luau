--!strict
--- Specs for the editor's syntax highlighter.
---
--- The highlighter used to live inside plugin/src/Editor/init.luau, wrapped around `Display.Text`,
--- so nothing about it could be checked outside Studio. It is now a pure function -- source string
--- and palette in, rich-text string out -- and these are the first assertions ever made about it.
---
--- What they are worth: the markup is what the user actually reads, and a mistake in it is silent.
--- An unescaped `<` in a schema turns the rest of the line into a tag the engine swallows, and
--- nobody notices until a `Component` type appears in a file.
local Harness = require("./Harness")
local Highlight = require("@compiler/../plugin/src/Editor/Highlight")
local Lexer = require("@compiler/Lexer")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

--> Distinct per role so a spec can tell which branch painted a token.
local PALETTE: Highlight.Palette = {
	Text = "111111",
	Keyword = "222222",
	Primitive = "333333",
	Identifier = "444444",
	Class = "555555",
	Number = "666666",
	String = "777777",
	Bracket = "888888",
	Boolean = "999999",
	Comment = "aaaaaa",
	Error = "bbbbbb",
}

local SourceLexer = Lexer.new("Highlighting")

local function Render(Source: string): string
	return Highlight.Render(Source, SourceLexer, PALETTE)
end

local function Expect(Name: string, Source: string, Needle: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Rendered = Render(Source)
	if not string.find(Rendered, Needle, 1, true) then
		ErrorPrint(`Failed "{Name}"\nExpected to find: {Needle}\nIn: {Rendered}`)
		return
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function ExpectNot(Name: string, Source: string, Needle: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Rendered = Render(Source)
	if string.find(Rendered, Needle, 1, true) then
		ErrorPrint(`Failed "{Name}"\nExpected NOT to find: {Needle}\nIn: {Rendered}`)
		return
	end

	OkPrint(`Test "{Name}" passed!`)
end

Expect("Keywords are painted", "struct Foo {}", `<font color="#222222">struct</font>`)
Expect("Primitives are painted", "type A = u8", `<font color="#333333">u8</font>`)
Expect("Comments are painted", "-- a comment", `<font color="#aaaaaa">-- a comment</font>`)
Expect("Strings are painted", 'option RemoteScope = "X"', `<font color="#777777">"X"</font>`)

--> A struct field and a reference to a type are both identifiers to the lexer. What separates them
--> is the `:` that follows, and the highlighter looks one token ahead to find it.
Expect("A field reads as text, not as an identifier", "struct Foo {\n\tBar: u8\n}", `<font color="#111111">Bar</font>`)
Expect("A type reference reads as an identifier", "type A = Foo", `<font color="#444444">Foo</font>`)

--> A map's key is a type even though a `:` follows it, so the field rule must not claim it.
Expect("A map key stays an identifier", "map M = {[Foo]: u8}", `<font color="#444444">Foo</font>`)

--> The reason escaping exists at all: an unescaped angle bracket opens a tag and the engine eats
--> whatever follows. A `vector<i16>` in a schema is enough to trigger it.
Expect("A component's brackets are escaped", "type V = vector<i16>", "&lt;")
ExpectNot("A component does not emit a raw bracket", "type V = vector<i16>", "><i16")

--> Ranges paint only the numbers, leaving the brackets and the dots alone.
Expect("A bounded range paints both ends", "type A = u8(0..10)", `<font color="#666666">0</font>`)
Expect("An exact array size is painted", "type A = u8[8]", `<font color="#666666">8</font>`)

--> An attribute reads as a keyword, and its profile as a string -- not as an error, which is what
--> an `@` the lexer had no rule for used to paint.
Expect("An attribute is painted as a keyword", '@profile("dev")\nevent A {}', `<font color="#222222">@profile</font>`)
Expect(
	"An attribute's profile is painted as a string",
	'@profile("dev")\nevent A {}',
	`<font color="#777777">"dev"</font>`
)
ExpectNot("An attribute is not painted as an error", '@profile("dev")\nevent A {}', "#bbbbbb")

--> An empty document is the state the editor starts in, and the state it returns to when the user
--> selects all and deletes.
if Render("") ~= "" then
	ErrorPrint(`Failed "An empty document renders empty", got "{Render("")}"`)
else
	OkPrint(`Test "An empty document renders empty" passed!`)
end

return {}
