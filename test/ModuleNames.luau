--!strict
--- Specs for the names a schema shares with the module generated from it, the accepting half of
--- what Sources/Invalid refuses: a member's name only in the spelling `option Casing` puts it in,
--- and a client-sent Instance beside `MaxInstancesPerPacket = 0` only where the client sends it.
---
--- Also the TypeScript declarations of the three handler setters, written out whole. The `.d.ts` had
--- declared none of them before 0.37.0, and a prefix check would pass one typed wrong.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--- Whether `Source` parses, and the error if it does not.
local function Parses(Source: string): (boolean, string?)
	local Success, Result = pcall(Isolated.Parse, Source)
	return Success, if Success then nil else tostring(Result)
end

RunClosure("A member's name is reserved only in the spelling Casing gives it", function()
	--> Under Pascal the members are StepReplication and SetPacketDropHandler; these are other keys.
	local Accepted, Failure = Parses([[
event stepReplication { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }
scope set_packet_drop_handler {
    event Ping { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }
}
]])

	if not Accepted then
		ErrorPrint(`Failed "Casing": names reserved only under Camel and Snake were refused under Pascal.\n{Failure}`)
	end

	--> Under Camel, StepReplication is no longer a member's spelling, but the parser holds every
	--> casing to the Pascal names it has always refused.
	if
		Parses(
			"option Casing = Camel\nevent StepReplication { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }"
		)
	then
		ErrorPrint(`Failed "Casing": the Pascal member name was accepted under Camel.`)
	end
end)

RunClosure("MaxInstancesPerPacket = 0 accepts Instances the client never sends", function()
	--> A From: Client function's return travels server to client; a From: Server event's data too.
	local Accepted, Failure = Parses([[
option MaxInstancesPerPacket = 0

function Lookup { Yield: Coroutine, From: Client, Rate: 10, Data: u8, Return: Instance }
event Point { From: Server, Type: Reliable, Call: ManySync, Data: struct { Parts: Instance[..4] } }
]])

	if not Accepted then
		ErrorPrint(`Failed "Server-sent Instances": refused with MaxInstancesPerPacket = 0.\n{Failure}`)
	end
end)

RunClosure("The TypeScript declarations type all four handler setters", function()
	local REASON = `"Malformed" | "Oversized" | "Budget" | "Instances" | "Events"`
	local Spellings = {
		Pascal = { "SetRateLimitHandler", "SetDecodeErrorHandler", "SetPacketDropHandler", "SetListenerErrorHandler" },
		Camel = { "setRateLimitHandler", "setDecodeErrorHandler", "setPacketDropHandler", "setListenerErrorHandler" },
		Snake = {
			"set_rate_limit_handler",
			"set_decode_error_handler",
			"set_packet_drop_handler",
			"set_listener_error_handler",
		},
	}

	for Casing, Names in Spellings do
		local Tree = Isolated.Parse(
			`option Casing = {Casing}\nevent Byte \{ From: Client, Type: Reliable, Call: ManySync, Rate: 10, Data: u8 }`
		)
		for _, Context in { "Server", "Client" } do
			local Decode = if Context == "Server"
				then "(player: Player, event: string | undefined, failure: string) => void"
				else "(event: string | undefined, failure: string) => void"

			local Expected = {
				`export declare const {Names[1]}: (handler?: (player: Player, event: string | undefined, refused: number) => void) => void`,
				`export declare const {Names[2]}: (handler?: {Decode}) => void`,
				`export declare const {Names[3]}: (handler?: (player: Player, reason: {REASON}, refused: number, detail: number) => void) => void`,
				`export declare const {Names[4]}: (handler?: (player: Player, event: string, failure: string, count: number) => void) => void`,
			}

			local Declaration = Generator.GenerateTypescript(Context :: any, Tree)
			for _, Line in Expected do
				if not string.find(Declaration, `{Line}\n`, 1, true) then
					ErrorPrint(`Failed "TypeScript": the {Casing} {Context} declaration lacks:\n{Line}`)
				end
			end
		end
	end
end)
