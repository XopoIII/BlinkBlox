--!strict
--- Specs for the schema signature: what it must notice, and what it must ignore.
---
--- The second half matters as much as the first. A signature that changed when `option Casing` was
--- flipped would refuse to start a game over a difference that reaches no byte, and the fastest way
--- to get a safety check removed is to make it cry wolf.
---
--- These parse source strings directly, so they say nothing about the generated modules -- the
--- end-to-end half is in test/SchemaDrift.luau.
local Harness = require("./Harness")
local Parser = require("@compiler/Parser")
local Signature = require("@compiler/Modules/Signature")

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local function Sign(Source: string): string
	local Instance = Parser.new()
	return Signature.Of(Instance:Parse(Source))
end

local function ExpectSame(Name: string, Left: string, Right: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local A, B = Sign(Left), Sign(Right)
	if A ~= B then
		ErrorPrint(`Failed "{Name}": signatures differ ({A} and {B}) over a change that reaches no byte.`)
		return
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function ExpectDifferent(Name: string, Left: string, Right: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local A, B = Sign(Left), Sign(Right)
	if A == B then
		ErrorPrint(`Failed "{Name}": both schemas signed as {A} despite differing on the wire.`)
		return
	end

	OkPrint(`Test "{Name}" passed!`)
end

local BASE = [[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}
]]

---- Must NOT change the signature ----

ExpectSame("Casing is not part of the wire", BASE, `option Casing = Camel\n{BASE}`)
ExpectSame("Typescript output is not part of the wire", BASE, `option Typescript = true\n{BASE}`)
ExpectSame("Output paths are not part of the wire", BASE, `option ClientOutput = "./C.luau"\n{BASE}`)
ExpectSame("SyncValidation is not part of the wire", BASE, `option SyncValidation = false\n{BASE}`)
ExpectSame("Packet caps are not part of the wire", BASE, `option MaxPacketSize = 16384\n{BASE}`)
ExpectSame("Comments and whitespace are not part of the wire", BASE, `-- a comment\n\n{BASE}\n\n`)

--> Rate and Call decide what the RECEIVER does with an event, not what arrives. Two builds that
--> differ only there can still talk, and refusing to start would be wrong.
ExpectSame(
	"A rate limit is not part of the wire",
	[[
event Alpha {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}
]],
	[[
event Alpha {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Rate: 5,
    Burst: 10,
    Data: u8
}
]]
)

ExpectSame(
	"The call type is not part of the wire",
	BASE,
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: ManyAsync,
    Data: u8
}
]]
)

---- Must change the signature ----

--> The one this exists for. An event inserted ahead of another renumbers it, and a stale client
--> reads the new index as the old event.
ExpectDifferent("An event inserted ahead of another", BASE, [[
event Inserted {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}
]] .. BASE)

--> Functions and events share the reliable channel's numbering, so a function inserted ahead of an
--> event shifts it just the same. Easy to miss precisely because they look like different things.
ExpectDifferent("A function inserted ahead of an event", BASE, [[
function Inserted {
    Yield: Coroutine,
    Data: u8,
    Return: u8
}
]] .. BASE)

ExpectDifferent(
	"A change of reliability",
	BASE,
	[[
event Alpha {
    From: Server,
    Type: Unreliable,
    Call: SingleSync,
    Data: u8
}
]]
)

ExpectDifferent(
	"Unreliable becoming ordered",
	[[
event Alpha {
    From: Server,
    Type: Unreliable,
    Call: SingleSync,
    Data: u8
}
]],
	[[
event Alpha {
    From: Server,
    Type: OrderedUnreliable,
    Call: SingleSync,
    Data: u8
}
]]
)

ExpectDifferent(
	"A wider number",
	BASE,
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: u16
}
]]
)

ExpectDifferent(
	"A bound on a string, which changes how its length is encoded",
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: string
}
]],
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: string(0..64)
}
]]
)

ExpectDifferent(
	"Two struct fields transposed",
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: struct { A: u8, B: u16 }
}
]],
	[[
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: struct { B: u16, A: u8 }
}
]]
)

ExpectDifferent(
	"An enum variant inserted mid-list",
	[[
enum States = { A, B, C }
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: States
}
]],
	[[
enum States = { A, Inserted, B, C }
event Alpha {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: States
}
]]
)

--> Direction does not change the bytes, but it changes which side listens -- so one side would be
--> sending into a channel the other is not reading.
ExpectDifferent(
	"A change of direction",
	BASE,
	[[
event Alpha {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}
]]
)

--> A rename reaches no byte either, but it renames the API the other side calls, and a schema that
--> differs by a name is a schema somebody edited without recompiling both sides.
ExpectDifferent(
	"A renamed event",
	BASE,
	[[
event Renamed {
    From: Server,
    Type: Reliable,
    Call: SingleSync,
    Data: u8
}
]]
)

return {}
