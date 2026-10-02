--!strict
--- Tokens of a zap config, as zap 0.6.29's grammar (`zap/src/parser/grammar.lalrpop`) cuts them.
---
--- Not src/Lexer.luau: that one is built on BlinkBlox's own keywords and joins a class, a range and
--- an array's brackets into single tokens, in an order its parser depends on. zap spells unions with
--- `|`, strings with `.utf8`, and classes with a dot, so it gets a scanner of its own.
---
--- Comments are tokens here, where zap discards them: the parser carries them over to the draft.

export type Kind = "Word" | "Number" | "String" | "Symbol" | "Comment" | "End"

export type Token = {
	Kind: Kind,
	--- A string without its quotes, a comment without its dashes; anything else as written.
	Text: string,
	Line: number,
	--- Where it starts and ends in the source, for quoting what could not be converted.
	Start: number,
	Finish: number,
}

local Lexer = {}

--- A comment starting at `Position`, when one does: its text and where it ends.
local function Comment(Source: string, Position: number): (string?, number)
	if string.sub(Source, Position, Position + 3) == "--[[" then
		local Close = string.find(Source, "]]", Position + 4, true)
		return string.sub(Source, Position + 4, if Close then Close - 1 else #Source),
			if Close then Close + 1 else #Source
	elseif string.sub(Source, Position, Position + 1) == "--" then
		local Finish = (string.find(Source, "\n", Position, true) or #Source + 1) - 1
		return string.sub(Source, Position + 2, Finish), Finish
	end

	return nil, Position
end

--- The token starting at `Position`, which is not whitespace: its kind, its text and where it ends.
local function Scan(Source: string, Position: number, Line: number): (Kind, string, number)
	local Remark, RemarkFinish = Comment(Source, Position)
	if Remark then
		return "Comment" :: Kind, Remark, RemarkFinish
	end

	local Character = string.sub(Source, Position, Position)
	if Character == '"' or Character == "'" then
		local Close = string.find(Source, Character, Position + 1, true)
		if not Close then
			error(`line {Line}: a string is never closed`, 0)
		end

		return "String" :: Kind, string.sub(Source, Position + 1, Close - 1), Close
	elseif string.match(Source, "^%-?%d", Position) then
		local _, Whole = string.find(Source, "^%-?%d+", Position)
		--> `0..100` is a number and a range, not `0.` and a stray dot.
		local _, Fraction = string.find(Source, "^%.%d+", (Whole :: number) + 1)
		local Finish = (Fraction or Whole) :: number
		return "Number" :: Kind, string.sub(Source, Position, Finish), Finish
	elseif string.match(Character, "[%a_]") then
		local _, Finish = string.find(Source, "^[%w_]+", Position)
		return "Word" :: Kind, string.sub(Source, Position, Finish :: number), Finish :: number
	elseif string.sub(Source, Position, Position + 1) == ".." then
		return "Symbol" :: Kind, "..", Position + 1
	end

	return "Symbol" :: Kind, Character, Position
end

function Lexer.Tokenise(Source: string): { Token }
	local Tokens: { Token } = {}
	local Position = 1
	local Line = 1
	local Length = #Source

	while Position <= Length do
		if string.match(Source, "^%s", Position) then
			Line += if string.sub(Source, Position, Position) == "\n" then 1 else 0
			Position += 1
			continue
		end

		local Found: Kind, Text: string, Finish: number = Scan(Source, Position, Line)
		local Token: Token = { Kind = Found, Text = Text, Line = Line, Start = Position, Finish = Finish }
		table.insert(Tokens, Token)

		--> A block comment and a string may span lines.
		local _, Breaks = string.gsub(string.sub(Source, Position, Finish), "\n", "")
		Line += Breaks
		Position = Finish + 1
	end

	table.insert(
		Tokens,
		{ Kind = "End", Text = "the end of the file", Line = Line, Start = Length + 1, Finish = Length }
	)
	return Tokens
end

return Lexer
