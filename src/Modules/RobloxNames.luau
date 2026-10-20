--!strict
--- Refuses a top-level type named after a Roblox type the generated module uses.
---
--- A declared type is exported under its own name, and a Luau type alias shadows the global one for
--- the whole module: `type Player = Instance(Player)` emitted `export type Player = Player`, a type
--- that refers to itself, and every `Player: Player` parameter in the module then named the alias.
--- The module still ran -- types are erased -- but its strict type check failed.
---
--- A type inside a scope is exported with the scope's name in front, so only the top level can
--- collide. The classes named by `Instance(Class)` anywhere in the module, imports included, are
--- names it uses too.
local Error = require("./Error")
local Lexer = require("../Lexer")
local Walk = require("./Walk")

type Token = Lexer.Token
--- Structural stand-ins for the parser's nodes. Requiring the parser here would close a cycle.
type Declaration = any

--- The Roblox types every generated module names in its own signatures and serialisers.
local ROBLOX_TYPES = {
	Player = true,
	Instance = true,
	RemoteEvent = true,
	UnreliableRemoteEvent = true,
	CFrame = true,
	Vector3 = true,
	Color3 = true,
	DateTime = true,
	BrickColor = true,
}

--- Luau types a datatype's generated code names only when a schema uses that datatype, so a schema
--- that declared a type of one of these names before the datatypes existed still compiles.
local ROBLOX_TYPES_OF: { [string]: { string } } = {
	Enum = { "Enum", "EnumItem" },
	TweenInfo = { "Enum", "EnumItem" },
	ColorSequence = { "ColorSequenceKeypoint" },
	NumberSequence = { "NumberSequenceKeypoint" },
}

--- Every Roblox type name the module uses, its own and those the schema's datatypes bring.
local function Collect(Used: { [string]: boolean }, List: { Declaration })
	for _, Declaration in List do
		if Declaration.Type == "Scope" then
			Collect(Used, Declaration.Value.Values)
			continue
		end

		for _, Root in Walk.Roots(Declaration) do
			Walk.Type(Root, function(Node: Declaration)
				if Node.Type ~= "Primitive" then
					return
				end

				local Primitive = Node.Tokens.Primitive.Value
				--> An Enum's class is emitted as `Enum.Material`, under the global it cannot shadow.
				if Node.Value.Class and Primitive == "Instance" then
					Used[Node.Value.Class] = true
				end
				local Named: { string } = ROBLOX_TYPES_OF[Primitive] or {}
				for _, Name in Named do
					Used[Name] = true
				end
			end)
		end
	end
end

local function Check(Source: string, File: string?, Declarations: { Declaration })
	local Used: { [string]: boolean } = table.clone(ROBLOX_TYPES)
	Collect(Used, Declarations)

	for _, Declaration in Declarations do
		local Kind = Declaration.Type
		if Kind == "Scope" or Kind == "Event" or Kind == "Function" or not Used[Declaration.Name] then
			continue
		end

		--> A type node carries no token for its own name; the scope's symbol table holds it.
		local Scope = Declaration.Value.Scope
		local Symbol = Scope and Scope.Symbols.Types[Declaration.Name]
		local Identifier: Token? = Symbol and Symbol.Name
		local Diagnostic = Error.new(Error.AnalyzeReservedIdentifier, Source, `Reserved identifier`, File)
		if Identifier then
			Diagnostic:Primary(Identifier, `"{Declaration.Name}" is a Roblox type the generated module uses`)
		end

		Diagnostic:Note("A declared type is exported under its own name and would shadow it. Rename the declaration.")
			:Emit()
	end
end

return {
	Check = Check,
}
