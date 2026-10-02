--!strict
--- The zap parser's place in its tokens, shared by the files that parse declarations and types.
---
--- Comments are stepped over wherever the grammar is being read and gathered as they pass, so the
--- declaration being parsed can take them along.
local Draft = require("../Draft")
local Lexer = require("./Lexer")

export type Token = Lexer.Token

export type Stream = {
	Source: string,
	Tokens: { Token },
	Index: number,
	--- Comments passed since a declaration last took them.
	Comments: { string },
	Draft: Draft.Draft,
	--- The declaration being parsed, for a note to name.
	Subject: string?,
}

local Stream = {}

function Stream.new(Source: string, Into: Draft.Draft): Stream
	return {
		Source = Source,
		Tokens = Lexer.Tokenise(Source),
		Index = 1,
		Comments = {},
		Draft = Into,
		Subject = nil,
	}
end

--- The token `Ahead` places on, comments not counted; 1, the default, is the next one.
function Stream.Peek(Self: Stream, Ahead: number?): Token
	local Remaining = Ahead or 1
	local Index = Self.Index
	while true do
		local Token = Self.Tokens[Index]
		if Token.Kind ~= "Comment" then
			Remaining -= 1
			if Remaining == 0 or Token.Kind == "End" then
				return Token
			end
		end

		Index += 1
	end
end

--- Steps over the comments at the current place, gathering them.
local function Gather(Self: Stream)
	while Self.Tokens[Self.Index].Kind == "Comment" do
		--> A block comment becomes one comment a line; one space after the dashes is the dashes' own.
		for _, Line in string.split(Self.Tokens[Self.Index].Text, "\n") do
			local Text = string.gsub(string.gsub(Line, "^ ", ""), "%s+$", "")
			table.insert(Self.Comments, Text)
		end

		Self.Index += 1
	end
end

function Stream.Next(Self: Stream): Token
	Gather(Self)

	local Token = Self.Tokens[Self.Index]
	if Token.Kind ~= "End" then
		Self.Index += 1
	end

	return Token
end

--- Whether the token `Ahead` places on is the word or symbol `Text`.
function Stream.Is(Self: Stream, Text: string, Ahead: number?): boolean
	local Token = Stream.Peek(Self, Ahead)
	return Token.Text == Text and (Token.Kind == "Word" or Token.Kind == "Symbol")
end

function Stream.Accept(Self: Stream, Text: string): boolean
	if Stream.Is(Self, Text) then
		Stream.Next(Self)
		return true
	end

	return false
end

function Stream.Fail(Token: Token, Expected: string): never
	local Found = if Token.Kind == "String" then `"{Token.Text}"` else Token.Text
	return error(`line {Token.Line}: expected {Expected}, found {Found}`, 0)
end

function Stream.Expect(Self: Stream, Text: string): Token
	local Token = Stream.Next(Self)
	if Token.Text ~= Text or (Token.Kind ~= "Word" and Token.Kind ~= "Symbol") then
		Stream.Fail(Token, `"{Text}"`)
	end

	return Token
end

--- The next token, which has to be a name.
function Stream.Word(Self: Stream, What: string): Token
	local Token = Stream.Next(Self)
	if Token.Kind ~= "Word" then
		Stream.Fail(Token, What)
	end

	return Token
end

--- The comments passed since the last call, which are then the caller's.
function Stream.TakeComments(Self: Stream): { string }
	Gather(Self)

	local Taken = Self.Comments
	Self.Comments = {}
	return Taken
end

function Stream.Note(Self: Stream, Severity: "Lossy" | "Dropped", Message: string, Line: number?)
	table.insert(Self.Draft.Notes, {
		Severity = Severity,
		Message = Message,
		Subject = Self.Subject,
		Line = Line,
	})
end

return Stream
