--!strict

local Grammar = require("./Grammar")
local stdio = require("@lune/stdio")

local function Style(text: any, style: stdio.Style): string
	return `{stdio.style(style)}{text}{stdio.style("reset")}`
end

local function Color(text: any, color: stdio.Color): string
	return `{stdio.color(color)}{text}{stdio.color("reset")}`
end

local function ShouldntWrap(value: any): boolean
	if type(value) ~= "string" then
		return false
	end

	if #value == 0 then
		return false
	end

	if string.find(value, "[^%d%a_]") then
		return false
	end

	if tonumber(string.sub(value, 1, 1)) then
		return false
	end

	if Grammar.LUAU_KEYWORDS[value] then
		return false
	end

	return true
end

local Cache
local INDENT = string.rep(" ", 3)

local function Noop() end

local Format: (Value: any, Filter: ((Value: any) -> boolean)?, Depth: number?) -> string

local function FormatNumber(Value: number): string
	if Value == math.huge then
		return Color("math.huge", "cyan")
	end
	if Value == -math.huge then
		return Color("-math.huge", "cyan")
	end
	return Color(Value, "cyan")
end

local function FormatTable(Value: any, FilterFunction: (Value: any) -> boolean, CurrentDepth: number): string
	local Address = string.match(tostring(Value), "0x[%w]+")
	if Cache[Value] then
		return `{Color("{CACHED}", "red")} {Style(Address, "dim")}`
	end

	local Tabs = string.rep(INDENT, CurrentDepth)
	local Newline = ("\n" .. INDENT .. Tabs)
	Cache[Value] = true

	local Parts = {}
	for Key, Entry in Value do
		if FilterFunction(Key) == false then
			continue
		end

		local KeyText = ShouldntWrap(Key) and Key or `["{Format(Key, FilterFunction, CurrentDepth + 1)}"]`
		table.insert(Parts, `{KeyText} = {Format(Entry, FilterFunction, CurrentDepth + 1)}`)
	end

	local Text = table.concat(Parts, Style(",", "dim") .. Newline)
	return Style(`\{ ({Address})`, "dim") .. Newline .. Text .. "\n" .. Tabs .. Style("}", "dim")
end

function Format(Value: any, Filter: ((Value: any) -> boolean)?, Depth: number?): string
	local CurrentDepth = Depth or 0
	local FilterFunction = (Filter or Noop) :: (Value: any) -> boolean

	if CurrentDepth == 0 then
		Cache = {}
	end

	if FilterFunction(Value) == false then
		return ""
	end

	local Type = type(Value)
	if Type == "string" then
		return Color(`"{Value}"`, "green")
	elseif Type == "number" then
		return FormatNumber(Value)
	elseif Type == "boolean" then
		return Color(Value, "yellow")
	elseif Type == "table" then
		return FormatTable(Value, FilterFunction, CurrentDepth)
	end

	return `<{Type}>`
end

return Format
