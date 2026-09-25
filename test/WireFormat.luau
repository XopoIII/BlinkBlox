--!strict
--- Specs for the three wire-format changes that landed in 0.21.0: a sequence number on ordered
--- unreliable events, lengths encoded relative to their declared minimum, and booleans and optional
--- presence flags packed into a shared bitfield. And the one from 0.27.0: `boolean[]` eight to a byte.
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

RunClosure("Packed boolean arrays", function()
	--> A pattern that is neither all one value nor periodic in eight, so a wrong mask, a wrong byte
	--> offset or a bit order reversed within the byte all show up as a changed element.
	local Seed = 0
	local function Pattern(Count: number): { boolean }
		local Values = table.create(Count)
		for Index = 1, Count do
			Seed = (Seed * 1103515245 + 12345) % 2147483648
			table.insert(Values, (Index % 3 == 0) ~= (Seed % 2 == 0))
		end
		return Values
	end

	--> The length prefix is a u16, then one byte per eight elements, rounded up.
	local Cases = {
		{ Count = 0, Bytes = 2 },
		{ Count = 1, Bytes = 3 },
		{ Count = 7, Bytes = 3 },
		{ Count = 8, Bytes = 3 },
		{ Count = 9, Bytes = 4 },
		{ Count = 17, Bytes = 5 },
		{ Count = 1000, Bytes = 127 },
	}

	for _, Case in Cases do
		local Value = Pattern(Case.Count)
		local Buffer = Client.PackedBooleans.Write(Value)

		if buffer.len(Buffer) ~= Case.Bytes then
			ErrorPrint(
				`Failed "Packed boolean arrays": {Case.Count} elements serialised to {buffer.len(Buffer)} bytes, `
					.. `expected {Case.Bytes}.`
			)
		end

		if not Equals(Client.PackedBooleans.Read(Buffer), Value) then
			ErrorPrint(`Failed "Packed boolean arrays": {Case.Count} elements did not survive the round trip.`)
		end
	end

	--> Bit order is part of the format: element one is the least significant bit, like `Block.Bit`.
	local Ordered = Client.PackedBooleans.Write({ true, false, false, false, false, false, false, false, true })
	if buffer.readu8(Ordered, 2) ~= 0x01 or buffer.readu8(Ordered, 3) ~= 0x01 then
		ErrorPrint(`Failed "Packed boolean arrays": the first element is not the least significant bit.`)
	end

	--> Every other shape a packed run can sit in. The fixed and ranged lengths, the run beside plain
	--> booleans that share the struct's bitfield, one per map value, nested, and through an alias.
	local Shapes: { { Name: string, Value: any, Bytes: number? } } = {
		{ Name = "PackedFixed", Value = Pattern(10), Bytes = 2 },
		{ Name = "PackedRanged", Value = Pattern(3), Bytes = 2 },
		{ Name = "PackedRanged", Value = Pattern(20), Bytes = 4 },
		{ Name = "PackedThroughAlias", Value = Pattern(12), Bytes = 4 },
		{ Name = "PackedNested", Value = { Pattern(3), {}, Pattern(9) } },
		{
			Name = "PackedBeside",
			Value = { A = true, List = Pattern(11), B = false, Fixed = { true, false, true }, C = 200 },
			--> Bitfield, u16 length, the fixed run and the u8, then the variable run's two bytes.
			Bytes = 7,
		},
		{ Name = "PackedMap", Value = { First = Pattern(5), Second = {}, Third = Pattern(16) } },
	}

	for _, Shape in Shapes do
		local Buffer = Client[Shape.Name].Write(Shape.Value)
		if Shape.Bytes and buffer.len(Buffer) ~= Shape.Bytes then
			ErrorPrint(
				`Failed "Packed boolean arrays": {Shape.Name} serialised to {buffer.len(Buffer)} bytes, `
					.. `expected {Shape.Bytes}.`
			)
		end

		if not Equals(Client[Shape.Name].Read(Buffer), Shape.Value) then
			ErrorPrint(`Failed "Packed boolean arrays": {Shape.Name} did not survive the round trip.`)
		end
	end

	--> Under WriteValidations a non-boolean is refused by the index of the first one, whether it sits
	--> in a whole byte, which is tested eight elements at once, or in the partial byte at the end.
	local Refusals = {
		{ Index = 3, Count = 16, Expected = "Value[3] to be of type boolean, got number" },
		{ Index = 12, Count = 16, Expected = "Value[12] to be of type boolean, got string" },
		{ Index = 18, Count = 19, Expected = "Value[18] to be of type boolean, got table" },
	}
	local Wrong: { [number]: any } = { [3] = 1, [12] = "true", [18] = {} }

	for _, Refusal in Refusals do
		local Value = Pattern(Refusal.Count) :: { any }
		Value[Refusal.Index] = Wrong[Refusal.Index]
		if Refusal.Index == 3 then
			--> A later bad element in the same byte must not be the one named.
			Value[5] = "later"
		end

		local Success, Result = pcall(Client.PackedBooleans.Write, Value :: any)
		if Success or not string.find(tostring(Result), Refusal.Expected, 1, true) then
			ErrorPrint(
				`Failed "Packed boolean arrays": a non-boolean at {Refusal.Index} was reported as `
					.. `{if Success then "nothing" else tostring(Result)}, expected "{Refusal.Expected}".`
			)
		end
	end
end)
