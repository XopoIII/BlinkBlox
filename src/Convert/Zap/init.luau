--!strict
--- A zap config read into a Draft: its options, then its types, events, functions and namespaces.
---
--- Follows zap 0.6.29's grammar (`zap/src/parser/grammar.lalrpop`). A config zap accepts is read
--- whole; one it would refuse fails here with the line, since a draft of half a config would look
--- like a whole one.
local Draft = require("./Draft")
local Options = require("@self/Options")
local Stream = require("@self/Stream")
local Types = require("@self/Types")

type Stream = Stream.Stream
type Declaration = Draft.Declaration

local Zap = {}

--- The version of zap whose grammar and options this reads.
Zap.VERSION = "0.6.29"

local Declarations: (Self: Stream, Settings: Options.Settings, Closing: string?) -> { Declaration }

--- Whether the parenthesis ahead opens a union, `(A | B)`, rather than a list of values.
local function IsUnion(Self: Stream): boolean
	local Depth = 0
	local Ahead = 1
	while true do
		local Token = Stream.Peek(Self, Ahead)
		if Token.Kind == "End" then
			return false
		elseif Token.Kind == "Symbol" then
			local Text = Token.Text
			if Text == "(" or Text == "{" or Text == "[" then
				Depth += 1
			elseif Text == ")" or Text == "}" or Text == "]" then
				Depth -= 1
				if Depth == 0 then
					return false
				end
			elseif Text == "|" and Depth == 1 then
				return true
			end
		end

		Ahead += 1
	end
end

--- An event's `data`, or a function's `args` or `rets`: one type, or values in parentheses that
--- may each be named.
local function Parameters(Self: Stream): Draft.Type?
	if not Stream.Is(Self, "(") or IsUnion(Self) then
		return Types.Parse(Self)
	end

	local Fields: { Draft.Field } = {}
	Stream.Expect(Self, "(")
	while not Stream.Is(Self, ")") do
		local Name: string?
		if Stream.Peek(Self).Kind == "Word" and Stream.Is(Self, ":", 2) then
			Name = Stream.Next(Self).Text
			Stream.Next(Self)
		end

		table.insert(Fields, { Name = Name, Type = Types.Parse(Self) })
		if not Stream.Accept(Self, ",") then
			break
		end
	end
	Stream.Expect(Self, ")")

	if #Fields == 0 then
		return nil
	elseif #Fields == 1 and Fields[1].Name == nil then
		return Fields[1].Type
	end

	return Draft.Tuple(Fields)
end

--- The `key: value` pairs between a declaration's braces, each handed to `Field`.
local function Braces(Self: Stream, Field: (Key: Stream.Token) -> ())
	Stream.Expect(Self, "{")
	while not Stream.Is(Self, "}") do
		local Key = Stream.Word(Self, "a field")
		Stream.Expect(Self, ":")
		Field(Key)
		if not Stream.Accept(Self, ",") then
			break
		end
	end
	Stream.Expect(Self, "}")
	Stream.Accept(Self, ";")
end

local function Event(Self: Stream, Name: string, Settings: Options.Settings): Declaration
	local Declaration: Declaration = {
		Kind = "Event",
		Name = Name,
		--> zap's own defaults: an event with no `type` is reliable.
		Reliability = "Reliable",
		Call = Settings.Call or "SingleSync",
	}

	Braces(Self, function(Key)
		if Key.Text == "from" then
			local Side = Stream.Word(Self, "Server or Client").Text
			Declaration.From = if Side == "Server" then "Server" else "Client"
		elseif Key.Text == "type" then
			local Kind = Stream.Word(Self, "Reliable, Unreliable or OrderedUnreliable").Text
			Declaration.Reliability = if Kind == "Unreliable"
				then "Unreliable"
				elseif Kind == "OrderedUnreliable" then "OrderedUnreliable"
				else "Reliable"
		elseif Key.Text == "call" then
			Declaration.Call = Stream.Word(Self, "how the event is heard").Text
		elseif Key.Text == "data" then
			Declaration.Data = Parameters(Self)
		else
			Stream.Fail(Key, "from, type, call or data")
		end
	end)

	return Declaration
end

local function Function(Self: Stream, Name: string, Settings: Options.Settings): Declaration
	--> zap's functions are a client asking the server; there is no other direction to declare.
	local Declaration: Declaration = { Kind = "Function", Name = Name, From = "Client", Yield = Settings.Yield }

	Braces(Self, function(Key)
		if Key.Text == "call" then
			Stream.Word(Self, "Async or Sync")
			Stream.Note(Self, "Dropped", "a funct's call (Async or Sync) has no equivalent and was left out", Key.Line)
		elseif Key.Text == "args" then
			Declaration.Data = Parameters(Self)
		elseif Key.Text == "rets" then
			Declaration.Return = Parameters(Self)
		else
			Stream.Fail(Key, "call, args or rets")
		end
	end)

	return Declaration
end

function Declarations(Self: Stream, Settings: Options.Settings, Closing: string?): { Declaration }
	local Body: { Declaration } = {}

	while true do
		local Comments = Stream.TakeComments(Self)
		local Keyword = Stream.Peek(Self)
		if Keyword.Kind == "End" or (Closing and Stream.Is(Self, Closing)) then
			return Body
		end

		Stream.Next(Self)
		local Name = Stream.Word(Self, "a name").Text
		Stream.Expect(Self, "=")

		local Outer = Self.Subject
		Self.Subject = Name

		local Declaration: Declaration
		if Keyword.Text == "type" then
			Declaration = { Kind = "Type", Name = Name, Type = Types.Parse(Self) }
			Stream.Accept(Self, ";")
		elseif Keyword.Text == "event" then
			Declaration = Event(Self, Name, Settings)
		elseif Keyword.Text == "funct" then
			Declaration = Function(Self, Name, Settings)
		elseif Keyword.Text == "namespace" then
			Stream.Expect(Self, "{")
			Declaration = { Kind = "Scope", Name = Name, Body = Declarations(Self, Settings, "}") }
			Stream.Expect(Self, "}")
		else
			Stream.Fail(Keyword, "type, event, funct or namespace")
		end

		--> Comments written inside a declaration are kept with it, after the ones above it. Those
		--> after its closing brace have not been reached yet, and go to what follows.
		table.move(Self.Comments, 1, #Self.Comments, #Comments + 1, Comments)
		Self.Comments = {}

		Self.Subject = Outer
		Declaration.Comments = Comments
		table.insert(Body, Declaration)
	end
end

--- Reads a zap config. Raises the line and what was expected when zap would not have read it.
function Zap.Parse(Source: string): Draft.Draft
	local Into = Draft.new("zap", Zap.VERSION)
	local Self = Stream.new(Source, Into)

	local Settings = Options.Read(Self)
	Into.Body = Declarations(Self, Settings, nil)
	return Into
end

return Zap
