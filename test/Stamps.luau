--!strict
--- Specs for `Stamp` (docs/src/content/docs/language/stamps.mdx): what a stamped event puts on the
--- wire, the `SentAt` the server's listener receives -- exact inside the window, held to its edges
--- outside it, unwrapped across the 65536 ms the stamp wraps at -- and the schemas the compiler refuses.
local Assertions = require("./Assertions")
local ClientEnvironment = require("./Client")
local Generator = require("@compiler/Generator")
local Isolated = require("./Isolated")
local ServerEnvironment = require("./Server")
local roblox = require("@lune/roblox")

local RunClosure = Assertions.RunClosure

local ServerClock = ServerEnvironment.Services.Workspace
local ClientClock = ClientEnvironment.Services.Workspace

local SCHEMA = [[
event Kick {
	From: Client,
	Type: Reliable,
	Call: SingleSync,
	Rate: 1000,
	Stamp: 250
}

event Aim {
	From: Client,
	Type: Unreliable,
	Call: ManySync,
	Rate: 1000,
	Stamp: 100,
	Data: (Target: u8, vector)
}
]]

local Built = 0

local function Fresh(): Isolated.Pair
	Built += 1
	return Isolated.Build(Isolated.Parse(SCHEMA), `STAMPS{Built}`)
end

