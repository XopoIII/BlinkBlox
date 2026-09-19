--!strict
--- Parses `@profile("...")` and decides what a compile under one profile keeps.
---
--- A statement marked with a profile is compiled only when that profile is active; a statement
--- without one always is. The point for this fork is the server: a debug remote left in a shipped
--- schema is surface a client can reach, and gating it keeps it out of every build nobody asked for.
---
--- An excluded declaration is still parsed and still registered, because a dev-only event may name a
--- dev-only type and has to resolve it. What exclusion does is keep the node out of the declaration
--- list the generator walks, and record it, so a declaration that IS compiled cannot reach one that is
--- not -- references are inlined at parse time, and an unchecked one would quietly carry the excluded
--- type into the build. Two declarations therefore cannot share a name across profiles.
---
--- Extracted from Parser.luau for the same reason as Modules/Options: the parser is on the size
--- ratchet in scripts/check-file-size.sh. It takes the same structural Reader, for the same reason.

---- Imports ----

local Error = require("./Error")
local Lexer = require("../Lexer")

---- Types ----

type Token = Lexer.Token

export type Profile = "dev" | "debug" | "test" | "release"

--- One per compilation, shared by the parser of every file it imports -- an excluded import excludes
--- what that file declares, and the file's own parser has to see that.
export type State = {
	Profile: Profile,

	--> The profile token of the attribute that excluded the statement being parsed now, or nil while
	--> it is compiled. Set by the outermost excluded statement; everything inside it inherits it.
	Excluding: Token?,

	--> An attribute read but not yet applied. The option block reads ahead of the declarations, so
	--> an attribute in front of the first declaration is read there and left here for it.
	Pending: Token?,

	--> Every declaration node parsed while excluded, with the attribute that excluded it.
	Excluded: { [any]: Token },
}

export type Reader = {
	Source: string,
	File: string?,
	Attributes: State,

	Peek: (self: any) -> Token,
	Consume: (self: any, Type: Lexer.Types) -> Token,
}

---- Constants ----

--> Closed, so a misspelt profile is an error rather than a statement that silently never compiles.
local PROFILES: { [string]: true } = {
	dev = true,
	debug = true,
	test = true,
	release = true,
}

--> Release, not dev. A statement marked dev is one somebody meant to keep out of a shipped game, and
--> a build that forgot the flag should leave it out rather than ship it.
local DEFAULT: Profile = "release"

local Attributes = {}

---- Public Functions ----

function Attributes.IsProfile(Name: string): boolean
	return PROFILES[Name] == true
end

function Attributes.new(Profile: string?): State
	local Name = Profile or DEFAULT
	assert(PROFILES[Name], `Unknown profile "{Name}", expected one of dev, debug, test or release`)

	return {
		Profile = Name :: Profile,
		Excluding = nil,
		Pending = nil,
		Excluded = {},
	}
end

--- Reads any attributes at the cursor into `Pending`, without applying them.
function Attributes.Read(Reader: Reader)
	local State = Reader.Attributes

	while Reader:Peek().Type == "Attribute" do
		local Name = Reader:Consume("Attribute")
		if Name.Value ~= "@profile" then
			Error.new(Error.AnalyzeUnknownAttribute, Reader.Source, `Unknown attribute "{Name.Value}"`, Reader.File)
				:Primary(Name, `Expected "@profile"`)
				:Emit()
		end

		Reader:Consume("OpenParentheses")
		local Profile = Reader:Consume("String")
		Reader:Consume("CloseParentheses")

		if not PROFILES[Profile.Value] then
			Error.new(Error.AnalyzeUnknownProfile, Reader.Source, `Unknown profile "{Profile.Value}"`, Reader.File)
				:Primary(Profile, `Expected one of "dev", "debug", "test" or "release"`)
				:Emit()
		end

		if State.Pending then
			Error.new(Error.AnalyzeMisplacedAttribute, Reader.Source, `Duplicate attribute`, Reader.File)
				:Primary(Profile, "A statement belongs to one profile")
				:Secondary(State.Pending, "Already given here")
				:Emit()
		end

		State.Pending = Profile
	end
end

--- Applies the pending attribute, if any, to the statement about to be parsed. Returns what
--- `Excluding` was before, for `Close` to restore.
function Attributes.Open(Reader: Reader): Token?
	Attributes.Read(Reader)

	local State = Reader.Attributes
	local Previous = State.Excluding
	local Pending = State.Pending
	if not Pending then
		return Previous
	end

	State.Pending = nil

	local Next = Reader:Peek()
	if Next.Type ~= "Keyword" and Next.Type ~= "Import" then
		Error.new(Error.AnalyzeMisplacedAttribute, Reader.Source, `Attribute without a statement`, Reader.File)
			:Primary(Pending, "Expected a declaration, import or option after this")
			:Emit()
	end

	if Previous == nil and Pending.Value ~= State.Profile then
		State.Excluding = Pending
	end

	return Previous
end

--- Closes the statement `Open` began: records it if it was excluded and appends it to `Into` if not.
function Attributes.Close(Reader: Reader, Previous: Token?, Declaration: any, Into: { any }?)
	local State = Reader.Attributes
	local Excluding = State.Excluding
	State.Excluding = Previous

	if Excluding then
		State.Excluded[Declaration] = Excluding
	elseif Into then
		table.insert(Into, Declaration)
	end
end

--- Refuses a reference from a compiled declaration to an excluded one.
function Attributes.Refer(Reader: Reader, Token: Token, To: any)
	local State = Reader.Attributes
	local Excluded = State.Excluded[To]
	if Excluded and State.Excluding == nil then
		Error.new(Error.AnalyzeExcludedReference, Reader.Source, `Reference to an excluded declaration`, Reader.File)
			:Primary(Token, `"{Token.Value}" is compiled only under profile "{Excluded.Value}"`)
			:Note(
				`This build uses profile "{State.Profile}". Give the declaration using it the same profile, or remove the attribute from the one it names.`
			)
			:Emit()
	end
end

return Attributes
