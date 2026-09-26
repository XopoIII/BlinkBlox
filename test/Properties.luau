--!strict
--- Properties every exported type's serialiser must hold, checked on random values.
---
--- Every other spec checks values someone picked. These draw them (Generate.luau), leaning on the
--- edges where the last release's serialiser bugs were -- a range's own bound, a length of 256, an
--- f16 subnormal -- and check, for each exported type of Test.blink:
---
---   1. a value of the type is written without error;
---   2. into a number of bytes the size analysis allows;
---   3. and read back as the same value -- floats included, since each draw is exactly representable;
---   4. re-writing what was read reproduces the same bytes;
---   5. the encoding cannot be cut short: every byte of it is read;
---   6. a corrupted encoding either fails to read, or reads as a value the schema admits and the
---      sender would write -- the server's side of this, since a client chooses every byte;
---   7. and a value the receiver would refuse, if the sender writes it at all, is read to its last
---      byte, and under WriteValidations arrives unchanged.
---
--- The sixth is the one the rest of the module exists for: a decoder may refuse anything, but
--- whatever it accepts is handed to the game as if the schema vouched for it.
---
--- Each type is checked in two builds of Test.blink: the one the suite loads, with WriteValidations
--- on, and one with the options a game gets by default.
---
--- The draws are seeded. A failure prints its seed; `BLINKBLOX_SEED=<n>` on the suite replays it,
--- and any other seed explores further.
local Attributes = require("@compiler/Modules/Attributes")
local Error = require("@compiler/Modules/Error")
local Generate = require("./Generate")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Oracle = require("./Oracle")
local Parser = require("@compiler/Parser")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local Size = require("@compiler/Modules/Size")
local fs = require("@lune/fs")
local process = require("@lune/process")

local Server = Modules.Server :: any
local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local SEED = tonumber(process.env.BLINKBLOX_SEED) or 29
local DRAWS = 100
local CORRUPTIONS = 12

--> No read of a corrupted encoding may take this long: every decode loop is bounded by the bytes
--> it has, and one that is not shows up here as a stall rather than as a hung suite.
local SLOW_READ = 0.25

type Node = { Type: string, Name: string, Value: any, Tokens: any }

