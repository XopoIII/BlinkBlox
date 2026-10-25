--!strict
--!native
--!optimize 2

--- How a module receives a packet: the two connections, the loop that decodes a packet's events, and
--- each channel's decoder, opened before the declarations add their branches and closed after.
local Blocks = require("./Blocks")
local Decode = require("./Decode")
local Fragments = require("./Fragments")
local Prefabs = require("./Prefabs")
local State = require("./State")
local Table = require("../Modules/Table")
local Traffic = require("./Traffic")

local EVENT_BODY = Fragments.EVENT_BODY
local EVENT_SYNC_VALIDATION = Fragments.EVENT_SYNC_VALIDATION

local Packets = {}

--- The reliable remote's connection and the unreliable one's, up to where a packet is decoded.
function Packets.Connections(): (Blocks.Block, Blocks.Block)
	local Signal = State.Context == "Client" and "OnClientEvent" or "OnServerEvent"
	local Arguments = (State.Context == "Server" and "Player: Player, " or "")
		.. "Buffer: buffer, Instances: {Instance}"

	local ReliableConnection = Blocks.Connection(`Reliable.{Signal}`, Arguments)
	local UnreliableConnection = Blocks.Connection(`Unreliable.{Signal}`, Arguments)

	--> Reject a hostile packet before any of it is parsed; see Fragments.InboundGuard.
	if State.Context == "Server" then
		local Guard = Fragments.InboundGuard(State.Options)
		ReliableConnection:Lines(Guard, 1)
		UnreliableConnection:Lines(Guard, 1)
	end

	ReliableConnection:Lines(EVENT_BODY, 1)
	UnreliableConnection:Lines(EVENT_BODY, 1)
	Traffic.Packet(ReliableConnection, false)
	Traffic.Packet(UnreliableConnection, true)

	if State.Options.SyncValidation then
		ReliableConnection:Lines(EVENT_SYNC_VALIDATION, 1)
		UnreliableConnection:Lines(EVENT_SYNC_VALIDATION, 1)
	end

	return ReliableConnection, UnreliableConnection
end

--> The loop over one packet's events: the head of each turn, which on the server stops the packet at
--> MaxEventsPerPacket and reports it. A channel whose events read no Instance and run no loop holds
--> the loop in its decoder; the others are handed to `DecodeLoop`, made once for the module only when
--> one is (see CloseDecode below).
local function LoopHead(MaxEvents: number, Indent: string): { string }
	if State.Context ~= "Server" then
		return {}
	end
	return {
		`{Indent}if DecodeRemaining == 0 then\n`,
		`{Indent}\tReportDrop(Player, "Events", {MaxEvents})\n`,
		`{Indent}\tbreak\n`,
		`{Indent}end\n`,
		`{Indent}DecodeRemaining -= 1\n`,
	}
end

--> What one packet's decode keeps between events lives in the module, as the cursor does, so no
--> packet allocates anything to decode:
--> - `Decoding`, the index of the event being read, for a failure to name it, or `-2 - Index` while
-->   that event's Sync listener runs (Listeners.Call);
--> - `DecodeRemaining`, the events the packet may still decode before MaxEventsPerPacket.
-->
--> Whether the player is still in the game is asked once a packet, by InboundAccept before it is
--> decoded, and again after a listener throws. It was asked before every event, which cost a property
--> read an event to spare the rare packet whose listener removes its own player: the rest of that
--> packet, MaxEventsPerPacket at most, reaches listeners with a Player already gone, as a packet
--> already queued when the player leaves always has.
function Packets.DecodeLoop(MaxEvents: number): { string }
	local OnServer = State.Context == "Server"
	local Lines = { "local Decoding = -1\n" }
	if OnServer then
		table.insert(Lines, `local DecodeRemaining = {MaxEvents}\n`)
	end
	if not (State.Channels.Reliable.Called or State.Channels.Unreliable.Called) then
		return Lines
	end

	return Table.Merge(
		Lines,
		{
			if OnServer
				then "local function DecodeLoop(DecodeEvent: (Player: Player) -> (), Player: Player, Size: number)\n"
				else "local function DecodeLoop(DecodeEvent: () -> (), Size: number)\n",
			"\twhile RecieveCursor < Size do\n",
		},
		LoopHead(MaxEvents, "\t\t"),
		{
			if OnServer then "\t\tDecodeEvent(Player)\n" else "\t\tDecodeEvent()\n",
			"\tend\n",
			"end\n",
		}
	)
end

