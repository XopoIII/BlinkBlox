--!strict
--- Specs for what a stream puts on the wire and what the client makes of it: the packet's layout, the
--- server-time stamp across its 65536 ms wrap, clearing, a state that fails to send, and the schemas
--- the compiler refuses. The scheduler's timing is Streams.luau's.
local Assertions = require("./Assertions")
local ClientEnvironment = require("./Client")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local Support = require("./StreamSupport")
local task = require("@lune/task")

local RunClosure = Assertions.RunClosure
local Fresh, Frame, Frames, Expect, Heads = Support.Fresh, Support.Frame, Support.Frames, Support.Expect, Support.Heads

local ServerClock = ServerEnvironment.Services.Workspace
local ClientClock = ClientEnvironment.Services.Workspace

--- [event index][u16 sequence][presence bits][u16 stamp], then the state when there is one.
local HEADER = 6

RunClosure("A stream's stamp wraps at 65536 ms and the client unwraps it", function()
	local Pair = Fresh()
	local Received: { number } = {}
	Pair.Client.Heads.On(function(_Value, ServerTime: number)
		table.insert(Received, ServerTime)
	end)

	--> Three sends, forced with Urgent, at server times whose milliseconds straddle 3 * 65536 = 196608.
	--> The stamp is the milliseconds, rounded down, modulo 65536.
	local Packets = {}
	for _, Seconds in { 196.5, 196.59375, 196.75 } do
		ServerClock.Fixed = Seconds
		Pair.Server.Heads.Set(Heads(Seconds))
		Pair.Server.Heads.Urgent()
		local Sent = Frame(Pair)
		assert(#Sent == 1, `the send at {Seconds} s sent {#Sent} packets`)
		table.insert(Packets, Sent[1])
	end
	ServerClock.Fixed = nil

	local Stamps = {}
	for Index, Packet in Packets do
		Stamps[Index] = buffer.readu16(Packet.Buffer, 4)
	end
	Expect("stamps", Stamps, { 65428, 65521, 142 })

	--> The client's clock a little behind before the wrap, ahead of a stamp from before it, and behind
	--> one from after it: each comes back as the server's time to the millisecond.
	for Index, Client in { 196.375, 196.625, 196.625 } do
		ClientClock.Fixed = Client
		Pair.Deliver(Packets[Index])
	end
	ClientClock.Fixed = nil

	Expect("server times", Received, { 196500 / 1000, 196593 / 1000, 196750 / 1000 })
end)

RunClosure("A stream packet is its header, then the state", function()
	local Pair = Fresh()
	Pair.Server.Speed.Set(1.5)
	local Sent = Frame(Pair)
	assert(#Sent == 1, `sent {#Sent} packets, expected one`)

	local Packet = Sent[1].Buffer
	--> Speed is the second unreliable declaration, and this is the first packet the player got of it.
	Expect(
		"header",
		{ buffer.len(Packet), buffer.readu8(Packet, 0), buffer.readu16(Packet, 1), buffer.readu8(Packet, 3) },
		{ HEADER + 8, 1, 1, 1 }
	)
	assert(buffer.readf64(Packet, HEADER) == 1.5, `the state reads {buffer.readf64(Packet, HEADER)}, expected 1.5`)
end)

RunClosure("Clear sends nil once, and the stream is silent until the next Set", function()
	local Pair = Fresh()
	local Received: { string } = {}
	Pair.Client.Heads.On(function(Value)
		table.insert(Received, if Value == nil then "nil" else tostring(Value[1].At.X))
	end)

	Pair.Server.Heads.Set(Heads(7))
	Expect("frames before Clear", Frames(Pair, 3), { 1 })

	--> At the next step, whatever the rate: the clients should drop the state at once.
	Pair.Server.Heads.Clear()
	Expect("frames after Clear", Frames(Pair, 150), { 1 })

	local Cleared = Pair.Outbound[#Pair.Outbound].Buffer
	Expect("the clear's length and presence bits", { buffer.len(Cleared), buffer.readu8(Cleared, 3) }, { HEADER, 0 })

	Pair.Server.Heads.Set(Heads(8))
	Expect("frames after the next Set", Frames(Pair, 3), { 1 })

	for _, Packet in Pair.Outbound do
		Pair.Deliver(Packet)
	end
	Expect("states received", Received, { "7", "nil", "8" })
end)

RunClosure("Clearing a stream the clients never saw sends nothing", function()
	local Pair = Fresh()
	Pair.Server.Heads.Set(Heads(1))
	Pair.Server.Heads.Clear()
	Expect("frames that sent", Frames(Pair, 120), {})

	--> Cleared twice: the second has nothing left to tell.
	Pair.Server.Heads.Set(Heads(2))
	Expect("frames after Set", Frames(Pair, 1), { 1 })
	Pair.Server.Heads.Clear()
	Pair.Server.Heads.Clear()
	Expect("frames after two Clears", Frames(Pair, 120), { 1 })
end)

RunClosure("A Set after Clear in the same frame sends the state, not the clear", function()
	local Pair = Fresh()
	Pair.Server.Heads.Set(Heads(1))
	Expect("first frame", Frames(Pair, 1), { 1 })

	Pair.Server.Heads.Clear()
	Pair.Server.Heads.Set(Heads(2))
	local Sent = Frame(Pair)
	assert(#Sent == 1, `sent {#Sent} packets, expected one`)
	assert(buffer.readu8(Sent[1].Buffer, 3) == 1, "the packet was a clear, expected the state")
end)

RunClosure("An emptied set is a state, not a clear: sent, then kept alive", function()
	local Pair = Fresh()
	local Received: { string } = {}
	Pair.Client.Heads.On(function(Value)
		table.insert(Received, if Value == nil then "nil" else `#{#Value}`)
	end)

	--> Two frames of heads, then none: the empty list is a change, 7 sends it, 13 is the still state
	--> after the change, and 73 the keepalive a second after 13.
	local Sent = Frames(Pair, 75, function(Index)
		Pair.Server.Heads.Set(if Index <= 2 then Heads(Index) else {})
	end)
	Expect("frames that sent", Sent, { 1, 7, 13, 73 })

	local Empty = Pair.Outbound[2].Buffer
	--> Present, with a zero length after it: one byte more than the header, where a clear is none.
	Expect(
		"the empty list's length and presence bits",
		{ buffer.len(Empty), buffer.readu8(Empty, 3) },
		{ HEADER + 1, 1 }
	)

	for _, Packet in Pair.Outbound do
		Pair.Deliver(Packet)
	end
	Expect("states received", Received, { "#1", "#0", "#0", "#0" })
end)

RunClosure("A state that fails to send is reported and stops the stream", function()
	local Pair = Fresh()
	local Raised: { string } = {}
	Shared.Task.spawn = function(Function, ...)
		if Function == error then
			table.insert(Raised, tostring((...)))
			return nil :: any
		end

		return task.spawn(Function, ...)
	end

	--> Seventeen heads where the schema bounds the list at sixteen: refused on send, whatever the options.
	local TooMany = table.create(17, Heads(0)[1])
	Pair.Server.Heads.Set(TooMany)
	local Sent = Frames(Pair, 120)
	Shared.Task.spawn = nil :: any

	Expect("frames that sent", Sent, {})
	assert(#Raised == 1, `reported {#Raised} times, expected once`)
	assert(string.find(Raised[1], 'Stream "Heads" could not send its state:', 1, true), `reported as: {Raised[1]}`)

	Pair.Server.Heads.Set(Heads(3))
	Expect("frames after a good Set", Frames(Pair, 1), { 1 })
end)

--> Each refusal on its own, with the message that names it; the Invalid fixtures check the codes.
local STREAM = "event S {\n\tFrom: %s,\n\tType: %s,\n\tCall: %s,\n\tStream: { Rate: 10%s },\n\tData: %s\n}"
local REFUSED = {
	{ { "Client", "OrderedUnreliable", "SingleSync", "", "u8" }, 'Stream "S" is not sent by the server' },
	{ { "Server", "Unreliable", "SingleSync", "", "u8" }, 'Stream "S" is not OrderedUnreliable' },
	{ { "Server", "OrderedUnreliable", "Polling", "", "u8" }, 'Stream "S" cannot be polled' },
	{ { "Server", "OrderedUnreliable", "SingleSync", "", "u8?" }, 'Stream "S" streams an optional' },
	{ { "Server", "OrderedUnreliable", "SingleSync", "", "(u8, u8)" }, 'Stream "S" streams a type pack' },
	{ { "Server", "OrderedUnreliable", "SingleSync", ", Fast: 5", "u8" }, "has a Fast rate no faster than its Rate" },
	{ { "Server", "OrderedUnreliable", "SingleSync", ", Rat: 5", "u8" }, 'Unknown option "Rat"' },
	{ { "Server", "OrderedUnreliable", "SingleSync", "", "u8[975]" }, 'Unreliable event "S" cannot fit in one packet' },
}

RunClosure("The compiler refuses a stream it cannot schedule", function()
	for _, Case in REFUSED do
		local Fields, Message = Case[1], Case[2]
		local Source = string.format(STREAM, table.unpack(Fields))
		local Parsed, Failure = pcall(Isolated.Parse, Source)
		assert(not Parsed, `accepted:\n{Source}`)
		assert(string.find(tostring(Failure), Message, 1, true), `refused with "{Failure}", expected "{Message}"`)
	end

	--> And the largest state that fits: 980 bytes less the six of the header.
	local Fits = string.format(STREAM, "Server", "OrderedUnreliable", "SingleSync", "", "u8[974]")
	assert(pcall(Isolated.Parse, Fits), "refused a stream whose state fits exactly")
end)

return {}