local function Describe(Value: any): string
	if typeof(Value) == "buffer" then
		return `buffer({buffer.len(Value)})`
	elseif type(Value) == "string" then
		return string.format("%q", if #Value > 40 then string.sub(Value, 1, 40) .. "..." else Value)
	elseif type(Value) ~= "table" then
		return tostring(Value)
	end

	local Parts = {}
	for Key, Entry in Value do
		table.insert(Parts, `{Key}={Describe(Entry)}`)
		if #Parts >= 6 then
			table.insert(Parts, "...")
			break
		end
	end

	return `\{{table.concat(Parts, ", ")}}`
end

local function Hex(Bytes: buffer): string
	local Parts = {}
	for Index = 0, math.min(buffer.len(Bytes), 24) - 1 do
		table.insert(Parts, string.format("%02x", buffer.readu8(Bytes, Index)))
	end

	return table.concat(Parts, " ") .. (if buffer.len(Bytes) > 24 then " ..." else "")
end

--- A copy of `Bytes` with one kind of damage a hostile or broken sender could do.
local function Corrupt(Bytes: buffer): buffer
	local Length = buffer.len(Bytes)
	local Kind = math.random(1, 5)

	if Kind == 1 and Length > 0 then
		--> Cut short.
		local Result = buffer.create(math.random(0, Length - 1))
		buffer.copy(Result, 0, Bytes, 0, buffer.len(Result))
		return Result
	elseif Kind == 2 then
		--> Trailing garbage.
		local Extra = math.random(1, 16)
		local Result = buffer.create(Length + Extra)
		buffer.copy(Result, 0, Bytes)
		for Index = Length, Length + Extra - 1 do
			buffer.writeu8(Result, Index, math.random(0, 255))
		end

		return Result
	elseif Kind == 3 and Length > 0 then
		--> A byte set to a value that sits on some boundary.
		local Result = buffer.create(Length)
		buffer.copy(Result, 0, Bytes)
		local Edges = { 0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE }
		buffer.writeu8(Result, math.random(0, Length - 1), Edges[math.random(1, #Edges)])
		return Result
	elseif Length > 0 then
		--> Bits flipped.
		local Result = buffer.create(Length)
		buffer.copy(Result, 0, Bytes)
		for _ = 1, math.random(1, 3) do
			local Index = math.random(0, Length - 1)
			buffer.writeu8(Result, Index, bit32.bxor(buffer.readu8(Result, Index), bit32.lshift(1, math.random(0, 7))))
		end

		return Result
	end

	local Result = buffer.create(math.random(1, 32))
	for Index = 0, buffer.len(Result) - 1 do
		buffer.writeu8(Result, Index, math.random(0, 255))
	end

	return Result
end

--- Checks one draw of one type. Returns why it failed, or nil.
local function Check(Node: Node, Serde: any, Bounds: Size.Measurement, Validated: boolean): string?
	local Value = Generate.Value(Node)

	--> 1. Written.
	local Wrote, Bytes = pcall(Serde.Write, Value)
	if not Wrote then
		return `writing {Describe(Value)} failed: {Bytes}`
	end

	--> 2. In as many bytes as the size analysis allows.
	local Length = buffer.len(Bytes)
	if Length < Bounds.Min or Length > Bounds.Max then
		return `{Describe(Value)} took {Length} bytes, the size analysis allows {Bounds.Min}..{Bounds.Max}`
	end

	--> 3. Read back as itself.
	local Read, Got = pcall(Serde.Read, Bytes)
	if not Read then
		return `reading back {Describe(Value)} failed: {Got}\n  bytes: {Hex(Bytes)}`
	elseif not Oracle.Equal(Node, Value, Got) then
		return `{Describe(Value)} came back as {Describe(Got)}\n  bytes: {Hex(Bytes)}`
	end

	--> 4. One encoding per value. A map has no order to keep, so a value holding one is checked by
	-->    reading the second encoding back instead.
	local Again = Serde.Write(Got)
	if Generate.HasMap(Node) then
		if not Oracle.Equal(Node, Value, Serde.Read(Again)) then
			return `{Describe(Value)} re-wrote as a different value:\n  bytes: {Hex(Again)}`
		end
	elseif buffer.tostring(Again) ~= buffer.tostring(Bytes) then
		return `{Describe(Value)} re-wrote differently:\n  first:  {Hex(Bytes)}\n  second: {Hex(Again)}`
	end

	--> 5. Every byte is read: an encoding one byte short must not decode. A reader that stops early
	-->    leaves the rest of an event's bytes to be read as the next event.
	if Length > 0 then
		local Short = buffer.create(Length - 1)
		buffer.copy(Short, 0, Bytes, 0, Length - 1)
		local Accepted, Shortened = pcall(Serde.Read, Short)
		if Accepted then
			return `{Describe(Value)} still decoded one byte short, as {Describe(Shortened)}\n  bytes: {Hex(Bytes)}`
		end
	end

	--> 6. Whatever a corrupted encoding decodes to is a value of the type, and one the sender would
	-->    write.
	for _ = 1, CORRUPTIONS do
		local Damaged = Corrupt(Bytes)
		local Started = os.clock()
		local Accepted, Decoded = pcall(Serde.Read, Damaged)
		local Took = os.clock() - Started

		--> A read over the limit is timed twice more on the same bytes, and only the fastest counts. A
		--> loop the bytes do not bound is slow every time; a garbage collection that lands inside one
		--> read is not, and late in the suite, with the heap at its largest, one did: a read whose
		--> slowest honest case takes 22 ms was clocked at 330.
		for _ = 1, 2 do
			if Took <= SLOW_READ then
				break
			end

			local Retried = os.clock()
			pcall(Serde.Read, Damaged)
			Took = math.min(Took, os.clock() - Retried)
		end

		if Took > SLOW_READ then
			return `reading {buffer.len(Damaged)} corrupted bytes took {Took}s\n  bytes: {Hex(Damaged)}`
		elseif Accepted then
			local Reason = Oracle.Valid(Node, Decoded)
			if Reason then
				return `corrupted bytes decoded to a value outside the type: {Reason}\n  bytes: {Hex(Damaged)}`
			end

			local Rewrote, Failure = pcall(Serde.Write, Decoded)
			if not Rewrote then
				return `corrupted bytes decoded to {Describe(Decoded)}, which the sender refuses to write: {Failure}\n  bytes: {Hex(
					Damaged
				)}`
			end
		end
	end

	--> 7. A value the receiver would not take -- a length past its bound, an integer past its range,
	-->    a float between representable values -- may be refused by either side. What the sender
	-->    does write:
	-->    a. is read to its last byte and no further, whatever the options. A length prefix that
	-->       wrapped on send was this: the receiver took a shorter value and read the rest of the
	-->       packet from the wrong place.
	-->    b. under WriteValidations, arrives as what was sent, floats narrowed to their precision.
	-->       Without it, cutting an exact-length value to size is the documented behaviour.
	Generate.Wild = true
	local Drew, Wild = pcall(Generate.Value, Node)
	Generate.Wild = false
	if not Drew then
		return nil
	end

	local Sent, Encoded = pcall(Serde.Write, Wild)
	if not Sent then
		return nil
	end

	local Received, Arrived = pcall(Serde.Read, Encoded)
	if not Received then
		return nil
	end

	local Written = buffer.len(Encoded)
	if Written > 0 then
		local Short = buffer.create(Written - 1)
		buffer.copy(Short, 0, Encoded, 0, Written - 1)
		if pcall(Serde.Read, Short) then
			return `{Describe(Wild)} was written in {Written} bytes, and fewer of them decode\n  bytes: {Hex(Encoded)}`
		end
	end

	if Validated and not Oracle.Equal(Node, Wild, Arrived, true) then
		return `{Describe(Wild)} was written and read back as {Describe(Arrived)}\n  bytes: {Hex(Encoded)}`
	end

	return nil
end

PrettyPrint("blue", `Checking serialiser properties (seed {SEED})...`)

--> Test.blink's warnings were printed when the harness compiled it; they are not this spec's to repeat.
local Hook = Error.OnEmit
Error.OnEmit = function(Diagnostic)
	return Diagnostic.Severity == "Warning"
end
local Tree = Parser.new("./Sources/", "Test.blink", nil, Attributes.new(nil)):Parse(fs.readFile("./Sources/Test.blink"))
Error.OnEmit = Hook

--> Test.blink turns WriteValidations on, and most games leave it at its default, off -- so every
--> property is checked against a second build of the same schema with it off. That build gets a
--> remote scope of its own, so its remotes are not the ones every other spec drives.
local Plain = table.clone(Tree)
Plain.Value = table.clone(Tree.Value)
Plain.Value.Options = table.clone(Tree.Value.Options)
Plain.Value.Options.WriteValidations = false
Plain.Value.Options.RemoteScope = "PROPERTIES"
fs.writeFile("../Network/PropertiesServer.luau", Generator.Generate("Server", Plain))

--> Remotes nothing is bridged to: this build only has its serialisers called.
local Stubs = {
	PROPERTIES_BLINK_RELIABLE_REMOTE = "RemoteEvent",
	PROPERTIES_BLINK_UNRELIABLE_REMOTE = "UnreliableRemoteEvent",
}
for Name, ClassName in Stubs do
	ServerEnvironment.Instances[Name] = {
		SetAttribute = function() end,
		GetAttribute = function() end,
		FireClient = function() end,
		FireAllClients = function() end,
		OnServerEvent = Shared.Signal.new(),
		IsA = function(_self, Queried: string)
			return Queried == ClassName
		end,
	}
end

local Unvalidated = Modules.MockRequire("../Network/PropertiesServer.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

local Builds = {
	{ Label = "WriteValidations on", Module = Server, Validated = true },
	{ Label = "default options", Module = Unvalidated, Validated = false },
}

local Checked, Skipped = 0, 0
local Failures: { string } = {}

for _, Build in Builds do
	for _, Declaration in Tree.Value.Declarations do
		local Node = Declaration :: any
		local Serde = Build.Module[Node.Name]
		local Kind = Node.Type
		if Kind == "Event" or Kind == "Function" or Kind == "Scope" or not Node.Value.Export or Node.Value.Generics then
			continue
		elseif not Serde or not Serde.Read then
			table.insert(Failures, `{Node.Name}: exported, but the server module has no reader for it`)
			continue
		elseif not Generate.Supported(Node) then
			Skipped += 1
			continue
		end

		PrettyPrint("cyan", `Testing: properties of {Node.Name} ({Build.Label})...`, true)

		--> Each type draws from its own stream, so adding a type to Test.blink does not change the
		--> draws of every type after it.
		local TypeSeed = SEED
		for Index = 1, #Node.Name do
			TypeSeed = (TypeSeed * 31 + string.byte(Node.Name, Index)) % 2147483647
		end
		math.randomseed(TypeSeed)

		local Bounds = Size.Sealed(Node)
		local Reason: string? = nil
		for _ = 1, DRAWS do
			Reason = Check(Node, Serde, Bounds, Build.Validated)
			if Reason then
				break
			end
		end

		Checked += 1
		if Reason then
			PrettyPrint("red", " failed")
			table.insert(Failures, `{Node.Name} ({Build.Label}): {Reason}`)
		else
			OkPrint(`Test "properties of {Node.Name} ({Build.Label})" passed!`)
		end
	end
end

if #Failures > 0 then
	ErrorPrint(`{#Failures} serialiser properties failed (seed {SEED}):\n{table.concat(Failures, "\n")}`)
end

if Checked < 80 then
	ErrorPrint(`Only {Checked} type checks ran; Test.blink or the filter above has lost most of its exports.`)
end

OkPrint(
	`Checked {Checked // 2} exported types in two builds, {DRAWS} draws each; {Skipped // 2} with Roblox datatypes are covered elsewhere.`
)