--> A TRUNCATED packet defeats every limit above, because it is SMALLER than a legitimate one: two
--> bytes tagged as a five-byte event make `buffer.readu16` throw from inside the remote's
--> connection, where no user pcall can reach it. `Read` advances the cursor without a bounds
--> check, so the only place to contain that is around the decode itself. The cursor is wherever
--> the throw left it afterwards, so the packet cannot be resumed -- hence `break` rather than
--> `continue`.
-->
--> BOTH sides, not just the server. The client cannot be attacked this way, but it can still be
--> handed a packet it cannot parse: a listener that yields in a Sync call leaves the module-level
--> cursor pointing mid-event, and a client built from a different schema than the server decodes
--> every index one event out. Without this the user gets a raw `buffer access out of bounds` from
--> inside OnClientEvent, which is what upstream issue #26 and the devforum report were.
-->
--> Each event is decoded by one call of the channel's decoder, and the loop making those calls runs
--> under one pcall for the whole packet. The decoder is a function of the module, made once. It was
--> a closure written inside the loop, which allocated one and its upvalues for every event -- a
--> quarter of what a one-byte event cost the server to decode -- and then one for every packet.
--> A loop with the dispatch inside it, one call a packet, was measured twice. Under Roblox's flags
--> before client 0.744 it compiled to slower native code, a hundred events carrying a part decoding
--> in 0.015 ms rather than 0.012. With linearisation back (LuneBlox 0.11.2) it decodes small events
--> faster -- a thousand one-byte events in 0.050 ms natively rather than 0.056, a broadcast 5%
--> faster -- but those hundred events with a part still in 0.0154 ms rather than 0.0128, ABBA on an
--> M1; nothing may get slower, so the decoder stays a function called once an event.
--> `Decoding` carries the index out of the pcall, so a failure can name the event it happened in.
--> It is reset before the index is read: a listener that yields, or decodes another packet, can
--> leave the cursor past the end of the one this loop holds, and that failure must be the packet's,
--> named after no event -- not the listener's, whose mark would otherwise still stand, and whose
--> error goes on with the next event, which would be the same unreadable byte again. The index is
--> read in place rather than through `Read`, a call an event.
function Packets.OpenDecode(Name: string): Blocks.Block
	local DecoderArguments = if State.Context == "Server" then "Player: Player" else ""
	local Decoder = Blocks.Function(`Decode{Name}`, DecoderArguments, "()", false, true)
	Decoder:Line("Decoding = -1")
	Decoder:Line("local Index = buffer.readu8(RecieveBuffer, RecieveCursor)")
	Decoder:Line("RecieveCursor += 1")
	Decoder:Line("Decoding = Index")
	return Decoder
end

--> An unknown event index means the packet is not what it claims to be: the byte came from a
--> client, and the cursor is no longer at an event boundary, so nothing after it can be trusted.
--> Without this branch the loop silently fell through and kept reading, which is how a buffer of
--> unrecognised tags turned into a full-length parse.
--> `error` and not `break`: this branch sits inside the pcall'd decode function opened above, and
--> Luau cannot break out of a loop across a function boundary. Raising here lands in that pcall,
--> which turns into the `break` below — the same stop, expressed where it is legal.
local UNKNOWN_EVENT = `error("[BlinkBlox]: Unknown event index.")`

--> A channel this side receives nothing on has no branch to hang that on, and its index read
--> alone never failed: junk was consumed byte by byte up to MaxEventsPerPacket, unreported. The
--> connection itself stays, since a remote nobody connects to queues whatever is sent to it.
function Packets.CloseIndex(Channel: Blocks.Block, Branches: { State.Branch }): Blocks.Block
	if #Branches == 0 then
		return Channel:Line(`error("[BlinkBlox]: This channel receives no events.")`)
	end

	return Decode.Close(Channel, Branches, UNKNOWN_EVENT)
end

--> Close the decode function opened above, then decode the packet one event at a time. What is
--> said about a failure, and to whom, is ReportDecodeFailure's business: the server is silent
--> unless the game installed a handler, the client warns. See the two templates.
-->
--> The pcall is around the loop rather than around each event. A failure stops the packet either
--> way -- the cursor is wherever the throw left it -- so one pcall a packet stops it at the same
--> event, and a pcall an event had cost a one-byte event more than its decode did. `return` inside
--> an event's branch still leaves only that event, because it returns from the decoder.
-->
--> A Sync listener received here is called without a pcall of its own (Listeners.Call), with
--> `Decoding` at `-2 - Index` while it runs: when the packet's pcall catches an error with it
--> there, the listener threw, not the packet, and it is reported as a listener error was -- to
--> the game's handler or raised on a thread of its own -- and the decode goes on from the next
--> event, where the cursor already is. A packet's listeners that throw nothing cost no pcall each;
--> one that throws costs one more for the rest of its packet.
--> The shape of a channel's decoder, measured on LuneBlox 0.11.2 with Roblox's flags, ABBA on an M1.
--> Holding the loop -- one call a packet -- decodes a thousand one-byte events in 0.050 ms natively
--> rather than 0.056 and a broadcast 5% faster, but a hundred events carrying a part in 0.0154 ms
--> rather than 0.0128, and a thousand random arrays of structs in 4.07 ms rather than 3.92 (the median
--> of thirteen pairs, ten of them slower): an event's own loop compiles to slower native code nested
--> in the packet's. Interpreted, the shapes tie. So a channel whose events read no Instance and run
--> no loop (Decode.Open) holds the packet's loop, and any other stays a function `DecodeLoop` calls
--> once an event. Each turn of the held loop starts as `DecodeLoop`'s does, and a branch's
--> State.NEXT_EVENT becomes `continue` there and `return` in a function: either way the packet goes
--> on with its next event.
local NEXT_EVENT_PATTERN = string.gsub(State.NEXT_EVENT, "%p", "%%%0")

