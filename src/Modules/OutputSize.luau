--!strict
--- Whether a generated module has grown large enough to warn about.
---
--- A game using zap generated a module of about 72,000 lines, and Roblox timed out compiling it: the
--- script never ran, and the game had no networking at all (red-blox/zap #225; the same failure was
--- reported against Roblox as devforum 4637969). Nothing in BlinkBlox splits a module, and a schema at
--- its limit -- 256 declarations a channel -- stays well under that, but a schema of wide structs
--- can pass it. The warning comes at 50,000 lines, with room left before the size that failed.
---
--- Shared by the CLI and the Studio plugin, which both write what the generator returns.
local LIMIT = 50000

--- A warning for the module named `Name` when `Source` is past the limit, or nil.
local function Warning(Name: string, Source: string): string?
	local _, Lines = string.gsub(Source, "\n", "")
	if Lines <= LIMIT then
		return nil
	end

	return `The {Name} module is {Lines} lines long. Roblox has timed out compiling a generated module of about 72,000 lines, which left the game with no networking at all. Split the schema into several with RemoteScope before it gets that far.`
end

return {
	LIMIT = LIMIT,
	Warning = Warning,
}
