--!strict
--- Parses the `option` block at the top of a schema.
---
--- Extracted from Parser.luau, which is on the size ratchet in scripts/check-file-size.sh and has no
--- room to grow. It pairs with Modules/Grammar, which already held the table of which options exist
--- and what each one's value must lex as -- the shape was there and the code that reads it was not.
---
--- It takes a structural Reader rather than the Parser type, which is what keeps this out of a
--- require cycle: Parser requires this, so this cannot require Parser back. Anything with these
--- four members satisfies it, and the parser is the only thing that has them.

---- Imports ----

local Error = require("./Error")
local Grammar = require("./Grammar")
local Lexer = require("../Lexer")
local Settings = require("../Settings")

---- Types ----

type Token = Lexer.Token
type Options = Grammar.Options

--- The slice of the parser this needs: where it is reading, and enough of the source to render a
--- diagnostic against.
export type Reader = {
	Source: string,
	File: string?,

	Peek: (self: any) -> Token,
	Consume: (self: any, Type: Lexer.Types) -> Token,
	ConsumeAll: (self: any, ...Lexer.Types) -> ...Token,
}

---- Constants ----

local OPTIONS = Grammar.OPTIONS

local Utility = {}

---- Private Functions ----

--- Lists a table's keys for an "expected one of ..." line.
---
--- Built from the table being validated against rather than written out beside it, so the message
--- cannot fall out of step with the set it describes.
local function ListKeys(Of: { [string]: any }): string
	local Parts: { string } = {}
	for Key in Of do
		table.insert(Parts, `"{Key}"`)
	end

	return table.concat(Parts, " or ")
end

local function IsInteger(Number: number): boolean
	return (Number // 1) == Number
end

---- Public Functions ----

function Utility.Parse(Reader: Reader): Options
	local Options: Options = {}

	--> Read options until something that is not one. Bounding this loop by the number of KNOWN
	--> options -- as it used to be -- silently stopped parsing once that many `option` statements
	--> had been seen, duplicates included, and every option past the cut was reported as
	--> "Option set after start of file" instead of being applied.
	local Declared: { [string]: Token } = {}

	while Reader:Peek().Value == "option" do
		Reader:Consume("Keyword")
		local Key = Reader:ConsumeAll("Identifier", "Assign")
		local Name = Key.Value

		local Type: Lexer.Types = OPTIONS[Name]
		if not Type then
			Error.new(Error.ParserUnknownOption, Reader.Source, `Unknown option "{Name}"`, Reader.File)
				:Primary(Key, `Expected one of {ListKeys(OPTIONS)}`)
				:Emit()
		end

		local Previous = Declared[Name]
		if Previous then
			Error.new(Error.AnalyzeDuplicateOption, Reader.Source, `Duplicate option "{Name}"`, Reader.File)
				:Primary(Key, "Option set twice")
				:Secondary(Previous, "Already set here")
				:Emit()
		end

		Declared[Name] = Key

		--> Parsed since 0.14 and read by nothing since: no generator has ever looked at it. Warning
		--> rather than erroring keeps existing schemas compiling while they migrate.
		if Name == "UseColon" then
			Error.new(
				Error.AnalyzeDeprecatedOption,
				Reader.Source,
				`Option "UseColon" is deprecated`,
				Reader.File,
				"Warning"
			)
				:Primary(Key, "This option has no effect")
				:Note("No generator reads it. It will be removed in 1.0 -- delete the line.")
				:Warn()
		end

		local Value = Reader:Consume(Type)
		if Type == "Number" then
			--> Number tokens carry their text; every consumer of a numeric option wants the number.
			local Numeric = tonumber(Value.Value)
			if not Numeric or Numeric < 1 or not IsInteger(Numeric) then
				Error.new(Error.ParserUnknownOption, Reader.Source, `Invalid value for option "{Name}"`, Reader.File)
					:Primary(Value, "Expected a positive whole number")
					:Emit()
			end

			Options[Name] = Numeric
		else
			--> An unknown casing used to get all the way to the GENERATOR, which raised a plain Lua
			--> error mid-emit: no code, no source span, and a stack trace through the compiler in
			--> place of a line number. Every other bad option value is a diagnostic, and this is the
			--> last point at which the token is still around to point at.
			if Name == "Casing" and Settings.Casings[Value.Value] == nil then
				Error.new(Error.ParserUnknownOption, Reader.Source, `Invalid value for option "Casing"`, Reader.File)
					:Primary(Value, `Expected one of {ListKeys(Settings.Casings)}`)
					:Emit()
			end

			Options[Name] = Value.Value
		end
	end

	return Options
end

return Utility
