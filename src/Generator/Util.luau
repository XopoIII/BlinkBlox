--!strict
local Grammar = require("../Modules/Grammar")
local Parser = require("../Parser")
local Signature = require("../Modules/Signature")

local LUAU_KEYWORDS = Grammar.LUAU_KEYWORDS

type Scope = Parser.Scope

local function GetScopePrefix(ReferenceScope: Scope?, Dots: boolean?, CurrentScope: Scope): string
	local Prefix = ""
	local WorkingScope: Scope? = ReferenceScope or CurrentScope
	while WorkingScope and WorkingScope.Name.Value ~= "" do
		Prefix = `{WorkingScope.Name.Value}{Dots and "." or "_"}` .. Prefix
		WorkingScope = WorkingScope.Parent
	end

	return Prefix
end

local function GetScopeIndent(CurrentScope: Scope): number
	return math.max(#string.split(GetScopePrefix(nil, true, CurrentScope), "."), 1)
end

local function GetTypesPath(Name: string, Write: boolean, CurrentScope: Scope): string
	return `SerdesFunctions.{GetScopePrefix(nil, false, CurrentScope)}{Write and "Write" or "Read"}{Name}`
end

local function GetExportName(Name: string, CurrentScope: Scope): string
	return `{GetScopePrefix(nil, false, CurrentScope)}{Name}`
end

local function GenerateEnumLiterals(Variants: { string }): string
	local Literals = {}
	for _, EnumItem in Variants do
		table.insert(Literals, `"{EnumItem}"`)
	end
	return `{table.concat(Literals, " | ")}`
end

--- Whether a name can be written bare, as a key or after a dot. A Luau keyword cannot, though it is a
--- legal field, flag or tag in a schema: emitted bare, `end` made `{ end: number }` and `Value.end`,
--- and the generated module failed to load.
local function IsValidIdentifier(Identifier: string): boolean
	return Identifier:match("%a%w*") == Identifier and not LUAU_KEYWORDS[Identifier]
end

--- A table key as it is written in a constructor: bare when it is an identifier, bracketed when a
--- schema named the field something Luau will not take unquoted.
local function FormatKey(Key: string): string
	if not IsValidIdentifier(Key) then
		return `["{Key}"]`
	end
	return Key
end

--- The same decision for an access rather than a constructor: `.Field` or `["odd field"]`.
local function FormatIndex(Index: string): string
	if not IsValidIdentifier(Index) then
		return `["{Index}"]`
	end
	return `.{Index}`
end

local function BitIndexToHex(Index: number): string
	return `0x{string.format("%x", 2 ^ Index)}`
end

--- The two constants the generated module opens with: the remote's name, and the signature of the
--- schema it was built from.
---
--- Routed through here rather than written inline because Generator/init.luau was over its size
--- limit when this was added. Nothing else about it wants to be separate.
---
--- The remotes are still named `BLINK_*` after the rename to BlinkBlox, and must stay so: the client
--- finds them by name, so a server and a client built by versions either side of a rename would never
--- meet -- the client would wait on a remote that does not exist, before the signature check that
--- would otherwise say what is wrong.
local function Constants(RemoteScope: string?, Tree: any): { string }
	local Scope = if RemoteScope then RemoteScope .. "_" else ""
	return {
		`local BASE_EVENT_NAME = "{Scope}BLINK"\n`,
		`local SCHEMA_SIGNATURE = "{Signature.Of(Tree)}"\n`,
	}
end

return {
	GetPath = GetTypesPath,
	GetExportName = GetExportName,
	GetScopePrefix = GetScopePrefix,
	GetScopeIndent = GetScopeIndent,
	GenerateEnumLiterals = GenerateEnumLiterals,
	Constants = Constants,

	FormatKey = FormatKey,
	FormatIndex = FormatIndex,
	BitIndexToHex = BitIndexToHex,
	IsValidIdentifier = IsValidIdentifier,
}
