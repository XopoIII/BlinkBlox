--!strict
--- The table a server or client module returns, built one member a statement.
---
--- It used to be one table constructor holding every member the module has -- each event's Fire,
--- FireAll, FireList, FireExcept and On, every function's Invoke, every handler setter -- and the new
--- type solver gives up on an expression that large: "Code is too complex to typecheck". The module's
--- type is `typeof(Returns)`, so when it gave up, a game requiring the module was left with nothing it
--- could check: past about 200 events a Fire given a string for a u8 raised no error at all, which is
--- what games using other libraries reported as the new solver breaking their autocomplete. Each
--- member assigned on its own is a statement of its own, typed from its own annotations, and the old
--- solver reads the table the same way.
---
--- The members arrive as the lines the generator wrote for a constructor, one tab in: `Name = Value,`
--- for a member held in one line, `Name = {` down to `},` for one that holds a table. They are
--- rewritten into assignments, the table's lines one tab shallower. Anything else is a generator bug,
--- and is refused rather than written out as a module that does not load.
local Returns = {}

--- `Lines` as a sequence of `local Returns = {}`, one assignment a member, and the freeze.
function Returns.Assemble(Lines: { string }): { string }
	local Text = table.concat(Lines)
	local Rows = string.split(Text, "\n")
	local Output: { string } = { "\nlocal Returns = {}\n" }

	local Index = 1
	while Index <= #Rows do
		local Row = Rows[Index]
		if string.match(Row, "^%s*$") then
			Index += 1
			continue
		end

		local Name, Value = string.match(Row, "^\t([%a_][%w_]*) = (.*)$")
		if Name == nil or Value == nil then
			error(`[BlinkBlox]: the module's return table has a member the generator cannot assign: {Row}`)
		end

		if Value == "{" then
			table.insert(Output, `Returns.{Name} = \{\n`)
			Index += 1
			while Rows[Index] ~= "\t}," and Rows[Index] ~= "\t}" do
				local Nested = Rows[Index]
				if Nested == nil then
					error(`[BlinkBlox]: the member "{Name}" of the module's return table is never closed.`)
				end
				table.insert(Output, `{string.sub(Nested, 2)}\n`)
				Index += 1
			end
			table.insert(Output, "}\n")
		else
			table.insert(Output, `Returns.{Name} = {string.gsub(Value, ",$", "")}\n`)
		end
		Index += 1
	end

	table.insert(Output, "table.freeze(Returns)\n")
	return Output
end

return Returns