--- Fires Kick with the client's clock at `Client` seconds and delivers it with the server's at
--- `Server`. What the listener received: the argument count and SentAt.
local function Kick(Pair: Isolated.Pair, Client: number, Server: number): (number, number?)
	local Count, SentAt = -1, nil
	Pair.Server.Kick.On(function(...)
		Count = select("#", ...)
		SentAt = select(2, ...)
	end)

	ClientClock.Fixed = Client
	Pair.Client.Kick.Fire()
	Pair.Client.StepReplication()
	ClientClock.Fixed = nil

	local Packet = Pair.Sent[#Pair.Sent]
	ServerClock.Fixed = Server
	Pair.Feed(true, Packet.Buffer, Packet.Instances)
	ServerClock.Fixed = nil

	return Count, SentAt
end

RunClosure("A stamped event carries the client's send time, and the listener gets it in seconds", function()
	local Pair = Fresh()
	local Count, SentAt = Kick(Pair, 1000.5, 1000.6)

	--> [event index][u16 stamp]: the client's milliseconds, modulo 65536, and nothing else.
	local Packet = Pair.Sent[1].Buffer
	assert(buffer.len(Packet) == 3, `the packet is {buffer.len(Packet)} bytes, expected 3`)
	assert(buffer.readu8(Packet, 0) == 0, `the event index is {buffer.readu8(Packet, 0)}, expected 0`)
	local Stamp = buffer.readu16(Packet, 1)
	assert(Stamp == 1000500 % 65536, `the stamp is {Stamp}, expected {1000500 % 65536}`)

	assert(Count == 2, `the listener got {Count} arguments, expected the player and SentAt`)
	assert(SentAt == 1000.5, `SentAt is {SentAt}, expected 1000.5`)
end)

RunClosure("SentAt is held between the window's start and the moment the event arrived", function()
	--> Five seconds before the server's clock: a lie or a very late packet, held to 250 ms back.
	local _, Stale = Kick(Fresh(), 995, 1000)
	assert(Stale == 999.75, `a stamp 5 s old gave {Stale}, expected 999.75`)

	--> After the server's clock: nobody acts in the future.
	local _, Ahead = Kick(Fresh(), 1000.3, 1000)
	assert(Ahead == 1000, `a stamp 300 ms ahead gave {Ahead}, expected 1000`)

	--> Exactly at the window's edge, and just inside it: both are the client's word.
	local _, Edge = Kick(Fresh(), 999.75, 1000)
	assert(Edge == 999.75, `a stamp at the edge gave {Edge}, expected 999.75`)
	local _, Inside = Kick(Fresh(), 999.9, 1000)
	assert(Inside == 999.9, `a stamp 100 ms back gave {Inside}, expected 999.9`)
end)

RunClosure("A stamp unwraps across the 65536 ms it wraps at", function()
	--> 196608 ms is 3 * 65536. Sent before the wrap and received after it, the stamp is 65528 and
	--> the server's own milliseconds modulo 65536 are 92: it has to come back 100 ms ago, not 65 s on.
	local _, Before = Kick(Fresh(), 196.6, 196.7)
	assert(Before == 196.6, `sent before the wrap: {Before}, expected 196.6`)

	--> Both after it.
	local _, After = Kick(Fresh(), 196.65, 196.7)
	assert(After == 196.65, `sent after the wrap: {After}, expected 196.65`)

	--> Both before it, the server a hair short of the wrap.
	local _, Short = Kick(Fresh(), 196.5, 196.6)
	assert(Short == 196.5, `both before the wrap: {Short}, expected 196.5`)
end)

RunClosure("A stamped event's values arrive before SentAt, and its Fire takes only them", function()
	local Pair = Fresh()
	local Got: { any } = {}
	Pair.Server.Aim.On(function(...)
		Got = table.pack(...)
	end)

	ClientClock.Fixed = 50.25
	Pair.Client.Aim.Fire(7, roblox.Vector3.new(1, 2, 3))
	ClientClock.Fixed = nil

	local Packet = Pair.SentUnreliable[1]
	ServerClock.Fixed = 50.3
	Pair.Feed(false, Packet.Buffer, Packet.Instances)
	ServerClock.Fixed = nil

	assert(Got.n == 4, `the listener got {Got.n} arguments, expected the player, Target, the vector and SentAt`)
	assert(Got[2] == 7, `Target is {Got[2]}, expected 7`)
	assert(Got[3].X == 1 and Got[3].Y == 2 and Got[3].Z == 3, `the vector is {Got[3]}, expected 1, 2, 3`)
	assert(Got[4] == 50.25, `SentAt is {Got[4]}, expected 50.25`)
end)

RunClosure("TypeScript types a stamped Fire without the stamp, and its listener with SentAt", function()
	local Tree = Isolated.Parse(SCHEMA)
	local Client = Generator.GenerateTypescript("Client" :: any, Tree)
	local Server = Generator.GenerateTypescript("Server" :: any, Tree)

	for _, Line in { "Fire: () => void", "Fire: (Target: number, Value2: Vector3) => void" } do
		assert(string.find(Client, Line, 1, true), `the client declaration lacks "{Line}"`)
	end

	for _, Line in
		{
			"On: (Listener: (Player: Player, SentAt: number) => void)",
			"On: (Listener: (Player: Player, Target: number, Value2: Vector3, SentAt: number) => void)",
		}
	do
		assert(string.find(Server, Line, 1, true), `the server declaration lacks "{Line}"`)
	end
end)

--> Each refusal on its own, with the message that names it; the Invalid fixtures check the code.
local EVENT = "event S {\n\tFrom: %s,\n\tType: Reliable,\n\tCall: %s,\n\tStamp: %s%s\n}"
local REFUSED = {
	{ { "Server", "SingleSync", "250", "" }, 'Event "S" is stamped but not sent by a client' },
	{ { "Client", "Polling", "250", "" }, 'Stamped event "S" cannot be polled' },
	--> A number field takes no zero, before the stamp's own check sees it.
	{ { "Client", "SingleSync", "0", "" }, 'Invalid value for "Stamp"' },
	{ { "Client", "SingleSync", "0.5", "" }, 'Stamp window of "S" is out of range' },
	{ { "Client", "SingleSync", "30001", "" }, 'Stamp window of "S" is out of range' },
	{
		{ "Client", "SingleSync", "250", ",\n\tData: (SentAt: u8)" },
		'Stamped event "S" already has an element named SentAt',
	},
}

RunClosure("The compiler refuses a stamp it cannot honour", function()
	for _, Case in REFUSED do
		local Source = string.format(EVENT, table.unpack(Case[1]))
		local Parsed, Failure = pcall(Isolated.Parse, Source)
		assert(not Parsed, `accepted:\n{Source}`)
		assert(string.find(tostring(Failure), Case[2], 1, true), `refused with "{Failure}", expected "{Case[2]}"`)
	end

	--> And the edges that are allowed.
	for _, Window in { "1", "30000" } do
		local Source = string.format(EVENT, "Client", "SingleSync", Window, "")
		assert(pcall(Isolated.Parse, Source), `refused a window of {Window} ms`)
	end
end)

return {}
