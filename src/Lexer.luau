--!strict
--!native
--!optimize 2

local Error = require("./Modules/Error")
local Settings = require("./Settings")

export type Types =
	"Comma"
	| "OpenParentheses"
	| "CloseParentheses"
	| "OpenBraces"
	| "CloseBraces"
	| "OpenBrackets"
	| "CloseBrackets"
	| "Merge" --> Structs & enums
	| "String"
	| "Boolean"
	| "Number" --> Literals
	| "Array"
	| "Range"
	| "Optional"
	| "Class"
	| "Component"
	| "OpenChevrons"
	| "CloseChevrons" --> Attributes
	| "Attribute" --> `@profile`
	| "Assign"
	| "FieldAssign"
	| "Keyword"
	| "Primitive"
	| "Identifier" --> Reserved
	| "Import"
	| "As" --> Imports
	| "Whitespace"
	| "Comment"
	| "Unknown"
	| "EndOfFile"

export type Keywords = "type" | "enum" | "struct" | "event" | "function"

export type Token = {
	Type: Types,
	Value: string,

	Start: number,
	End: number,
}

export type Mode = "Parsing" | "Highlighting"

--- A rule in `TOKENS`: a Lua pattern, plus either the token type it always produces or a transformer
--- that inspects the matched text and decides both the type and the value it carries.
---
--- The transformer's value is `string | boolean` and not `string`, because that is what the lexer
--- genuinely produces: the `true`/`false` rule returns a real boolean, and `Parser.Options` stores it
--- straight into a `boolean` option field. Everything else in the compiler reads `Token.Value` as a
--- string, so the widening is confined to this type and to the one cast where a token is built.
export type TokenTransformer = (Text: string) -> (Types, string | boolean)
export type TokenRule = { [number]: string | Types | TokenTransformer }

local DOTS = "%.%."
local NUMBER = "%-?%d*%.?%d+"

local Keywords = Settings.Keywords
local Primitives = Settings.Primtives

local Booleans = {
	["true"] = true,
	["false"] = true,
}

