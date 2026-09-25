--!strict
--- Every first byte a client can send, on every channel of every test schema's server.
---
--- The first byte of an event is its index, and the client chooses it. A server has to route each of
--- the 256 values to the declaration it names, or refuse it and say so -- deny by default. That
--- refusal is an `else` branch the generator emits, and in 0.26.0 it turned out not to be emitted at
--- all on a channel with nothing to receive: the loop read on, one byte at a time, without failing or
--- reporting. Guards.luau checks the emitted code for the branch by substring; this runs it. For each
--- value alone in a packet:
---
---   an index the server declares is taken as that declaration: nothing reports it as unknown, and a
---   failure to decode it -- most have data a one-byte packet does not carry -- names it;
---   any other index is reported through SetDecodeErrorHandler exactly once, with no event named.
---
--- 256 values of a small domain are cheaper to exhaust than to sample, and exhausting them leaves no
--- value untried.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local fs = require("@lune/fs")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

--- The indices a generated server receives on, read from the module it generated: `EventNames` is
--- what its decode loop names a declaration by.
local function Declared(Source: string, Channel: string): { [number]: string }
	local Names: { [number]: string } = {}
	for Index, Name in string.gmatch(Source, `EventNames%.{Channel}%[(%d+)%] = "([^"]+)"`) do
		Names[tonumber(Index) :: number] = Name
	end

	return Names
end

RunClosure("Every event index is routed or refused, on every test schema's server", function()
	local Schemas = 0
	for _, File in fs.readDir("./Sources") do
		local Name = string.match(File, "^(.+)%.blink$")
		if not Name then
			continue
		end

		Schemas += 1
		local Tree = Isolated.Parse(fs.readFile(`./Sources/{File}`), "./Sources/", File)
		local Pair = Isolated.Build(Tree, `INDICES{string.upper(Name)}`, false)
		local Source = fs.readFile(`../Network/IsolatedINDICES{string.upper(Name)}Server.luau`)

		--> Named in the schema's own casing.
		local Server = Pair.Server

		--> A server built with `AutoStart = false` listens only once started.
		local Start = Server.Start or Server.start
		if Start then
			Start()
		end

		local SetHandler = Server.SetDecodeErrorHandler
			or Server.setDecodeErrorHandler
			or Server.set_decode_error_handler

		local Reports: { { Event: string? } } = {}
		SetHandler(function(_Player, Event, _Failure)
			table.insert(Reports, { Event = Event })
		end)

		for _, Channel in { "Reliable", "Unreliable" } do
			local Names = Declared(Source, Channel)
			for Index = 0, 255 do
				--> Reports are limited to one a second per player, channel and event; each probe is
				--> its own second, and its own share of the inbound budget.
				Shared.AdvanceClock(2)
				table.clear(Reports)

				local Packet = buffer.create(1)
				buffer.writeu8(Packet, 0, Index)
				Pair.Feed(Channel == "Reliable", Packet)

				local Expected = Names[Index]
				local Report = Reports[1]
				if #Reports > 1 then
					ErrorPrint(`Failed "{File}" {Channel} index {Index}: reported {#Reports} times for one packet.`)
				elseif Expected == nil and (Report == nil or Report.Event ~= nil) then
					ErrorPrint(
						`Failed "{File}" {Channel} index {Index}: no declaration has it, and it was {if Report
							then `reported as "{Report.Event}"`
							else "never reported"}.`
					)
				elseif Expected ~= nil and Report and Report.Event ~= Expected then
					ErrorPrint(
						`Failed "{File}" {Channel} index {Index}: declared as "{Expected}", reported as {Report.Event or "unknown"}.`
					)
				end
			end
		end

		SetHandler(nil)
		Shared.DrainWarnings()
	end

	if Schemas < 10 then
		ErrorPrint(`Failed "event indices": only {Schemas} test schemas were found.`)
	end
end)
