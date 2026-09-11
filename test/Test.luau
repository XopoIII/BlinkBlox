--!strict
--- The behavioural suite: every spec loads the generated modules against mocked Roblox globals and
--- drives them the way a game would. Building those modules -- compiling, goldens, diagnostics --
--- lives in Harness.luau.
local Format = require("../src/Modules/Format")
local Harness = require("./Harness")
local fs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")

local Compiler = Harness.Compiler
local COMPILE_TEST_FILE = Harness.TestSchema

local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

Harness.Prepare()

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local Modules = require("./Modules")
local Client = Modules.Client
local Server = Modules.Server
local MockRequire = Modules.MockRequire

--> Helper functions, extracted to keep this file under its recorded size.
local Assertions = require("./Assertions")
local GetFlags = Assertions.GetFlags
local Fail = Assertions.Fail
local Equals = Assertions.Equals
local FireAndFail = Assertions.FireAndFail
local FireAndExpect = Assertions.FireAndExpect
local InvokeAndExpect = Assertions.InvokeAndExpect
local QueueAndExpect = Assertions.QueueAndExpect
local FireAndExpectAll = Assertions.FireAndExpectAll
local FireAllAndExpectAll = Assertions.FireAllAndExpectAll
local FireAndExpectTuple = Assertions.FireAndExpectTuple
local InvokeAndExpectTuple = Assertions.InvokeAndExpectTuple
local FireManyAndExpectMany = Assertions.FireManyAndExpectMany
local FireAndPollExpect = Assertions.FireAndPollExpect
local FireAndExpectSeparate = Assertions.FireAndExpectSeparate
local RunClosure = Assertions.RunClosure

--> Tests
local Instance = setmetatable({
	__typeof = "Instance",
	IsA = function(_self)
		return true
	end,
}, {
	__tostring = function()
		return "Instance"
	end,
})

local InstanceNeverIsA = setmetatable({
	__typeof = "Instance",
	ClassName = "Never",
	IsA = function(_self)
		return false
	end,
}, {
	__tostring = function()
		return "Instance (Invalid)"
	end,
})

local Example: Client.Example = {
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
}

PrettyPrint("blue", "Running output tests...")

FireAndExpect("Reliable Server", Server.ReliableServer, Client.ReliableServer, 1)
FireAndExpect("Unreliable Server", Server.UnreliableServer, Client.UnreliableServer, 1)
FireAndExpect("Empty Reliable Server", Server.EmptyEvent, Client.EmptyEvent, nil)
FireAndExpect("Empty Unreliable Server", Server.EmptyUnreliableEvent, Client.EmptyUnreliableEvent, nil)

FireAndExpect("Reliable Client", Client.ReliableClient, Server.ReliableClient, 1)
FireAndExpect("Unreliable Client", Client.UnreliableClient, Server.UnreliableClient, 1)
FireAndExpect("Empty Reliable Client", Client.ClientEmptyEvent, Server.ClientEmptyEvent, nil)
FireAndExpect("Empty Unreliable Client", Client.ClientEmptyUnreliableEvent, Server.ClientEmptyUnreliableEvent, nil)