local TOKENS: { TokenRule } = {
	--> Simple patterns
	{ "^%s+", "Whitespace" },
	{ "^=", "Assign" },
	{ "^:", "FieldAssign" },
	{ "^{", "OpenBraces" },
	{ "^}", "CloseBraces" },
	{ "^<", "OpenChevrons" },
	{ "^>", "CloseChevrons" },
	{ "^,", "Comma" },
	{ "^%.%.", "Merge" },
	{ "^@[%a_][%w_]*", "Attribute" },

	--> Comments
	{ "^%-%-%[(=*)%[.-%]%1%]", "Comment" },
	{ "^%-%-%[%[.-.*", "Comment" },
	{ "^%-%-.-\n", "Comment" },
	{ "^%-%-.-.*", "Comment" },

	--> Attribute patterns
	{ "^?", "Optional" },
	--> `%a+` would not match a class name containing a digit, so `Instance(Vector3Value)`,
	--> `Instance(UIGridLayout)` and `Instance(Part0)` failed to lex (upstream issue #75). The parser
	--> then silently fell back to the bare "Instance" class and reported the leftover "(" as an
	--> unrelated syntax error.
	--> A digit is allowed only after the first character, ON PURPOSE: this rule is matched BEFORE the
	--> Range rules below, so `^%(%w+%)` would swallow `u8(10)` and `(1..5)` and break every range.
	{ `^%([%a_][%w_]*%)`, "Class" },
	{ `^%[]`, "Array" },
	{ `^%({NUMBER}%)`, "Range" },
	{ `^%({NUMBER}{DOTS}%)`, "Range" },
	{ `^%({DOTS}{NUMBER}%)`, "Range" },
	{ `^%({NUMBER}{DOTS}{NUMBER}%)`, "Range" },
	{ `^%[{NUMBER}%]`, "Array" },
	{ `^%[{NUMBER}{DOTS}%]`, "Array" },
	{ `^%[{DOTS}{NUMBER}%]`, "Array" },
	{ `^%[{NUMBER}{DOTS}{NUMBER}%]`, "Array" },

	--> A bare number, as in `option MaxPacketSize = 8192` or an event's `Rate: 5`.
	-->
	--> It has to sit AFTER the range and array rules, which match a number wrapped in brackets: put
	--> ahead of them, this would take the `1` out of `(1..5)` and leave the parser with nonsense.
	--> Nothing above matches a leading digit, so ordering against the identifier rules is moot.
	-->
	--> Its absence is why numeric options never worked. `Parser.Options` has always had a branch for
	--> them and `OPTIONS` has always listed three, but no schema could reach it: the lexer rejected
	--> the value as an unexpected token before the parser saw the option at all.
	{ `^{NUMBER}`, "Number" },

	{ "^%(", "OpenParentheses" },
	{ "^%)", "CloseParentheses" },
	{ "^%[", "OpenBrackets" },
	{ "^%]", "CloseBrackets" },

	--> String patterns
	{
		'^""',
		function(_Token: string)
			return "String", ""
		end,
	},

	{
		[[^(['"]).-[^\](\*)%2%1]],
		function(Token: string)
			return "String", string.sub(Token, 2, #Token - 1)
		end,
	},

	{
		"^(['\"]).-.*",
		function(Token: string)
			return "String", string.sub(Token, 2)
		end,
	},

	--> Complex patterns
	{ "^[%w_]+%.[%w_%.]+", "Identifier" },
	{
		"^[%a_][%w_]*",
		function(Token: string)
			if Token == "import" then
				return "Import", Token
			elseif Token == "as" then
				return "As", Token
			elseif Keywords[Token] then
				return "Keyword", Token
			elseif Primitives[Token] then
				return "Primitive", Token
			elseif Booleans[Token] then
				return "Boolean", (Token == "true")
			end

			return "Identifier", Token
		end,
	},
}

local SKIPPED_TOKENS = {
	Comment = true,
	Whitespace = true,
}

local Lexer = {}
Lexer.__index = Lexer

export type Lexer = typeof(setmetatable(
	{} :: {
		Mode: Mode,
		Size: number,
		Source: string,
		Cursor: number,
	},
	Lexer
))

function Lexer.new(Mode: Mode?): Lexer
	return setmetatable(
		{
			Size = 0,
			Mode = Mode or "Parsing",
			Source = "",
			Cursor = 1,
		} :: any,
		Lexer
	)
end

function Lexer.Initialize(self: Lexer, Source: string)
	self.Size = #Source
	self.Source = Source
	self.Cursor = 1
end

function Lexer.GetNextToken(self: Lexer, DontAdvanceCursor: boolean?, StartAt: number?): Token
	if self.Cursor > self.Size then
		return {
			Type = "EndOfFile",
			Value = "",
			Start = #self.Source,
			End = #self.Source,
		}
	end

	local Source = self.Source
	local Position = StartAt or self.Cursor
	local IsHighlighting = (self.Mode == "Highlighting")

	local function Match(Pattern: string): (string?, number, number)
		local Start, End = string.find(Source, Pattern, Position)
		if not Start or not End then
			return nil, Position, Position
		end

		local Text = string.sub(Source, Start, End)
		return Text, Position, math.min(Position + #Text, self.Size)
	end

	for _, Rule in TOKENS do
		--> A rule is a fixed pair: the pattern, then either a type or a transformer (see TokenRule).
		local Pattern = Rule[1] :: string
		local Type = Rule[2] :: Types | TokenTransformer

		local Text, Start, End = Match(Pattern)

		--> Couldn't match this pattern, continue.
		if not Text then
			continue
		end

		if not DontAdvanceCursor or (SKIPPED_TOKENS[Type] and not IsHighlighting) then
			Position += #Text
			self.Cursor = Position
		end

		--> Whitespace matched, skip token.
		--> We don't want to skip whitespaces in highlighting mode.
		if SKIPPED_TOKENS[Type] and not IsHighlighting then
			return self:GetNextToken(DontAdvanceCursor)
		end

		local Value: string | boolean = Text
		if type(Type) == "function" then
			--> Only overwrite the type when highlighting
			local TrueType, TrueValue = Type(Text)

			Type = TrueType
			Value = if IsHighlighting then Text else TrueValue
		end

		return {
			Type = Type :: Types,
			--> `true`/`false` genuinely arrive here as booleans, which `Parser.Options` relies on when
			--> it stores an option straight into a boolean field. Every other reader treats `Value` as
			--> a string, so the cast keeps that widening in this one place instead of in the type.
			Value = Value :: string,
			Start = Start,
			End = End,
		}
	end

	if not IsHighlighting then
		Error.new(Error.LexerUnexpectedToken, self.Source, "Unexpected token")
			:Primary({ Start = self.Cursor, End = self.Cursor }, `Unexpected token`)
			:Emit()
	end

	--> Attempt to recover the lexer
	local Symbol = string.sub(self.Source, Position, Position)
	if DontAdvanceCursor ~= true then
		self.Cursor += 1
	end

	return {
		Type = "Unknown",
		Value = Symbol,
		Start = Position,
		End = Position,
	}
end

return Lexer
