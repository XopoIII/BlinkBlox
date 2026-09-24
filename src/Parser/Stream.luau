--!strict
--!native
--!optimize 2

--- The token stream: looking at the next token and consuming it, with the diagnostics for
--- a token that is not the one the grammar expects.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Lexer = require("../Lexer")
local ParserClass = require("./Class")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type Primitive = ParserClass.Primitive

local Parser = ParserClass.Class

function Parser.Peek(self: Parser): Token
	local Token = self.LookAhead
	if not Token then
		error(
			Error.new(Error.ParserUnexpectedEndOfFile, self.Source, "Unexpected end of file", self.File)
				:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
				:Emit()
		)
	end

	return Token
end

function Parser.Consume(self: Parser, Type: Lexer.Types): Token
	local Token = self.LookAhead
	if not Token then
		Error.new(Error.ParserUnexpectedEndOfFile, self.Source, "Unexpected end of file", self.File)
			:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
			:Emit()

		--> Above already errors
		error("Unexpected end of file")
	end

	if Token.Type ~= Type then
		Error.new(Error.ParserUnexpectedToken, self.Source, `Unexpected token`, self.File)
			:Primary(Token, `Expected "{Type}", found "{Token.Type}"`)
			:Emit()
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

function Parser.TryConsume(self: Parser, Type: Lexer.Types): Token?
	local Token = self.LookAhead
	if not Token then
		return
	end

	if Token.Type ~= Type then
		return
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

function Parser.ConsumeAny(self: Parser, ...: Lexer.Types): Token
	local Types = { ... }
	for _, Type: Lexer.Types in Types do
		local Token = self:TryConsume(Type)
		if Token then
			return Token
		end
	end

	local Token = self:Peek()
	error(
		Error.new(Error.ParserUnexpectedToken, self.Source, `Unexpected token`, self.File)
			:Primary(Token, `Expected one of "{table.concat(Types, `", "`)}", found "{Token.Type}"`)
			:Emit()
	)
end

function Parser.ConsumeAll(self: Parser, ...: Lexer.Types): ...Token
	local Tokens = {}
	for _, Type: Lexer.Types in { ... } do
		table.insert(Tokens, self:Consume(Type))
	end

	return table.unpack(Tokens)
end

--> Used to consume identifiers without getting "Expected Identifier, got Keyword" errors
--> Boolean flag here is code smell but this codebase is already EOL and will soonish be replaced by the rewrite

function Parser.ConsumeText(self: Parser, ConsumePrimitives: boolean?, ConsumeStrings: boolean?): Token
	--> Get text token
	local Token: Token

	if ConsumeStrings and self:Peek().Type == "String" then
		Token = self:Consume("String")
	else
		if ConsumePrimitives then
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier", "Primitive")
		else
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier")
		end
	end

	--> Convert token to identifier token
	return {
		End = Token.End,
		Start = Token.Start,
		Type = "Identifier",
		Value = Token.Value,
	}
end

return Parser