FireManyAndExpectMany("Many Reliable Sync Server", 8, Server.ManyReliableSync, Client.ManyReliableSync, 1)
FireManyAndExpectMany("Many Reliable Async Server", 8, Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
FireManyAndExpectMany("Many Unreliable Sync Server", 8, Server.ManyUnreliableSync, Client.ManyUnreliableSync, 1)
FireManyAndExpectMany("Many Unreliable Async Server", 8, Server.ManyUnreliableAsync, Client.ManyUnreliableAsync, 1)

FireAndExpect("Unknown", Server.Unknown, Client.Unknown, newproxy())
FireAndExpect("Unknown (false)", Server.Unknown, Client.Unknown, false)
FireAndExpectAll("Unknown (nil mixed)", Server.Unknown, Client.Unknown, { "a", nil, "b", nil, nil, nil, "c" })

FireAndExpect(
	"Generic",
	Server.Generic,
	Client.Generic,
	{ Data = 0, Array = { 0 }, Optional = nil, Nested = { Value = 0 } }
)

FireAndExpect("Set 8", Server.Flags8, Client.Flags8, GetFlags(8))
FireAndExpect("Set 16", Server.Flags16, Client.Flags16, GetFlags(16))
FireAndExpect("Set 32", Server.Flags32, Client.Flags32, GetFlags(32))
FireAndExpect("Set >32", Server.Flags33, Client.Flags33, GetFlags(33))

FireAndExpect("Map", Server.MapEvent, Client.MapEvent, { ["string"] = 1 })
FireAndExpect("Map Struct", Server.MapStructEvent, Client.MapStructEvent, { Map = { string = 1 } })
FireAndExpect("Map Complex", Server.MapComplexEvent, Client.MapComplexEvent, { string = table.create(8, 1) })
FireAndExpect("Map Reference", Server.MapReferenceEvent, Client.MapReferenceEvent, { A = "A" })

FireAndExpect("Struct", Server.Reference, Client.Reference, Example)
FireAndExpect("Array", Server.ArrayPrimitive, Client.ArrayPrimitive, { 1, 2, 3, 4, 5, 6, 7, 8 })
FireAndExpect("Optional", Server.OptionalPrimitive, Client.OptionalPrimitive, 1)
FireAndExpect("Optional (nil)", Server.OptionalPrimitive, Client.OptionalPrimitive, nil)

FireAndExpect("Instance Any", Server.InstanceAny, Client.InstanceAny, Instance)
FireAndExpect("Instance Type", Server.InstanceOfType, Client.InstanceOfType, Instance)
FireAndFail("Instance Type (Fail)", Server.InstanceOfType, Client.InstanceOfType, nil)
FireAndExpect("Instance Optional", Server.InstanceOptional, Client.InstanceOptional, Instance)
FireAndExpectSeparate(
	"Instance Optional (nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	Shared.ServerOnlyInstance,
	nil
)

local Array = table.create(8, Example)
FireAndExpect("Reference", Server.Reference, Client.Reference, Example)
FireAndExpect("Referency Array", Server.ReferenceArray, Client.ReferenceArray, Array)
FireAndExpect("Referency Optional", Server.ReferenceOptional, Client.ReferenceOptional, Example)
FireAndExpect("Referency Optional (nil)", Server.ReferenceOptional, Client.ReferenceOptional, nil)

InvokeAndExpect("Remote Function", Client.RemoteFunction, Server.RemoteFunction, 1, true)
InvokeAndExpect("Remote Function (yield)", Client.RemoteFunction, Server.RemoteFunction, 1, true, 1)
InvokeAndExpect("Remote Function (error)", Client.RemoteFunction, Server.RemoteFunction, 1, false)
InvokeAndExpect("Empty Remote Function", Client.EmptyFunction, Server.EmptyFunction, nil, true)
InvokeAndExpect("Unit Remote Function", Client.UnitFunction, Server.UnitFunction, nil, true)

QueueAndExpect("Reliable Queue", Server.ReliableServer, Client.ReliableServer, 1)
QueueAndExpect("Many Reliable Sync Queue", Server.ManyReliableSync, Client.ManyReliableSync, 1)
QueueAndExpect("Many Reliable Async Queue", Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
--QueueAndExpect("Unreliable Queue", Server.UnreliableServer, Client.UnreliableServer, 1)

FireAndFail("Invalid Instance Any", Server.InstanceAny, Client.InstanceAny, true)
FireAndFail("Invalid Instance Type", Server.InstanceOfType, Client.InstanceOfType, InstanceNeverIsA)

FireAndExpectAll("Correct order", Server.ReliableServer, Client.ReliableServer, { 1, 2, 3, 4 })
FireAndExpectAll(
	"Multiple instances (nil and non nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	{ nil, Instance, nil, Instance, Instance }
)

FireAndExpectAll("Many primitive", Server.ReliableServer, Client.ReliableServer, table.create(255, 1))
FireAndExpectAll("Many structs", Server.Reference, Client.Reference, table.create(255, Example))

FireAndExpectTuple(
	"Reliable Tuple",
	Server.Tuple,
	Client.Tuple,
	255,
	"A",
	65535,
	Instance,
	Instance,
	table.create(8, 0)
)
FireAndExpectTuple(
	"Unreliable Tuple",
	Server.TupleUnreliable,
	Client.TupleUnreliable,
	255,
	"A",
	65535,
	Instance,
	Instance
)
InvokeAndExpectTuple(
	"Function Tuple",
	Client.TupleFunction,
	Server.TupleFunction,
	{ 255, "A", 65535, Instance, Instance },
	{ Instance, Instance, 65535, "A", 255 }
)

FireAllAndExpectAll("Many events", 32, {
	Reliable = {
		Data = { 0 },
		Outgoing = Server.ReliableServer,
		Incoming = Client.ReliableServer,
	},
	Unreliable = {
		Data = { 0 },
		Outgoing = Server.UnreliableServer,
		Incoming = Client.UnreliableServer,
	},
	Reference = {
		Data = { Example },
		Outgoing = Server.Reference,
		Incoming = Client.Reference,
	},
	ReliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance, table.create(8, 0) },
		Outgoing = Server.Tuple,
		Incoming = Client.Tuple,
	},
	UnreliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance },
		Outgoing = Server.TupleUnreliable,
		Incoming = Client.TupleUnreliable,
	},
})

FireAndExpect("TagEnum Join", Server.PlayerEvent, Client.PlayerEvent, { Type = "Join", Name = "Player", UserId = 5 })
FireAndExpect("TagEnum Chat", Server.PlayerEvent, Client.PlayerEvent, { Type = "Chat", UserId = 5, Message = "Hello" })
FireAndExpect("TagEnum Leave", Server.PlayerEvent, Client.PlayerEvent, { Type = "Leave", UserId = 5 })

RunClosure("Color3", function()
	local Color = BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

	local Serialized = Server.Color.Write(Color)
	local Deserialized = Server.Color.Read(Serialized)

	assert(Color.R == Deserialized.R, `Expected {Color.R}, got {Deserialized.R}`)
	assert(Color.G == Deserialized.G, `Expected {Color.G}, got {Deserialized.G}`)
	assert(Color.B == Deserialized.B, `Expected {Color.B}, got {Deserialized.B}`)
end)

