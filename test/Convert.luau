--!strict
--- Specs for src/Convert/Print.luau on drafts built by hand: what the printer does with the things
--- no zap config can say, and the recording stubs' definitions will -- an event with no direction,
--- one with no stated reliability, a rate limit that was carried over.
local Assertions = require("./Assertions")
local Draft = require("@compiler/Convert/Draft")
local Harness = require("./Harness")
local Library = require("@compiler/Library")
local Print = require("@compiler/Convert/Print")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

local function Has(Text: string, Part: string): boolean
	return string.find(Text, Part, 1, true) ~= nil
end

RunClosure("Convert: an empty draft is a schema that compiles", function()
	local Text, Checklist = Print.Render(Draft.new("Tool", "1.0"))
	Library.Compile(Text)
	Check("Outputs", Has(table.concat(Checklist, "\n"), "Add option ServerOutput"), "no output paths were asked for")
end)

RunClosure("Convert: an event with no direction or reliability is marked, and still compiles", function()
	local Source = Draft.new("Tool", "1.0")
	table.insert(Source.Body, { Kind = "Event", Name = "Ping", Data = Draft.Primitive("u8") })

	local Text, Checklist = Print.Render(Source)
	local List = table.concat(Checklist, "\n")
	Check("From", Has(Text, "Tool does not say which side sends this"), Text)
	Check("Type", Has(Text, "Tool does not say whether this is reliable"), Text)
	Check("List", Has(List, "direction you must state: Ping") and Has(List, "reliability you must state: Ping"), List)
	--> Until the reader says otherwise it is a client's, so it is the kind that wants a rate.
	Check("Rate", Has(List, "1 event(s) a client fires with no Rate: Ping"), List)
	Library.Compile(Text)
end)

RunClosure("Convert: a rate the source carried is written, not asked for", function()
	local Source = Draft.new("Tool", "1.0")
	table.insert(Source.Body, { Kind = "Event", Name = "Ping", From = "Client", Reliability = "Reliable", Rate = "20" })

	local Text, Checklist = Print.Render(Source)
	Check("Rate", Has(Text, "Rate: 20"), Text)
	Check("List", not Has(table.concat(Checklist, "\n"), "with no Rate"), "a rated event was listed as unrated")
	Library.Compile(Text)
end)

RunClosure("Convert: a tuple, an optional and nested types print as a schema writes them", function()
	local Source = Draft.new("Tool", "1.0")
	table.insert(Source.Body, {
		Kind = "Type",
		Name = "Unit",
		Type = Draft.Struct({
			{ Name = "id", Type = Draft.Primitive("u16") },
			{ Name = "tags", Type = Draft.Array(Draft.Primitive("string", { Max = "8" }), { Max = "4" }) },
			{ Name = "owner", Type = Draft.Optional(Draft.Optional(Draft.Primitive("Instance(Player)"))) },
			{ Name = "kind", Type = Draft.Enum({ "Small", "Large" }) },
			{ Name = "stats", Type = Draft.Map(Draft.Primitive("string"), Draft.Primitive("u8")) },
		}),
	})
	table.insert(Source.Body, {
		Kind = "Function",
		Name = "Swap",
		From = "Server",
		Data = Draft.Tuple({ { Type = Draft.Reference("Unit") }, { Name = "slot", Type = Draft.Primitive("u8") } }),
		Return = Draft.Primitive("boolean"),
	})

	local Text = Print.Render(Source)
	Check("Array", Has(Text, "tags: string(..8)[..4]"), Text)
	Check("Optional", Has(Text, "owner: Instance(Player)?,"), Text)
	Check("Tuple", Has(Text, "Data: (Unit, slot: u8)"), Text)
	Check("From", Has(Text, "From: Server"), Text)
	Library.Compile(Text)
end)

return {}
