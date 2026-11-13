--!strict
--- How a generated module comes up: where it finds its remotes, and when.
---
--- Two options change that, and nothing else in the generator needs to know about either:
---
--- `ClientConnectTimeout` bounds the client's wait for the remotes. The wait moves ahead of the
--- edit-mode stubs, and a client that times out returns those stubs with `Connected` false.
---
--- `AutoStart = false` keeps the server from creating its remotes, connecting them and connecting
--- its Heartbeat at require time; `Start` does all three. Until then the remotes are stand-ins, a
--- reliable send stops at SavePlayerBuffer and an invocation fails at once.
---
--- Without either option the templates come out exactly as they always did. The markers this file
--- splits on (`-- REMOTES --`, `-- STARTED --`) are removed whole, newline included.
local Connect = require("../Templates/Connect")
local Folder = require("./Folder")
local Start = require("../Templates/Start")
local State = require("./State")

local Parser = require("../Parser")
local Settings = require("../Settings")

local REMOTES = "-- REMOTES --\n"
local STARTED = "-- STARTED --\n"

local CLIENT = string.split(require("../Templates/Client"), "-- SPLIT --")

--> The client's run framing: consecutive events of one index in a batch travel under a shared
--> 3-byte header -- 255, the index, the count less one -- instead of a byte of index each, which is
--> where the wire's smallest packets lose their last spare byte. The write itself never shifts
--> bytes: each Fire's entry goes down whole, as it always did, and this runs after it. Three
--> same-index entries in a row turn into a run when the fourth arrives -- one copy of each body two
--> bytes right, three bytes cheaper -- and every member after that moves its body one byte left over
--> the index it will not need. Nothing after the batch's tail is ever moved, and the state travels
--> with the packet a run started in, so a Cut between two fires starts the next run rather than
--> splitting one.
local FRAMING = [[local RunIndex = -1
local RunCount = 0
local RunHead = 0
local RunTail = 0
local RunPacket = 0
local RunFirst = 0
local RunSecond = 0
local RunThird = 0

local function Frame(Start: number, Index: number, Packet: number): ()
    if Index ~= RunIndex or Start ~= RunTail or Packet ~= RunPacket or RunCount == 256 then
        RunIndex = Index
        RunCount = 1
        RunHead = Start
        RunPacket = Packet
        RunFirst = Start
        RunSecond = 0
        RunThird = 0
    elseif RunCount < 3 then
        if RunCount == 1 then
            RunSecond = Start
        else
            RunThird = Start
        end
        RunCount += 1
    elseif RunCount == 3 then
        local End = SendCursor
        local First = RunSecond - RunFirst - 1
        local Second = RunThird - RunSecond - 1
        local Third = Start - RunThird - 1
        local Fourth = End - Start - 1
        buffer.copy(SendBuffer, RunHead + 3 + First + Second + Third, SendBuffer, Start + 1, Fourth)
        buffer.copy(SendBuffer, RunHead + 3 + First, SendBuffer, RunSecond + 1, Second)
        buffer.copy(SendBuffer, RunHead + 3, SendBuffer, RunHead + 1, First)
        buffer.writeu8(SendBuffer, RunHead, 255)
        buffer.writeu8(SendBuffer, RunHead + 1, Index)
        buffer.writeu8(SendBuffer, RunHead + 2, 3)
        SendCursor = RunHead + 3 + First + Second + Third + Fourth
        RunCount = 4
    else
        local End = SendCursor
        local Body = End - Start - 1
        --> A buffer.copy call costs more than a small body is worth -- a run of one-byte events paid
        --> half again on its fire -- so the common widths move by read and write, and the copy is
        --> for the rest.
        if Body == 1 then
            buffer.writeu8(SendBuffer, RunTail, buffer.readu8(SendBuffer, Start + 1))
        elseif Body == 2 then
            buffer.writeu16(SendBuffer, RunTail, buffer.readu16(SendBuffer, Start + 1))
        elseif Body == 4 then
            buffer.writeu32(SendBuffer, RunTail, buffer.readu32(SendBuffer, Start + 1))
        else
            --> No u64: Roblox's buffer library stops at four bytes, and the generated module runs
            --> there, not only on LuneBlox.
            buffer.copy(SendBuffer, RunTail, SendBuffer, Start + 1, Body)
        end
        buffer.writeu8(SendBuffer, RunHead + 2, RunCount)
        SendCursor = RunTail + Body
        RunCount += 1
    end
    RunTail = SendCursor
end
]]
local SERVER = string.split(require("../Templates/Server"), "-- SPLIT --")
local LIMITS = require("../Templates/Limits")

local Lifecycle = {}

--- Whether this server module waits for `Start`.
function Lifecycle.Deferred(Context: string, Options: Parser.Options): boolean
	return Context == "Server" and Options.AutoStart == false
end

--- Whether this client module gives up on the remotes after a while.
function Lifecycle.Bounded(Context: string, Options: Parser.Options): boolean
	return Context == "Client" and Options.ClientConnectTimeout ~= nil
