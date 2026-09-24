--!strict
--- The editor's colours: as Color3 for the instances, and as hex for the rich-text markup the
--- highlighter writes.
local Highlight = require("./Highlight")

local THEME = {
	Text = Color3.fromHex("#FFFFFF"),
	Keyword = Color3.fromHex("#6796E6"),
	Primitive = Color3.fromHex("#4EC9B0"),
	Identifier = Color3.fromHex("#9CDCFE"),

	Class = Color3.fromHex("#B5CEA8"),
	Number = Color3.fromHex("#B5CEA8"),
	String = Color3.fromHex("#ADF195"),
	Bracket = Color3.fromHex("#FFFFFF"),
	Boolean = Color3.fromHex("#B5CEA8"),
	Comment = Color3.fromHex("#529955"),

	Error = Color3.fromHex("#FF5050"),
	Warning = Color3.fromHex("#D7BA7D"),

	Complete = Color3.fromHex("#04385f"),

	Line = {
		Active = Color3.fromHex("FFFFFF"),
		Inactive = Color3.fromHex("787878"),
	},
}

--> The same colours as hex, which is what rich-text markup takes. Built once: ToHex allocates, and
--> the highlighter asks for a colour per token.
local PALETTE: Highlight.Palette = {
	Text = THEME.Text:ToHex(),
	Keyword = THEME.Keyword:ToHex(),
	Primitive = THEME.Primitive:ToHex(),
	Identifier = THEME.Identifier:ToHex(),
	Class = THEME.Class:ToHex(),
	Number = THEME.Number:ToHex(),
	String = THEME.String:ToHex(),
	Bracket = THEME.Bracket:ToHex(),
	Boolean = THEME.Boolean:ToHex(),
	Comment = THEME.Comment:ToHex(),
	Error = THEME.Error:ToHex(),
}

return {
	THEME = THEME,
	PALETTE = PALETTE,
}