local function Shape(Decoder: Blocks.Block, Name: string, MaxEvents: number): boolean
	local Holds = not State.Channels[Name].Called
	local NextEvent = if Holds then "continue" else "return"
	for Index, Line in Decoder.Content do
		Decoder.Content[Index] = string.gsub(Line, NEXT_EVENT_PATTERN, NextEvent)
	end
	if not Holds then
		return false
	end

	local Body = table.move(Decoder.Content, 2, #Decoder.Content, 1, {})
	table.clear(Decoder.Content)
	local Parameters = if State.Context == "Server" then "Player: Player, Size: number" else "Size: number"
	table.insert(Decoder.Content, `local function Decode{Name}({Parameters}): ()\n`)
	table.insert(Decoder.Content, "\twhile RecieveCursor < Size do\n")
	for _, Line in LoopHead(MaxEvents, "\t\t") do
		table.insert(Decoder.Content, Line)
	end
	for _, Line in Body do
		table.insert(Decoder.Content, (string.gsub(Line, "([^\n]+)", "\t%1")))
	end
	table.insert(Decoder.Content, "\tend\n")
	return true
end

function Packets.CloseDecode(
	Decoder: Blocks.Block,
	Connection: Blocks.Block,
	Name: string,
	MaxEvents: number
): Blocks.Block
	local OnServer = State.Context == "Server"
	local Holds = Shape(Decoder, Name, MaxEvents)
	Decoder:End()
	local Sender = if OnServer then `Player, "{Name}", ` else ""
	local Callee = if Holds then `Decode{Name}` else `DecodeLoop, Decode{Name}`
	local LoopArguments = if OnServer then `{Callee}, Player, Size` else `{Callee}, Size`
	if OnServer then
		Connection:Line(`DecodeRemaining = {MaxEvents}`)
	end
	Connection:Line("Decoding = -1")
	--> A packet that failed after a read raised the flag, and before its event's check cleared it,
	--> must not refuse the first event of the next one.
	if Prefabs.Missing.Count > 0 then
		Connection:Line("MissingInstance = false")
	end
	Connection:Line("while true do")
	Connection:Line(`\tlocal Parsed: boolean, Failure: any = pcall({LoopArguments})`)
	Connection:Line("\tif Parsed then")
	Connection:Line("\t\tbreak")
	Connection:Line("\tend")
	--> An event refused for an Instance that did not arrive: its reader raised the signal once its
	--> payload was read, so the cursor is at the next event and the packet goes on from there.
	if Prefabs.Missing.Count > 0 then
		Connection:Line("\tif Failure == MISSING_SIGNAL then")
		if OnServer then
			Connection:Line(`\t\tReportDecodeFailure({Sender}EventNames.{Name}[Decoding], MISSING_INSTANCE)`)
		else
			Connection:Line(`\t\tReportMissingInstance(EventNames.{Name}[Decoding])`)
		end
		Connection:Line("\t\tcontinue")
		Connection:Line("\tend")
	end
	Connection:Line("\tif Decoding > -2 then")
	Connection:Line(`\t\tReportDecodeFailure({Sender}EventNames.{Name}[Decoding], Failure)`)
	Connection:Line("\t\tbreak")
	Connection:Line("\tend")
	Connection:Line(`\tlocal Listening = EventNames.{Name}[-2 - Decoding]`)
	if OnServer then
		Connection:Line("\tif not ListenerFailed(Player, Listening, Failure) then")
		Connection:Line("\t\ttask.spawn(error, Failure, 0)")
		Connection:Line("\tend")
		Connection:Line("\tif Player.Parent == nil then")
		Connection:Line("\t\tbreak")
		Connection:Line("\tend")
	else
		Connection:Line("\ttask.spawn(error, Failure, 0)")
	end
	Connection:Line("end")
	return Connection:End()
end

return Packets
