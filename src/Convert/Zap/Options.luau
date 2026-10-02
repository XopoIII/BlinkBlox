--!strict
--- zap's `opt` lines, as the options a schema writes.
---
--- Read against zap 0.6.29's `docs/config/options.md`. An option with no equivalent is left out and
--- noted, never carried over under a name that would mean something else.
local Stream = require("./Stream")

type Stream = Stream.Stream

--- What the declarations after the options need from them.
export type Settings = {
	--- `call_default`: the `call` of an event that writes none.
	Call: string?,
	--- `yield_type`, as a function's `Yield`.
	Yield: string,
}

type Read = { Name: string, Value: string, IsString: boolean, Line: number, Comments: { string } }

type Names = { [string]: string }

local PATHS: Names = { server_output = "ServerOutput", client_output = "ClientOutput", types_output = "TypesOutput" }
local BOOLEANS: Names = { typescript = "Typescript", manual_event_loop = "ManualReplication" }
local STRINGS: Names = { remote_scope = "RemoteScope", remote_folder = "RemotesFolder" }
local CASINGS: Names = { PascalCase = "Pascal", camelCase = "Camel", snake_case = "Snake" }
local YIELDS: Names = { yield = "Coroutine", future = "Future", promise = "Promise" }

local Options = {}

--- A string as a schema writes it. zap takes either quote, so the text may hold the other one.
local function Quote(Text: string): string
	return `"{string.gsub(Text, '"', "'")}"`
end

local function Parse(Self: Stream): { Read }
	local Found: { Read } = {}
	while Stream.Is(Self, "opt") and Stream.Is(Self, "=", 3) do
		local Comments = Stream.TakeComments(Self)
		Stream.Next(Self)
		local Name = Stream.Word(Self, "an option's name")
		Stream.Expect(Self, "=")

		local Value = Stream.Next(Self)
		if Value.Kind ~= "String" and Value.Kind ~= "Number" and Value.Text ~= "true" and Value.Text ~= "false" then
			Stream.Fail(Value, "a string, a number, true or false")
		end
		Stream.Accept(Self, ";")

		table.insert(Found, {
			Name = Name.Text,
			Value = Value.Text,
			IsString = Value.Kind == "String",
			Line = Name.Line,
			Comments = Comments,
		})
	end

	return Found
end

--- The schema option a zap option carries over to under another name, and its value there.
local function Carried(Option: Read): (string?, string)
	local Name, Value = Option.Name, Option.Value
	if PATHS[Name] then
		return PATHS[Name], Quote(Value)
	elseif STRINGS[Name] then
		return STRINGS[Name], Quote(Value)
	elseif BOOLEANS[Name] then
		return BOOLEANS[Name], Value
	elseif Name == "write_checks" then
		return "WriteValidations", Value
	elseif Name == "casing" and CASINGS[Value] then
		return "Casing", CASINGS[Value]
	end

	return nil, Value
end

--- Reads the options at the head of a config into the draft.
function Options.Read(Self: Stream): Settings
	local Into = Self.Draft.Options
	local Settings: Settings = { Call = nil, Yield = "Coroutine" }
	local Library: Read?
	local ChecksWrites = false
	local KeepsPaths = false

	for _, Option in Parse(Self) do
		local Name, Value = Option.Name, Option.Value
		local As, Written = Carried(Option)

		--> Said once, on the first: the paths are where zap's own modules are.
		if PATHS[Name] and not KeepsPaths then
			KeepsPaths = true
			table.insert(Option.Comments, "TODO(convert): zap writes its own modules to these paths; choose others.")
			Stream.Note(Self, "Lossy", "the output paths are zap's own: change them, or these modules replace zap's")
		end

		if As then
			ChecksWrites = ChecksWrites or As == "WriteValidations"
			table.insert(Into, { Name = As, Value = Written, Comments = Option.Comments })
		elseif Name == "call_default" then
			Settings.Call = Value
		elseif Name == "yield_type" and YIELDS[Value] then
			Settings.Yield = YIELDS[Value]
		elseif Name == "async_lib" then
			Library = Option
		else
			Stream.Note(Self, "Dropped", `opt {Name} has no equivalent and was left out`, Option.Line)
		end
	end

	--> zap checks what it writes unless told not to, and a schema does not unless told to.
	if not ChecksWrites then
		table.insert(Into, {
			Name = "WriteValidations",
			Value = "true",
			Comments = { "zap checks what it sends unless write_checks is false; a schema checks only when asked." },
		})
	end

	if Library and Settings.Yield ~= "Coroutine" then
		--> zap takes the whole `require(...)`; a schema takes what goes inside it.
		local Path = string.match(Library.Value, "^%s*require%s*%((.*)%)%s*$") or Library.Value
		table.insert(Into, { Name = `{Settings.Yield}Library`, Value = Quote(Path), Comments = Library.Comments })
	elseif Library then
		Stream.Note(Self, "Dropped", "opt async_lib was left out: no function yields through a library", Library.Line)
	end

	return Settings
end

return Options
