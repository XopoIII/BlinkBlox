--!strict
--- Events side by side in one packet.
---
--- Properties.luau checks each type alone, at the start of a fresh buffer. The worst bugs of recent
--- releases were not in a type but at the seams between events: a refused fire that left a phantom
--- event in the batch (0.24), a reply whose reader stepped over a payload that was never sent, so
--- everything after it decoded from the wrong offset (0.29), an Instance left behind by a failed fire
--- that shifted every one after it (0.29). None of those shows up one value at a time. So this draws
--- random sequences of client events, fires them into one packet and checks four things:
---
---   1. The server's listeners receive exactly the sequence that was fired: same events, same order,
---      same values.
---   2. The packet is the events' standalone packets laid end to end. Nothing one event writes
---      reaches into the next: no bitfield, cursor or instance slot carries over.
---   3. A fire the sender refuses leaves the packet byte for byte as if it had never been tried.
---   4. A packet cut short delivers every event that ended before the cut, then stops and reports
---      once, naming the event it was cut inside -- and does not report at all when the cut falls on
---      a boundary.
---
--- The schema is this spec's own, built with remotes nothing else shares (Isolated.luau). Draws are
--- seeded like Properties.luau's: `BLINKBLOX_SEED` replays or varies them.
local Assertions = require("./Assertions")
local Generate = require("./Generate")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Oracle = require("./Oracle")
local Shared = require("./Shared")
local process = require("@lune/process")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SEED = tonumber(process.env.BLINKBLOX_SEED) or 29
local SEQUENCES = 60

--> One event per shape that has broken at a seam before: bitfields, offset-encoded and ranged
--> lengths, packed booleans, optionals with holes, tags, maps, f16, a type pack, and no data at all.
local SCHEMA = [[
option WriteValidations = true

struct Flags { A: boolean, B: boolean?, C: u8?, D: boolean }
enum Mode = { Idle, Walk, Run }
enum Shape = "Kind" {
    Circle { Radius: f32 },
    Box { W: u16, H: u16? },
}
map Scores = {[string(0..8)]: i16}

event Byte { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
event Empty { From: Client, Type: Reliable, Call: ManySync }
event Text { From: Client, Type: Reliable, Call: ManySync, Data: string(0..40) }
event Offset { From: Client, Type: Reliable, Call: ManySync, Data: string(3..300) }
event Bools { From: Client, Type: Reliable, Call: ManySync, Data: boolean[..20] }
event Packed { From: Client, Type: Reliable, Call: ManySync, Data: Flags }
event Holes { From: Client, Type: Reliable, Call: ManySync, Data: u16?[4] }
event Choice { From: Client, Type: Reliable, Call: ManySync, Data: Shape }
event Table { From: Client, Type: Reliable, Call: ManySync, Data: Scores }
event Half { From: Client, Type: Reliable, Call: ManySync, Data: f16 }
event Moving { From: Client, Type: Reliable, Call: ManySync, Data: Mode }
event Pack { From: Client, Type: Reliable, Call: ManySync, Data: (u8, string(0..10)?, boolean) }
]]

type Node = { Type: string, Name: string, Value: any, Tokens: any }
type Event = { Name: string, Elements: { Node } }
type Fired = { Event: Event, Values: { any }, Count: number }

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "COMPOSITION")
local Server = Pair.Server
local Client = Pair.Client

--> Each event's data as a list of type nodes: one for plain data, one per element of a type pack,
--> none for an event without data.
local Events: { Event } = {}
for _, Declaration in Pair.Tree.Value.Declarations do
	if Declaration.Type ~= "Event" then
		continue
	end

	local Data = Declaration.Value.Data
	local Elements = if Data == nil then {} elseif Data.Type == "Tuple" then Data.Value.Values else { Data }
	table.insert(Events, { Name = Declaration.Name, Elements = Elements })
end

--> What the server's listeners were handed, in order.
local Received: { { Name: string, Values: { any }, Count: number } } = {}
for _, Event in Events do
	Server[Event.Name].On(function(_Player, ...)
		table.insert(Received, { Name = Event.Name, Values = table.pack(...) :: any, Count = select("#", ...) })
	end)
end

local Reports: { { Event: string? } } = {}
Server.SetDecodeErrorHandler(function(_Player, Event, _Failure)
	table.insert(Reports, { Event = Event })
end)

