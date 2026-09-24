--!strict
--- The behavioural suite: every spec loads the generated modules against mocked Roblox globals and
--- drives them the way a game would. Building those modules -- compiling, goldens, diagnostics --
--- lives in Harness.luau.
local Harness = require("./Harness")
local process = require("@lune/process")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

Harness.Prepare()

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()

local Modules = require("./Modules")
local Client = Modules.Client
local Server = Modules.Server

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

--> A map as a VALUE. This used to key the outer map by the inner one, which round-tripped every byte
--> and still produced something unusable -- each decoded key was a fresh table, so the receiver
--> could only ever reach an entry by iterating. The compiler now refuses that shape; nesting on the
--> value side, which is what people actually mean by a nested map, is unaffected.
RunClosure("Nested Map", function()
	local Inner = { string = 1 }
	local Serialized = Server.MapNested.Write({ Outer = Inner })
	local Deserialized = Server.MapNested.Read(Serialized)

	local Elements = 0
	for Key, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(Key == "Outer", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end

	assert(Elements == 1, "Deserialized doesn't match original")
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
	--> Keyed by a string since GenericMerge stopped instantiating its map with an array key -- a
	--> decoded array key is a fresh table and can never be looked up.
	Map = {
		Key = 0,
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

--> These live apart, but they run as part of the same suite. New specs go in files like these rather
--> than on the end of this one.
require("./Ranges")
require("./Buffers")
require("./Listeners")
require("./SizeAnalysis")
require("./Guards")
require("./Predict")
require("./InboundBudget")
require("./Invocations")
require("./Signature")
require("./Profiles")
require("./SchemaDrift")
require("./TypePacks")
require("./ClientDecoding")
require("./SyncValidation")
require("./Highlighting")
require("./WireFormat")
require("./Encodings")
require("./WriteBounds")
require("./Decoding")
require("./BufferIntegrity")

--> LAST, and deliberately so: the CLI specs delete ../Network to prove the compiler recreates a
--> missing output directory, and then recompile only Test.blink. Everything generated from the other
--> schemas is gone afterwards, so any spec that reads a generated FILE has to have run already.
require("./CommandLine")

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