RunClosure("Color3 Array", function()
	local Colors = {}
	for _ = 1, 32 do
		table.insert(
			Colors,
			BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		)
	end

	local Serialized = Server.ColorArray.Write(Colors)
	local Deserialized = Server.ColorArray.Read(Serialized)

	assert(#Colors == #Deserialized, `Expected {#Colors} elements`)

	for Index, Got in Deserialized do
		local Expected = Colors[Index]
		assert(Expected.R == Got.R, `Expected {Expected.R}, got {Got.R}`)
		assert(Expected.G == Got.G, `Expected {Expected.G}, got {Got.G}`)
		assert(Expected.B == Got.B, `Expected {Expected.B}, got {Got.B}`)
	end
end)

RunClosure("DateTime", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestamp(2 ^ n)
		local Serialized = Server.DateSeconds.Write(DateTime)
		local Deserialized = Server.DateSeconds.Read(Serialized)
		assert(
			DateTime.UnixTimestamp == Deserialized.UnixTimestamp,
			`Expected timestamp {DateTime.UnixTimestamp}, got {Deserialized.UnixTimestamp}`
		)
	end
end)

RunClosure("DateTimeMillis", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestampMillis(2 ^ n)
		local Serialized = Server.DateMilliseconds.Write(DateTime)
		local Deserialized = Server.DateMilliseconds.Read(Serialized)
		assert(
			DateTime.UnixTimestampMillis == Deserialized.UnixTimestampMillis,
			`Expected timestamp {DateTime.UnixTimestampMillis}, got {Deserialized.UnixTimestampMillis}`
		)
	end
end)

RunClosure("BrickColor", function()
	local BrickColor = BaseEnvironment.BrickColor.new(373)
	local Serialized = Server.BrickkColor.Write(BrickColor)
	local Deserialized = Server.BrickkColor.Read(Serialized)

	assert(
		BrickColor.Number == Deserialized.Number,
		`Expected BrickColor number to be {BrickColor.Number}, got {Deserialized.Number}`
	)
end)

RunClosure("Nested Map", function()
	local Map = { string = 1 }
	local Serialized = Server.MapNested.Write({ [Map] = Map })
	local Deserialized = Server.MapNested.Read(Serialized)

	local Elements = 0
	for KeyMap, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(type(KeyMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(KeyMap.string) == "number", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end
end)

RunClosure("Standalone", function()
	local Original = {
		One = 1,
		Two = 2,
		Three = 3,
		Event = { Type = "Join", Name = "JohnDoe", UserId = 1 },
		Nested = {
			Four = "ABC",
			Five = "DEF",
		},
	}

	local Serialized = Server.Standalone.Write(Original)
	local Deserialized = Server.Standalone.Read(Serialized)

	assert(Equals(Original, Deserialized), "Deserialized doesn't match original")
end)

RunClosure("Disconnect & Queue", function()
	local Expect = 1
	local Events = {
		"ReliableServer",
		"UnreliableServer",
		"ManyReliableSync",
		"ManyReliableAsync",
		"ManyUnreliableSync",
		"ManyUnreliableAsync",
	}

	for _, Event in Events do
		local Outgoing = Server[Event]
		local Incoming = Client[Event]

		local NeverRecieve: never
		Incoming.On(function(Value: never)
			NeverRecieve = Value
		end)()

		local Recieve: typeof(Expect)
		local RecieveDisconnect = Incoming.On(function(Value: typeof(Expect))
			Recieve = Value
		end)

		Outgoing.FireAll(Expect)

		task.wait(0.5)

		if Recieve ~= Expect then
			error(`Failed queue test on {Event}, expected "{Expect}", got "{Recieve}"`)
		end

		if NeverRecieve ~= nil then
			error(`Failed disconnect test on {Event}, disconnected listener still recieving.`)
		end

		RecieveDisconnect()
	end
end)

local Element = { Static = 0, Dynamic = buffer.create(64) }

FireAndExpect("Dynamic Array Data Integrity", Server.DynamicArray, Client.DynamicArray, table.create(12, Element))
FireAndExpect("Dynamic Map Data Integrity", Server.DynamicMap, Client.DynamicMap, table.create(64, Element))

RunClosure("CLI compile prompt", function()
	pcall(function()
		fs.removeDir("../Network")
	end)

	local Result: process.ExecResult
	local Thread = task.spawn(function()
		Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE }, { cwd = "../src/CLI" })
	end)

	if coroutine.status(Thread) ~= "suspended" then
		error(Result and Result.stderr or "CLI didn't prompt")
	end

	task.cancel(Thread)
end)

RunClosure("CLI compile --yes", function()
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
end)

local MergeStruct: Server.MergeStruct = {
	Data = 1,
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
	AnotherNested = {
		Value = 1,
	},
	Map = {
		[{ 0 }] = 0,
	},
	Struct = {
		Data = 0,
		Array = { 0 },
		Nested = {
			Value = "hi",
		},
	},
}

FireAndPollExpect("Poll Reliable Client", Client.ClientPollEvent, Server.ClientPollEvent, MergeStruct)
FireAndPollExpect("Poll Reliable Server", Server.ServerPollEvent, Client.ServerPollEvent, MergeStruct)
FireAndPollExpect(
	"Poll Unreliable Client",
	Client.ClientUnreliablePollEvent,
	Server.ClientUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Unreliable Server",
	Server.ServerUnreliablePollEvent,
	Client.ServerUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect("Poll Empty Reliable Client", Client.ClientEmptyPollEvent, Server.ClientEmptyPollEvent, nil)
FireAndPollExpect("Poll Empty Reliable Server", Server.ServerEmptyPollEvent, Client.ServerEmptyPollEvent, nil)
FireAndPollExpect(
	"Poll Empty Unreliable Client",
	Client.ClientEmptyUnreliablePollEvent,
	Server.ClientEmptyUnreliablePollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Server",
	Server.ServerEmptyUnreliablePollEvent,
	Client.ServerEmptyUnreliablePollEvent,
	nil
)

RunClosure("Queue up and poll", function()
	local Expect = 10
	local Results = {
		Client = {},
		Server = {},
	}

	for _ = 1, Expect do
		Client.ClientPollEvent.Fire(MergeStruct)
		Server.ServerPollEvent.FireAll(MergeStruct)
	end

	task.wait(1 / 30)

	for _, Value in Client.ServerPollEvent.Iter() do
		table.insert(Results.Client, Value)
	end

	for _, Player, Value in Server.ClientPollEvent.Iter() do
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to be Player, got {Player} instead.`)
		end

		table.insert(Results.Server, Value)
	end

	for _, Context in Results do
		if #Context ~= Expect then
			ErrorPrint(`Expected to poll {Expect} events, got {#Results.Client} instead`)
		end

		for _, Result in Context do
			if not Equals(Result, MergeStruct) then
				Fail("Closure", Expect, Result)
			end
		end
	end
end)

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			Client.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			Client.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			Client.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundUpper.Write(2 ^ 53 + 1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundUpper.Write(-1)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundLower.Write(1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundLower.Write(-(2 ^ 53 + 1))
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	Client.ExactRange.Write(0)

	Client.DecimalRange.Write(-5.5)
	Client.DecimalRange.Write(10)

	Client.NegativeRange.Write(-5)
	Client.NegativeRange.Write(10)

	Client.UnboundUpper.Write(0)
	Client.UnboundUpper.Write(16777216)

	Client.UnboundLower.Write(-16777216)
	Client.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Nested = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = Client.MultiDimensionalArray.Write(Nested)
	local Deserialized = Client.MultiDimensionalArray.Read(Serialized)

	if not Equals(Nested, Deserialized) then
		ErrorPrint(`Expected: {Format(Nested)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		Server.Issue33.Event,
		Client.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("Static size analysis matches the emitter", function()
	--> src/Modules/Size.luau predicts how many bytes a type occupies; src/Generator/Prefabs.luau
	--> decides it. Nothing links the two, so the analysis can drift out of agreement with the
	--> compiler it describes and the only symptom would be a wrong diagnostic -- either a schema
	--> refused for no reason, or an oversize unreliable event let through.
	-->
	--> Every exported type carries a `.Write` that returns the exact bytes it produced, so the
	--> prediction can simply be checked against reality.
	local Parser = require("../src/Parser")
	local Size = require("../src/Modules/Size")

	local Source = fs.readFile("./Sources/Test.blink")
	local Tree = Parser.new("./Sources/", "Test.blink"):Parse(Source)

	local ByName = {}
	for _, Declaration in Tree.Value.Declarations do
		ByName[Declaration.Name] = Declaration
	end

	local Samples: { { Name: string, Value: any } } = {
		{ Name = "SizeByte", Value = 7 },
		{ Name = "SizeFixedString", Value = "abcdefgh" },
		{ Name = "SizeBoundedString", Value = "hello" },
		{ Name = "SizeBoundedString", Value = "" },
		{ Name = "SizeFixedArray", Value = { 1, 2, 3, 4 } },
		{ Name = "SizeBoundedArray", Value = { 1, 2, 3 } },
		{ Name = "SizeBoundedArray", Value = {} },
		{ Name = "SizeOptionalByte", Value = nil },
		{ Name = "SizeOptionalByte", Value = 5 },
		{ Name = "SizeStruct", Value = { A = 1, B = true, C = 2 } },
		{ Name = "SizeEnum", Value = "B" },
		{ Name = "SizeFlags", Value = { F1 = true, F3 = true } },
		{ Name = "SizeMap", Value = { [1] = 2, [3] = 4 } },
		{ Name = "Buffer", Value = buffer.create(10) },
		{ Name = "ExactBuffer", Value = buffer.create(9) },
		{ Name = "BoundedBuffer", Value = buffer.create(256) },
		{ Name = "MultiDimensionalArray", Value = { { { 1, 2 }, { 3 } }, { { 4 } } } },
	}

	for _, Sample in Samples do
		local Declaration = ByName[Sample.Name]
		if not Declaration then
			ErrorPrint(`Failed "Static size analysis": Test.blink has no exported type "{Sample.Name}".`)
		end

		local Measured = Size.Sealed(Declaration)
		local Length = buffer.len(Client[Sample.Name].Write(Sample.Value))

		if Length < Measured.Min or Length > Measured.Max then
			ErrorPrint(
				`Failed "Static size analysis": {Sample.Name} serialised to {Length} bytes, `
					.. `outside the predicted {Measured.Min}..{Measured.Max}.`
			)
		end
	end
end)

RunClosure("Export buffer trimming", function()
	local Buffer = Client.Byte.Write(0)
	if buffer.len(Buffer) ~= 1 then
		ErrorPrint(`Expected buffer to be trimmed to 1 byte`)
	end
end)

do
	local enum: Client.Indexers_TestEnums = "b b"
	local flags: Client.Indexers_TestFlags = { ["a a"] = true }
	local struct: Client.Indexers_TestStruct = {
		["z z"] = 0,
		["1 1"] = 1,
		["2 2"] = 2,
		["3 3"] = 3,
	}
	local tagged: Client.Indexers_TestTaggedEnums = {
		Type = "c c",
		Test = 1,
	}

	FireAndExpectTuple("Indexers", Server.Indexers.TestEvent, Client.Indexers.TestEvent, struct, flags, enum, tagged)
end

RunClosure("Buffer (Default, Fixed, Bounded)", function()
	local ExactBuffer = buffer.create(9)
	local BoundedBuffer = buffer.create(256)

	-- write some random bytes
	for offset = 0, 8, 4 do
		buffer.writeu8(ExactBuffer, offset, math.random(0, 2 ^ 30))
	end

	for offset = 0, 255, 4 do
		buffer.writeu8(BoundedBuffer, offset, math.random(0, 2 ^ 30))
	end

	-- test serdes
	do
		local Serialised = Client.Buffer.Write(BoundedBuffer)
		local Deserialised = Client.Buffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Default buffer serdes failed`)
	end

	do
		local Serialised = Client.ExactBuffer.Write(ExactBuffer)
		local Deserialised = Client.ExactBuffer.Read(Serialised)
		assert(Equals(ExactBuffer, Deserialised), `Fixed buffer serdes failed`)
	end

	do
		local Serialised = Client.BoundedBuffer.Write(BoundedBuffer)
		local Deserialised = Client.BoundedBuffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Bounded buffer serdes failed`)
	end
end)

RunClosure("Firing at a player who left does not resurrect their buffer", function()
	--> Upstream issue #84. A remote function's listener may yield, and the player can leave while it
	--> is suspended. PlayerRemoving clears their PlayersMap entry, but the resumed listener then
	--> wrote it straight back -- and nothing removes it a second time, so StepReplication allocated
	--> a buffer and fired a remote at a player who was gone on every Heartbeat, for ever.
	local Received = 0
	local Disconnect = Client.ReliableServer.On(function()
		Received += 1
	end)

	--> The player leaves.
	Shared.SetPlayerInGame(false)
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	--> This is the write a resumed listener performs. It must be dropped, not stored.
	Server.ReliableServer.Fire(Shared.Player, 1)

	--> Long enough for several Heartbeats, so a resurrected entry would replicate at least once.
	task.wait(0.5)

	Disconnect()
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(
			`Failed "Firing at a player who left": the client received {Received} event(s) after the player left.`
		)
	end

	--> And the map must be usable again for a player who is present.
	local ReceivedAfter = 0
	local DisconnectAfter = Client.ReliableServer.On(function()
		ReceivedAfter += 1
	end)

	Server.ReliableServer.Fire(Shared.Player, 1)
	task.wait(0.5)
	DisconnectAfter()

	if ReceivedAfter == 0 then
		ErrorPrint(`Failed "Firing at a player who left": a present player stopped receiving events.`)
	end
end)

RunClosure("Inbound packets are bounded", function()
	--> Upstream issue #45. The server parses a client's buffer in an unbounded loop, one event per
	--> iteration, so `buffer.create(1000000)` used to buy a million listener dispatches inside one
	--> remote callback. Three limits now bound that, and each is checked here.
	local MaxEventsPerPacket = 64

	--> 1. An oversized buffer is refused outright, before anything is parsed.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(64 * 1024), {})

		task.wait(0.2)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": an oversized packet was parsed ({Received} events).`)
		end
	end

	--> 2. A packet carrying more events than the cap is truncated, not parsed whole. Sent through
	--> the real client API so this exercises the same path a legitimate flood would take.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		for _ = 1, MaxEventsPerPacket * 2 do
			Client.ReliableClient.Fire(1)
		end

		task.wait(0.5)
		Disconnect()

		if Received > MaxEventsPerPacket then
			ErrorPrint(
				`Failed "Inbound packets are bounded": {Received} events decoded from one packet, cap is {MaxEventsPerPacket}.`
			)
		end

		if Received == 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": the cap swallowed legitimate traffic entirely.`)
		end
	end

	--> 3. The guard's shape, asserted against the emitted code.
	-->
	--> The remaining protections cannot be observed through these mocks: `Signal:Fire` dispatches via
	--> `task.spawn`, so a throw inside the remote handler lands in another thread and never reaches a
	--> pcall here — a behavioural test would pass whether or not the guard exists, which is worse
	--> than no test. What matters is that the generator still emits them, and that is checkable.
	-->
	--> A TRUNCATED packet is why the pcall is there: one byte tagging an event that carries data
	--> makes the reader run off the end of the buffer, and `Read` advances the cursor with no bounds
	--> check. That packet is SMALLER than a legitimate one, so no size cap can catch it.
	do
		local Source = fs.readFile("../Network/Server.luau")
		local Required = {
			["argument type check"] = `if typeof(Buffer) ~= "buffer" or type(Instances) ~= "table" then`,
			["departed player stops the loop"] = "Player.Parent ~= nil",
			["reliable remote class check"] = `assert(Reliable:IsA("RemoteEvent")`,
			["unreliable remote class check"] = `assert(Unreliable:IsA("UnreliableRemoteEvent")`,
			["oversized packet check"] = "if buffer.len(Buffer) >",
			["instance count check"] = "if #Instances >",
			["decoded event counter"] = "DecodedEvents += 1",
			["decode pcall"] = "local Parsed = pcall(function()",
			["decode failure stops the packet"] = "if not Parsed then break end",
			["unknown event id stops the packet"] = `error("[Blink]: Unknown event index.")`,
		}

		for Name, Fragment in Required do
			if not string.find(Source, Fragment, 1, true) then
				ErrorPrint(`Failed "Inbound packets are bounded": generated server code has no {Name}.`)
			end
		end
	end

	--> 4. Ordinary traffic still arrives untouched — a cap that breaks the normal path is worse than
	--> the hole it closes.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		Client.ReliableClient.Fire(1)
		task.wait(0.3)
		Disconnect()

		if Received ~= 1 then
			ErrorPrint(`Failed "Inbound packets are bounded": a single legitimate event arrived {Received} time(s).`)
		end
	end

	--> 5. Arguments of the wrong type are dropped rather than dispatched. A client picks what it
	--> passes to FireServer; the generated signature is a promise it never made.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, "not a buffer", {})
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(8), "not a table")
		Remote.OnServerEvent:Fire(Shared.Player)

		task.wait(0.3)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": malformed arguments dispatched {Received} event(s).`)
		end
	end
end)

RunClosure("Edit mode stubs keep the shape of the real API", function()
	--> Upstream issue #81. With `RunService:IsRunning()` false — edit mode, and therefore every
	--> Roblox story framework — the module returns a frozen stub table instead of touching remotes.
	--> A stub whose entries have the wrong SHAPE does not degrade quietly, it raises: `On` returning
	--> nil breaks `local Disconnect = ...On(...)`, and `Iter` returning nil breaks `for ... in`.
	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	local Stub = MockRequire("../Network/Server.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	local Disconnect = Stub.ReliableClient.On(function() end)
	if type(Disconnect) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": On returned {type(Disconnect)}, expected a disconnect function.`)
	end
	Disconnect()

	for _ in Stub.ClientPollEvent.Iter() do
		ErrorPrint(`Failed "Edit mode stubs": Iter yielded a value in edit mode.`)
	end

	if type(Stub.StepReplication) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": StepReplication is {type(Stub.StepReplication)}, expected a function.`)
	end
	Stub.StepReplication()

	--> Firing is a no-op rather than an error: a story that pushes state outward should not crash.
	Stub.ReliableServer.FireAll(1)
end)

RunClosure("Predict delivers to local listeners", function()
	--> Upstream issue #59. Predict hands an event to this side's own listeners without touching a
	--> remote, so receiving code can be driven directly from a test or a story.
	local Received: number?
	local Disconnect = Server.ReliableClient.On(function(_Player, Value)
		Received = Value
	end)

	Server.ReliableClient.Predict(Shared.Player, 42)

	if Received ~= 42 then
		ErrorPrint(`Failed "Predict": listener received {tostring(Received)}, expected 42.`)
	end

	Disconnect()

	--> It mirrors the receive path rather than only calling listeners: with none attached the event
	--> waits in the queue, exactly as a networked one would, and arrives when a listener connects.
	Server.ReliableClient.Predict(Shared.Player, 7)

	local Queued: number?
	local DisconnectQueued = Server.ReliableClient.On(function(_Player, Value)
		Queued = Value
	end)

	if Queued ~= 7 then
		ErrorPrint(`Failed "Predict": a queued event arrived as {tostring(Queued)}, expected 7.`)
	end

	DisconnectQueued()

	--> And it stays local: nothing may reach the wire.
	local Delivered = 0
	local Watch = Shared.Bridge:Connect(function()
		Delivered += 1
	end)

	Server.ReliableClient.Predict(Shared.Player, 1)
	task.wait(0.2)
	Watch.Disconnect()

	if Delivered ~= 0 then
		ErrorPrint(`Failed "Predict": {Delivered} packet(s) went over the wire.`)
	end
end)

RunClosure("Rate limiting", function()
	--> Neither zap nor upstream's rewrite has this, and it is the axis the packet caps cannot cover:
	--> MaxEventsPerPacket bounds one packet, while 200 well-formed packets a second pass every check
	--> there is. The bucket bounds events per second, per player, per event.
	-->
	--> The clock is the mock one from Shared, so "a second passes" is an exact statement rather than
	--> a race with the machine running the suite.

	--> Two things have to be settled before anything is counted.
	-->
	--> Earlier tests reach this event with raw buffers, and events that arrive with no listener bound
	--> are QUEUED and replayed the moment one is -- so attaching a listener and immediately counting
	--> credits this test with traffic it never sent. Attach first, let the replay land, then zero.
	-->
	--> The bucket those earlier events already spent from is cleared through PlayerRemoving, which
	--> dispatches via task.spawn, so it needs a moment of its own.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	local Received = 0
	local Disconnect = Server.RateLimited.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> An event with Rate 5 and Burst 10: ten arrive at once, the rest are refused.
	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)

	if Received ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Received} of 15 events arrived, expected the burst of 10.`)
	end

	--> One second of clock buys exactly five more tokens.
	Shared.AdvanceClock(1)

	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)
	Disconnect()

	if Received ~= 15 then
		ErrorPrint(`Failed "Rate limiting": {Received - 10} events arrived after a second, expected 5.`)
	end

	--> The polling path enqueues instead of dispatching, and is gated in the same place.
	Shared.AdvanceClock(10)

	for _ = 1, 15 do
		Client.RateLimitedPoll.Fire(1)
	end

	task.wait(0.4)

	local Polled = 0
	for _ in Server.RateLimitedPoll.Iter() do
		Polled += 1
	end

	if Polled ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Polled} of 15 polled events were queued, expected 10.`)
	end

	--> A refused INVOCATION still has to be answered. The caller is suspended with no timeout, so a
	--> silently dropped call would hang that coroutine until its slot was reused by an unrelated
	--> call -- which would then resume the wrong thread.
	Shared.AdvanceClock(10)
	Server.RateLimitedCall.On(function(_Player, Value)
		return Value
	end)

	local Succeeded, Refused = 0, 0
	for _ = 1, 4 do
		local Ok = pcall(function()
			return Client.RateLimitedCall.Invoke(1)
		end)

		if Ok then
			Succeeded += 1
		else
			Refused += 1
		end
	end

	if Succeeded ~= 2 or Refused ~= 2 then
		ErrorPrint(
			`Failed "Rate limiting": {Succeeded} invocations succeeded and {Refused} were refused, expected 2 and 2.`
		)
	end
