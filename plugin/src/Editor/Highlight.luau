--!strict
--- Turns a schema into the rich-text string the editor's Display label shows.
---
--- Deliberately free of Instances, Roblox globals and `script.`: a string and a palette go in, a
--- string comes out. That is what lets the Lune suite require it directly -- until this was split
--- out, nothing about the editor's highlighting was assertable at all, and it is the part most
--- likely to be got subtly wrong.
---
--- The palette is hex WITHOUT the leading '#', because `Color3:ToHex()` is the Roblox call that
--- produces it and that call stays on the caller's side of the boundary.
local Lexer = require("@compiler/Lexer")

export type Palette = {
	Text: string,
	Keyword: string,
	Primitive: string,
	Identifier: string,
	Class: string,
	Number: string,
	String: string,
	Bracket: string,
	Boolean: string,
	Comment: string,
	Error: string,
}

local DOTS = "%.%."
local NUMBER = "%-?%d*%.?%d+"

--> Tokens painted whole, in one colour of the palette.
local PLAIN: { [string]: string } = {
	Attribute = "Keyword",
	Primitive = "Primitive",
	String = "String",
	Boolean = "Boolean",
	Comment = "Comment",
	Unknown = "Error",
	OpenParentheses = "Bracket",
	CloseParentheses = "Bracket",
	OpenBraces = "Bracket",
	CloseBraces = "Bracket",
	OpenBrackets = "Bracket",
	CloseBrackets = "Bracket",
}

--- Only the two that would otherwise open a rich-text tag. Ampersand is left alone on purpose: the
--- schema language has no use for entities, and escaping it would make every `&` in a string render
--- as `&amp;`.
local RICH_TEXT_ESCAPES: { [string]: string } = {
	["<"] = "&lt;",
	[">"] = "&gt;",
}

local Highlight = {}

local function Color(Text: string, Hex: string): string
	return `<font color="#{Hex}">{Text}</font>`
end

local function Escape(Text: string): string
	for Symbol, Replacement in RICH_TEXT_ESCAPES do
		Text = string.gsub(Text, Symbol, Replacement)
	end

	return Text
end

--- An array's or a range's bounds: the numbers are painted, the brackets and dots are not.
local function Bounds(Value: string, Palette: Palette): string?
	local Single = string.match(Value, `%[({NUMBER})%]`) or string.match(Value, `%(({NUMBER})%)`)
	local Lower = string.match(Value, `%[({NUMBER}){DOTS}`) or string.match(Value, `%(({NUMBER}){DOTS}`)
	local Upper = string.match(Value, `{DOTS}({NUMBER})%]`) or string.match(Value, `{DOTS}({NUMBER})%)`)

	if Single then
		return (string.gsub(Value, Single, Color(Single, Palette.Number)))
	elseif Lower and Upper then
		local Open = string.sub(Value, 1, 1)
		local Close = string.sub(Value, #Value, #Value)
		return `{Open}{Color(Lower, Palette.Number)}..{Color(Upper, Palette.Number)}{Close}`
	end

	return nil
end

--- One token's worth of markup. Split out from the loop so a spec can drive a single token without
--- standing up a document.
function Highlight.Token(
	Token: Lexer.Token,
	Palette: Palette,
	SourceLexer: Lexer.Lexer,
	Keyword: string
): (string, string)
	local Type: Lexer.Types = Token.Type
	local Value = Token.Value

	local Plain = PLAIN[Type]
	if Plain then
		return Color(Value, (Palette :: any)[Plain]), Keyword
	end

	if Type == "Keyword" or Type == "Import" or Type == "As" then
		return Color(Value, Palette.Keyword), Value
	elseif Type == "Identifier" then
		--> A field name is painted as text rather than as an identifier, which is how `Name:` reads
		--> differently from a reference to `Name`. A map's key is a type, not a field, hence the guard.
		local LookAhead = SourceLexer:GetNextToken(true)
		local IsField = (LookAhead and LookAhead.Type == "FieldAssign" and Keyword ~= "map")
		return Color(Value, IsField and Palette.Text or Palette.Identifier), Keyword
	elseif Type == "Array" or Type == "Range" then
		return Bounds(Value, Palette) or Escape(Value), Keyword
	elseif Type == "Component" then
		local Primitive = string.match(Value, "(%w+)") or ""
		return `{Color("<", Palette.Bracket)}{Color(Primitive, Palette.Primitive)}{Color(">", Palette.Bracket)}`,
			Keyword
	elseif Type == "Class" then
		return `({Color(string.sub(Value, 2, #Value - 1), Palette.Class)})`, Keyword
	end

	return Escape(Value), Keyword
end

--- The whole document. `SourceLexer` is handed in rather than created here so the editor keeps using
--- the one instance it already has.
function Highlight.Render(Source: string, SourceLexer: Lexer.Lexer, Palette: Palette): string
	local RichText = {}

	SourceLexer:Initialize(Source)

	local Keyword = "none"
	local Token = SourceLexer:GetNextToken()

	while Token and (Token.Type ~= "EndOfFile") do
		local String
		String, Keyword = Highlight.Token(Token, Palette, SourceLexer, Keyword)
		table.insert(RichText, String)
		Token = SourceLexer:GetNextToken()
	end

	return table.concat(RichText)
end

return Highlight
