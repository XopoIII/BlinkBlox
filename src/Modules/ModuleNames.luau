--!strict
--- Refuses a top-level name the generated module already spends, in the spelling it spends it.
---
--- Module members follow `option Casing`: under `Camel` the module returns `stepReplication`, and a
--- top-level event, function or scope of that name became a second key in the same table, which
--- replaced the member. The parser's reserved check compares the declared name against the `Pascal`
--- spelling only, since it runs before anything asks which casing is in force, and no declaration
--- reached `SetReference` for a scope at all. So the spelling in force is checked here, for every kind.
---
--- The runtime also declares a few type aliases of its own. A top-level type is exported under its
--- own name into the same module, so one named after them redefined a type and failed the module's
--- strict check. They are spelled `BLINK_*` so that an ordinary schema never meets them.
local Error = require("./Error")
local Grammar = require("./Grammar")
local Lexer = require("../Lexer")
local Settings = require("../Settings")

type Token = Lexer.Token
--- Structural stand-ins for the parser's nodes. Requiring the parser here would close a cycle.
type Declaration = any

--- The type aliases the runtime templates declare (src/Templates) and the generator's own.
local MODULE_TYPES = {
	BLINK_ENTRY = true,
	BLINK_QUEUE = true,
	BLINK_BUFFER_SAVE = true,
	BLINK_INVOCATIONS = true,
	BLINK_DROP_REASON = true,
	BLINK_EVENTS_SYMBOL = true,
	BLINK_STREAM = true,
}

--- The token naming a top-level declaration, wherever its kind keeps it.
local function Identifier(Declaration: Declaration): Token?
	local Value = Declaration.Value
	if Declaration.Type == "Scope" then
		return Value.Scope and Value.Scope.Name
	elseif Declaration.Tokens and Declaration.Tokens.Identifier then
		return Declaration.Tokens.Identifier
	end

	local Scope = Value.Scope
	local Symbol = Scope and Scope.Symbols.Types[Declaration.Name]
	return Symbol and Symbol.Name
end

local function Refuse(Source: string, File: string?, Declaration: Declaration, Label: string, Note: string)
	local Diagnostic = Error.new(Error.AnalyzeReservedIdentifier, Source, `Reserved identifier`, File)
	local Token = Identifier(Declaration)
	if Token then
		Diagnostic:Primary(Token, Label)
	end

	Diagnostic:Note(Note):Emit()
end

local function Check(Source: string, File: string?, Declarations: { Declaration }, Options: any)
	local Casing = Settings.GetCasing((Options.Casing :: Settings.Case) or "Pascal")

	--> The members' names under the casing in force. The Pascal spelling is refused by the parser
	--> already, for every kind but a scope.
	local Members: { [string]: string } = {}
	for Member: string in Grammar.RESERVED :: { [string]: boolean } do
		Members[(Casing :: any)[Member]] = Member
	end

	for _, Declaration in Declarations do
		local Name = Declaration.Name
		local Kind = Declaration.Type
		local Member = Members[Name]

		if Member and (Name ~= Member or Kind == "Scope") then
			Refuse(
				Source,
				File,
				Declaration,
				`"{Name}" is the module's {Member}`,
				"A top-level declaration becomes a member of the module, and this one would replace it. Rename it."
			)
		elseif MODULE_TYPES[Name] and Kind ~= "Scope" and Kind ~= "Event" and Kind ~= "Function" then
			Refuse(
				Source,
				File,
				Declaration,
				`"{Name}" is a type the generated module declares`,
				"A declared type is exported under its own name and would redefine it. Rename the declaration."
			)
		end
	end
end

return {
	Check = Check,
}