end

--- Prefixes every line that has anything on it.
local function Indent(Text: string, Prefix: string): string
	local Lines = string.split(Text, "\n")
	for Index, Line in Lines do
		if Line ~= "" then
			Lines[Index] = Prefix .. Line
		end
	end

	return table.concat(Lines, "\n")
end

--- The two halves of a context's runtime template, before and after the declarations.
function Lifecycle.Sources(Context: string, Options: Parser.Options): { string }
	if Context == "Client" then
		local Half = if State.UsesFraming
			then string.gsub(CLIENT[2], "%-%- FRAME %-%-", FRAMING)
			else string.gsub(CLIENT[2], "\n%-%- FRAME %-%-\n", "")
		local Parts = string.split(Half, REMOTES)
		local Lookup = Folder.Client(Parts[2], Options)
		if Lifecycle.Bounded(Context, Options) then
			--> ConnectRemotes has already found both, or the module returned before getting here.
			Lookup = "local Reliable: RemoteEvent = ConnectedReliable :: RemoteEvent\n"
				.. "local Unreliable: UnreliableRemoteEvent = ConnectedUnreliable :: UnreliableRemoteEvent\n"
		end

		return { CLIENT[1], Parts[1] .. Lookup .. Parts[3] }
	end

	local Deferred = Lifecycle.Deferred(Context, Options)
	local Remotes = string.split(SERVER[2], REMOTES)
	local Lookup = Folder.Server(Remotes[2], Options)
	if Deferred then
		Lookup = Start.Before .. Indent(Lookup, "    ") .. Start.After
	end

	--> SavePlayerBuffer comes first in the template's text, then InvokePlayer; they are found by the
	--> line in front of each marker rather than by that order, so a move in the template cannot swap
	--> their guards.
	local Rest = string.split(SERVER[3], STARTED)
	local Guarded = { Rest[1] }
	for Index = 2, #Rest do
		local Before = Rest[Index - 1]
		local Guard = if string.find(Before, "local function SavePlayerBuffer%(Player: Player%)\n$")
				or string.find(Before, "local function AppendShared%(.-%)\n$")
			then Start.Guard.SavePlayerBuffer
			else Start.Guard.InvokePlayer
		table.insert(Guarded, if Deferred then Guard .. Rest[Index] else Rest[Index])
	end

	--> The server template's second split marks where its limits go: after the remotes, before the
	--> PlayerRemoving handler that clears their tables. Templates/Limits.luau holds them.
	return { SERVER[1], Remotes[1] .. Lookup .. Remotes[3] .. LIMITS .. table.concat(Guarded) }
end

--- What goes ahead of the edit-mode stubs, and the condition that returns them.
function Lifecycle.Stubs(Context: string, Options: Parser.Options): ({ string }, string)
	if not Lifecycle.Bounded(Context, Options) then
		return {}, "if not RunService:IsRunning() then"
	end

	return {
		`local CONNECT_TIMEOUT = {Options.ClientConnectTimeout}\n`,
		Folder.Connect(Connect, Options),
	},
		"if not RunService:IsRunning() or not ConnectRemotes() then"
end

--- The members this module adds to its return table and to its stub table, one line each.
function Lifecycle.Members(Context: string, Options: Parser.Options, Casing: Settings.Cases): ({ string }, { string })
	local Returned = { `{Casing.Remotes} = REMOTE_NAMES,` }
	local Stubbed = { `{Casing.Remotes} = REMOTE_NAMES,` }

	if Lifecycle.Bounded(Context, Options) then
		table.insert(Returned, `{Casing.Connected} = true,`)
		table.insert(Stubbed, `{Casing.Connected} = false,`)
	end

	if Lifecycle.Deferred(Context, Options) then
		table.insert(Returned, `{Casing.Start} = Start,`)
		table.insert(Stubbed, `{Casing.Start} = NOOP,`)
	end

	return Returned, Stubbed
end

--- The stub an invocation gets. A client that could not connect fails the call at once, as a real
--- one fails on its timeout; edit mode keeps the no-op a story has always had.
function Lifecycle.InvokeStub(Context: string, Options: Parser.Options): string
	if Lifecycle.Bounded(Context, Options) then
		return "NOOP_INVOKE"
	end

	return "NOOP"
end

--- Declared in the stub table's preamble when InvokeStub asks for it.
Lifecycle.NOOP_INVOKE =
	'local NOOP_INVOKE = if RunService:IsRunning() then function() error("[BlinkBlox]: The client is not connected to a server, so there is nobody to invoke.") end else NOOP'

--- Wraps what connects the module -- the Heartbeat and both remotes' connections -- into `Listen`,
--- and puts `Start` after it. Everything else passes through.
function Lifecycle.Connections(Context: string, Options: Parser.Options, Lines: { string }): { string }
	if not Lifecycle.Deferred(Context, Options) then
		return Lines
	end

	return {
		"local function Listen()\n",
		Indent(table.concat(Lines), "\t"),
		"end\n",
		Start.Start,
	}
end

return Lifecycle
