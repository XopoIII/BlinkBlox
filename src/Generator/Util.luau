--!strict
local Parser = require("../Parser")

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

local function IsValidIdentifier(Identifier: string): boolean
	return Identifier:match("%a%w*") == Identifier
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

return {
	GetPath = GetTypesPath,
	GetExportName = GetExportName,
	GetScopePrefix = GetScopePrefix,
	GetScopeIndent = GetScopeIndent,
	GenerateEnumLiterals = GenerateEnumLiterals,

	FormatKey = FormatKey,
	FormatIndex = FormatIndex,
	BitIndexToHex = BitIndexToHex,
	IsValidIdentifier = IsValidIdentifier,
}