end)

RunClosure("Invocation slots are recycled", function()
	--> The old allocator was a counter that wrapped at 255 and released a slot only on the error
	--> path, never on success. Two calls in flight across the wrap collided: the reused id was still
	--> occupied, so the collision check refused a legitimate call. A bitset hands out the first free
	--> slot instead, and a reply gives it straight back.

	Server.RemoteFunction.On(function(_Player, Value)
		task.wait(0.4)
		return Value
	end)

	local Completed, Refused = 0, 0
	for _ = 1, 40 do
		task.spawn(function()
			local Ok = pcall(function()
				return Client.RemoteFunction.Invoke(1)
			end)

			if Ok then
				Completed += 1
			else
				Refused += 1
			end
		end)
	end

	task.wait(1.5)

	--> Thirty-two slots exist, so eight of the forty must be turned away with an error rather than
	--> silently handed an id that belongs to another call.
	if Completed ~= 32 then
		ErrorPrint(`Failed "Invocation slots": {Completed} of 40 concurrent calls completed, expected 32.`)
	end

	if Refused ~= 8 then
		ErrorPrint(`Failed "Invocation slots": {Refused} calls were refused, expected 8.`)
	end

	--> And the slots came back: a call after the storm must simply work.
	local Success = pcall(function()
		return Client.RemoteFunction.Invoke(1)
	end)

	if not Success then
		ErrorPrint(`Failed "Invocation slots": a call after the burst was refused, so slots leaked.`)
	end
end)

