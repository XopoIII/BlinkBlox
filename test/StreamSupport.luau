--!strict
--- What the stream specs share: a schema of streams, a fresh server and client built from it for each
--- spec, and a clock stepped by hand one frame at a time. Streams.luau checks the scheduler with it,
--- StreamPackets.luau what goes on the wire and what the client makes of it.
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local roblox = require("@lune/roblox")

local SCHEMA = [[
struct Head {
	Id: u8,
	At: vector,
	Back: boolean
}

event Heads {
	From: Server,
	Type: OrderedUnreliable,
	Call: SingleSync,
	Stream: { Rate: 10, Fast: 20, Keepalive: 1 },
	Data: Head[..16]
}

event Speed {
	From: Server,
	Type: OrderedUnreliable,
	Call: ManySync,
	Stream: { Rate: 10, Epsilon: 0.25 },
	Data: f64
}

event Aim {
	From: Server,
	Type: OrderedUnreliable,
	Call: SingleSync,
	Stream: { Rate: 10, Epsilon: 0.25 },
	Data: vector
}
]]

--- One Heartbeat at sixty frames a second.
local FRAME = 1 / 60

local Built = 0

--- A server and client of their own, so one spec's stream state is never another's. The first step
--- settles the streams' clock at the mock clock's time, whatever earlier specs advanced it to.
local function Fresh(): Isolated.Pair
	Built += 1
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), `STREAMS{Built}`)
	Pair.Server.StepReplication()
	return Pair
end

--- One frame: the clock moves on by FRAME and the server steps. The packets it sent.
local function Frame(Pair: Isolated.Pair): { Isolated.Outbound }
	local Before = #Pair.Outbound
	Shared.AdvanceClock(FRAME)
	Pair.Server.StepReplication()
	return { table.unpack(Pair.Outbound, Before + 1) }
end

--- `Count` frames, with `Each(Frame)` run before each step. The frames that sent, counting from 1.
--- With one player in the game a send is exactly one packet, so a frame that sent two fails here.
local function Frames(Pair: Isolated.Pair, Count: number, Each: ((Frame: number) -> ())?): { number }
	local Sent = {}
	for Index = 1, Count do
		if Each then
			Each(Index)
		end

		local Packets = Frame(Pair)
		assert(#Packets <= 1, `frame {Index} sent {#Packets} packets, expected at most one`)
		if #Packets == 1 then
			table.insert(Sent, Index)
		end
	end

	return Sent
end

--- Fails unless `Got` holds exactly `Expected`, in order.
local function Expect(What: string, Got: { any }, Expected: { any })
	local Left, Right = {}, {}
	for Index, Value in Got do
		Left[Index] = tostring(Value)
	end
	for Index, Value in Expected do
		Right[Index] = tostring(Value)
	end

	local Shown, Wanted = table.concat(Left, ", "), table.concat(Right, ", ")
	assert(Shown == Wanted, `{What}: got \{{Shown}\}, expected \{{Wanted}\}`)
end

--- A list of one head, `Id` 1 at `X` along the x axis: a new table each call, as a game builds one.
local function Heads(X: number): { any }
	return { { Id = 1, At = roblox.Vector3.new(X, 0, 0), Back = false } }
end

return {
	FRAME = FRAME,
	Fresh = Fresh,
	Frame = Frame,
	Frames = Frames,
	Expect = Expect,
	Heads = Heads,
	Vector = roblox.Vector3.new,
}
