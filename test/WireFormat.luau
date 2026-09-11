--!strict
--- Specs for the three wire-format changes that landed in 0.21.0: a sequence number on ordered
--- unreliable events, lengths encoded relative to their declared minimum, and booleans and optional
--- presence flags packed into a shared bitfield.
---
--- Each asserts on the BYTE COUNT as well as the round trip. A format change that still round-trips
--- but costs what it used to has not done anything, and only the length tells them apart.
---
--- They live apart from Test.luau, like Decoding.luau, but run as part of the same suite.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local Client = Modules.Client
local Server = Modules.Server

local ErrorPrint = Harness.ErrorPrint

local Equals = Assertions.Equals
local RunClosure = Assertions.RunClosure

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