RunClosure("Oversized unreliable payloads are dropped, not sent", function()
	--> Roblox drops an unreliable payload past ~900 bytes silently. The compiler refuses schemas that
	--> can never fit and warns about the ones that might not, but a bounded schema can still overflow
	--> at runtime -- a string longer than the game assumed -- and that packet would vanish with
	--> nobody told which event lost it.
	local Received = 0
	local Disconnect = Server.UnreliableOversize.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> Well under the limit: ordinary traffic must be untouched.
	Client.UnreliableOversize.Fire(string.rep("a", 32))
	task.wait(0.3)

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": a small payload arrived {Received} time(s), expected 1.`)
	end

	--> Past the limit: dropped at the send, with a warning naming the event.
	Client.UnreliableOversize.Fire(string.rep("a", 2000))
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": an oversized payload was sent anyway.`)
	end
end)

RunClosure("Decoding stops when the player leaves", function()
	--> Every listener that runs past this point is handed a Player already detached from the
	--> DataModel, and anything it does with them -- a leaderstats write, a save -- is work aimed at
	--> nobody. The loop condition now checks, so the rest of that packet is not decoded.
	local Received = 0
	local Disconnect = Server.ReliableClient.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	Shared.SetPlayerInGame(false)
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": {Received} event(s) were still dispatched.`)
	end

	--> And a present player is unaffected -- a guard that broke the normal path would be worse than
	--> the case it closes.
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": a present player received {Received}, expected 1.`)
	end
end)