local function Draw(Event: Event): Fired
	local Values = {}
	for Index, Element in Event.Elements do
		Values[Index] = Generate.Value(Element)
	end

	return { Event = Event, Values = Values, Count = #Event.Elements }
end

local function Fire(Item: Fired)
	Client[Item.Event.Name].Fire(table.unpack(Item.Values, 1, Item.Count))
end

--- Flushes the client and returns the one packet it sent, or an empty buffer if it sent none.
local function Flush(): buffer
	table.clear(Pair.Sent)
	Client.StepReplication()
	if #Pair.Sent > 1 then
		error(`one flush sent {#Pair.Sent} packets`)
	end

	local Packet = Pair.Sent[1]
	return if Packet then Packet.Buffer else buffer.create(0)
end

local function Describe(Item: Fired): string
	return `{Item.Event.Name}({Item.Count} values)`
end

--- Delivers `Packet` and returns what the listeners got and what was reported.
local function Deliver(Packet: buffer): ({ { Name: string, Values: { any }, Count: number } }, { { Event: string? } })
	--> Its own second of reports and of inbound budget, so neither limit decides the outcome.
	Shared.AdvanceClock(2)
	table.clear(Received)
	table.clear(Reports)
	Pair.Feed(true, Packet)
	return table.clone(Received), table.clone(Reports)
end

local function Matches(Item: Fired, Got: { Name: string, Values: { any }, Count: number }): boolean
	if Got.Name ~= Item.Event.Name then
		return false
	end

	for Index, Element in Item.Event.Elements do
		if not Oracle.Equal(Element, Item.Values[Index], Got.Values[Index]) then
			return false
		end
	end

	return true
end

local function Slice(Packet: buffer, Length: number): buffer
	local Result = buffer.create(Length)
	buffer.copy(Result, 0, Packet, 0, Length)
	return Result
end

RunClosure("Events fired together arrive together, and apart", function()
	math.randomseed(SEED)
	Flush()

	--> Counted so the run cannot pass by never exercising what it claims to check.
	local RefusedFires, CutsInside = 0, 0

	for Sequence = 1, SEQUENCES do
		local Items: { Fired } = {}
		for _ = 1, math.random(1, 10) do
			table.insert(Items, Draw(Events[math.random(1, #Events)]))
		end

		--> 2. Each alone first: its packet, and where it ends in the combined one.
		local Parts: { string } = {}
		local Ends: { number } = {}
		local Total = 0
		for _, Item in Items do
			Fire(Item)
			local Part = buffer.tostring(Flush())
			table.insert(Parts, Part)
			Total += #Part
			table.insert(Ends, Total)
		end

		for _, Item in Items do
			Fire(Item)
		end

		local Packet = Flush()
		if buffer.tostring(Packet) ~= table.concat(Parts) then
			ErrorPrint(
				`Failed "composition" (seed {SEED}, sequence {Sequence}): the packet is not its events' packets end to end.`
			)
		end

		--> 1. The same sequence comes out.
		local Got, Reported = Deliver(Packet)
		if #Reported > 0 or #Got ~= #Items then
			ErrorPrint(
				`Failed "composition" (seed {SEED}, sequence {Sequence}): {#Items} events fired, {#Got} delivered, {#Reported} reported.`
			)
		end

		for Index, Item in Items do
			if not Matches(Item, Got[Index]) then
				ErrorPrint(
					`Failed "composition" (seed {SEED}, sequence {Sequence}): event {Index}, {Describe(Item)}, arrived changed.`
				)
			end
		end

		--> 3. A refused fire in the middle leaves no trace.
		local At = math.random(0, #Items)
		local Target = Events[math.random(1, #Events)]
		local Refused = false
		for Index = 1, #Items + 1 do
			if Index == At + 1 and #Target.Elements == 1 then
				Generate.Wild = true
				local Drew, Wild = pcall(Draw, Target)
				Generate.Wild = false
				if Drew then
					Refused = not pcall(Fire, Wild)
					if not Refused then
						break
					end
				end
			end

			if Items[Index] then
				Fire(Items[Index])
			end
		end

		local Again = Flush()
		RefusedFires += if Refused then 1 else 0
		if Refused and buffer.tostring(Again) ~= buffer.tostring(Packet) then
			ErrorPrint(
				`Failed "composition" (seed {SEED}, sequence {Sequence}): a refused {Target.Name} fire changed the packet.`
			)
		end

		--> 4. Cut short: on and around every boundary, and at a few places between.
		local Cuts: { number } = {}
		for _, End in Ends do
			for Offset = -1, 1 do
				if End + Offset > 0 and End + Offset < Total then
					table.insert(Cuts, End + Offset)
				end
			end
		end

		for _ = 1, 8 do
			if Total > 1 then
				table.insert(Cuts, math.random(1, Total - 1))
			end
		end

		for _, Cut in Cuts do
			local Complete, Inside = 0, nil
			for Index, End in Ends do
				if End <= Cut then
					Complete = Index
				elseif Inside == nil then
					Inside = if (Ends[Index - 1] or 0) == Cut then nil else Items[Index]
					break
				end
			end

			CutsInside += if Inside then 1 else 0
			local Delivered, Said = Deliver(Slice(Packet, Cut))
			local Expected = if Inside then 1 else 0
			if #Delivered ~= Complete or #Said ~= Expected then
				ErrorPrint(
					`Failed "composition" (seed {SEED}, sequence {Sequence}): cut at {Cut} of {Total}, expected {Complete} delivered and {Expected} reported, got {#Delivered} and {#Said}.`
				)
			elseif Inside and Said[1].Event ~= Inside.Event.Name then
				ErrorPrint(
					`Failed "composition" (seed {SEED}, sequence {Sequence}): cut inside {Inside.Event.Name}, reported as {Said[1].Event or "unknown"}.`
				)
			end
		end
	end

	Shared.DrainWarnings()

	if RefusedFires < 5 or CutsInside < 50 then
		ErrorPrint(
			`Failed "composition": only {RefusedFires} refused fires and {CutsInside} cuts inside an event were tried.`
		)
	end
end)
