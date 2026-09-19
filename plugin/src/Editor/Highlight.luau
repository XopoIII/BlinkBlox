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

local BRACKETS = {
	OpenParentheses = true,
	CloseParentheses = true,
	OpenBraces = true,
	CloseBraces = true,
	OpenBrackets = true,
	CloseBrackets = true,
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
	local String = Escape(Value)

	if Type == "Keyword" or Type == "Import" or Type == "As" then
		return Color(Value, Palette.Keyword), Value
	elseif Type == "Attribute" then
		String = Color(Value, Palette.Keyword)
	elseif Type == "Primitive" then
		String = Color(Value, Palette.Primitive)
	elseif Type == "Identifier" then
		--> A field name is painted as text rather than as an identifier, which is how `Name:` reads
		--> differently from a reference to `Name`. A map's key is a type, not a field, hence the guard.
		local LookAhead = SourceLexer:GetNextToken(true)
		local IsField = (LookAhead and LookAhead.Type == "FieldAssign" and Keyword ~= "map")
		String = Color(Value, IsField and Palette.Text or Palette.Identifier)
	elseif Type == "Array" or Type == "Range" then
		local Single = string.match(Value, `%[({NUMBER})%]`) or string.match(Value, `%(({NUMBER})%)`)
		local Lower = string.match(Value, `%[({NUMBER}){DOTS}`) or string.match(Value, `%(({NUMBER}){DOTS}`)
		local Upper = string.match(Value, `{DOTS}({NUMBER})%]`) or string.match(Value, `{DOTS}({NUMBER})%)`)

		if Single then
			String = string.gsub(Value, Single, Color(Single, Palette.Number))
		elseif Lower and Upper then
			local Open = string.sub(Value, 1, 1)
			local Close = string.sub(Value, #Value, #Value)
			String = `{Open}{Color(Lower, Palette.Number)}..{Color(Upper, Palette.Number)}{Close}`
		end
	elseif Type == "Component" then
		local Primitive = string.match(Value, "(%w+)") or ""
		String = `{Color("<", Palette.Bracket)}{Color(Primitive, Palette.Primitive)}{Color(">", Palette.Bracket)}`
	elseif BRACKETS[Type] then
		String = Color(Value, Palette.Bracket)
	elseif Type == "Class" then
		String = `({Color(string.sub(Value, 2, #Value - 1), Palette.Class)})`
	elseif Type == "String" then
		String = Color(Value, Palette.String)
	elseif Type == "Boolean" then
		String = Color(Value, Palette.Boolean)
	elseif Type == "Comment" then
		String = Color(Value, Palette.Comment)
	elseif Type == "Unknown" then
		String = Color(Value, Palette.Error)
	end

	return String, Keyword
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