RunClosure("Ordered unreliable events", function()
	--> Unreliable packets can arrive in any order. For anything that describes a CURRENT state -- a
	--> position, an aim direction -- applying an older packet after a newer one is worse than losing
	--> it: the state visibly snaps backwards.
	-->
	--> Delivery is captured rather than mocked away, then replayed backwards, which is the exact
	--> situation the sequence number exists for.
	local Received = {}
	local Disconnect = Server.OrderedPosition.On(function(_Player, Value)
		table.insert(Received, Value)
	end)

	task.wait(0.2)
	table.clear(Received)

	local Remote = ClientEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	local Original = Remote.FireServer
	local Captured = {}

	Remote.FireServer = function(_self, Buffer, Instances)
		table.insert(Captured, { Buffer = Buffer, Instances = Instances })
	end

	Client.OrderedPosition.Fire(1)
	Client.OrderedPosition.Fire(2)
	Client.OrderedPosition.Fire(3)
	Remote.FireServer = Original

	if #Captured ~= 3 then
		ErrorPrint(`Failed "Ordered unreliable": captured {#Captured} packets, expected 3.`)
	end

	local ServerRemote = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE

	--> Newest first, then the two older ones. Only the first may be dispatched.
	ServerRemote.OnServerEvent:Fire(Shared.Player, Captured[3].Buffer, Captured[3].Instances)
	ServerRemote.OnServerEvent:Fire(Shared.Player, Captured[1].Buffer, Captured[1].Instances)
	ServerRemote.OnServerEvent:Fire(Shared.Player, Captured[2].Buffer, Captured[2].Instances)

	task.wait(0.3)
	Disconnect()

	if #Received ~= 1 or Received[1] ~= 3 then
		ErrorPrint(
			`Failed "Ordered unreliable": received {#Received} event(s) ({table.concat(Received, ", ")}), `
				.. `expected only the newest.`
		)
	end

	--> In order, everything arrives: a check that drops stale packets must not drop fresh ones.
	local InOrder = {}
	local DisconnectOrdered = Server.OrderedPosition.On(function(_Player, Value)
		table.insert(InOrder, Value)
	end)

	Client.OrderedPosition.Fire(4)
	task.wait(0.15)
	Client.OrderedPosition.Fire(5)
	task.wait(0.3)
	DisconnectOrdered()

	if #InOrder ~= 2 then
		ErrorPrint(`Failed "Ordered unreliable": {#InOrder} of 2 in-order events arrived.`)
	end
end)

RunClosure("Offset-encoded lengths", function()
	--> A length is written relative to the declared minimum, in the smallest numeral that holds the
	--> SPAN. `u8[300..400]` has a hundred possible lengths, so one byte carries it -- where encoding
	--> 400 directly would have needed two.

	local Bounded = table.create(300, 7)
	local ArrayBuffer = Client.OffsetArray.Write(Bounded)

	if buffer.len(ArrayBuffer) ~= 301 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 300-element array took {buffer.len(ArrayBuffer)} bytes, expected 301.`
		)
	end

	if not Equals(Client.OffsetArray.Read(ArrayBuffer), Bounded) then
		ErrorPrint(`Failed "Offset-encoded lengths": the array did not survive the round trip.`)
	end

	--> The far end of the range must round-trip too: that is where the offset is largest.
	local Full = table.create(400, 3)
	if not Equals(Client.OffsetArray.Read(Client.OffsetArray.Write(Full)), Full) then
		ErrorPrint(`Failed "Offset-encoded lengths": a full-length array did not survive the round trip.`)
	end

	local Text = string.rep("a", 320)
	local TextBuffer = Client.OffsetString.Write(Text)

	if buffer.len(TextBuffer) ~= 321 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 320-character string took {buffer.len(TextBuffer)} bytes, expected 321.`
		)
	end

	if Client.OffsetString.Read(TextBuffer) ~= Text then
		ErrorPrint(`Failed "Offset-encoded lengths": the string did not survive the round trip.`)
	end

	local Bytes = buffer.create(350)
	local BytesBuffer = Client.OffsetBuffer.Write(Bytes)

	if buffer.len(BytesBuffer) ~= 351 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 350-byte buffer took {buffer.len(BytesBuffer)} bytes, expected 351.`
		)
	end

	--> Below the minimum the offset would go negative and wrap. It has to be refused by the SENDER,
	--> not discovered by the receiver as an unattributable length violation.
	local Refused = pcall(function()
		return Client.OffsetArray.Write(table.create(10, 1))
	end)

	if Refused then
		ErrorPrint(`Failed "Offset-encoded lengths": an array below the minimum was encoded anyway.`)
	end
end)

RunClosure("Bit packing", function()
	--> Booleans and optional presence flags take one BIT of a shared byte rather than a byte each.
	--> The numbers that matter are the ones either side of a byte boundary, and the round trip
	--> matters more than the size: a packing that loses a bit is worse than one that saves nothing.

	local function Booleans(Count: number): { [string]: boolean }
		local Value = {}
		for Index = 1, Count do
			--> Alternating rather than uniform, so a mask applied to the wrong bit shows up.
			Value[string.char(64 + Index)] = (Index % 2 == 1)
		end

		return Value
	end

	local Cases = {
		{ Name = "BitsOne", Count = 1, Bytes = 1 },
		{ Name = "BitsSeven", Count = 7, Bytes = 1 },
		{ Name = "BitsEight", Count = 8, Bytes = 1 },
		{ Name = "BitsNine", Count = 9, Bytes = 2 },
		{ Name = "BitsSeventeen", Count = 17, Bytes = 3 },
	}

	for _, Case in Cases do
		local Value = Booleans(Case.Count)
		local Buffer = Client[Case.Name].Write(Value)

		if buffer.len(Buffer) ~= Case.Bytes then
			ErrorPrint(
				`Failed "Bit packing": {Case.Count} booleans serialised to {buffer.len(Buffer)} bytes, `
					.. `expected {Case.Bytes}.`
			)
		end

		if not Equals(Client[Case.Name].Read(Buffer), Value) then
			ErrorPrint(`Failed "Bit packing": {Case.Count} booleans did not survive the round trip.`)
		end
	end

	--> Flags and booleans draw from the same byte, and an absent optional costs its bit and nothing
	--> else: four flags is one byte, plus one byte for the present u8.
	local Mixed = { A = true, B = 7, C = false }
	local MixedBuffer = Client.BitsMixed.Write(Mixed)

	if buffer.len(MixedBuffer) ~= 2 then
		ErrorPrint(`Failed "Bit packing": mixed flags serialised to {buffer.len(MixedBuffer)} bytes, expected 2.`)
	end

	if not Equals(Client.BitsMixed.Read(MixedBuffer), Mixed) then
		ErrorPrint(`Failed "Bit packing": mixed flags and optionals did not survive the round trip.`)
	end

	--> All four optionals absent: one byte of flags, nothing else.
	local Sparse = { A = false, C = true }
	local SparseBuffer = Client.BitsMixed.Write(Sparse)

	if buffer.len(SparseBuffer) ~= 1 then
		ErrorPrint(`Failed "Bit packing": absent optionals cost {buffer.len(SparseBuffer)} bytes, expected 1.`)
	end

	if not Equals(Client.BitsMixed.Read(SparseBuffer), Sparse) then
		ErrorPrint(`Failed "Bit packing": absent optionals did not survive the round trip.`)
	end
end)

--> Hostile-length specs live apart, but they run as part of the same suite.
require("./Decoding")

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
