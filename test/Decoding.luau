--!strict
--- Specs that feed a decoder a length prefix no honest sender would write.
---
--- The point of each is WHERE the read fails, not merely that it does. Reading past the end of a
--- buffer has always thrown, and the decode loop's pcall has always turned that into a dropped
--- packet -- but only after the read, or in `buffer`'s case after an allocation the packet never
--- paid for. Asserting on the message is what distinguishes the two.
local Harness = require("./Harness")
local Modules = require("./Modules")
local ServerEnvironment = require("./Server")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server
local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local function ExpectRejection(Name: string, Read: (buffer) -> any, Payload: buffer, Expected: string)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Success, Thrown = pcall(Read, Payload)
	if Success then
		ErrorPrint(`Failed "{Name}": the read accepted a hostile length instead of rejecting it.`)
	end

	local Message = tostring(Thrown)
	if not string.find(Message, Expected, 1, true) then
		ErrorPrint(`Failed "{Name}": expected the rejection to mention "{Expected}", got "{Message}" instead.`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

--> `string(0..64)` spends its prefix on the span, so the numeral is a u8 and 255 fits in it.
--> With the bytes present the declared bound is the only thing that rejects them.
local OversizeString = buffer.create(1 + 255)
buffer.writeu8(OversizeString, 0, 255)
ExpectRejection(
	"A string longer than its bound is rejected",
	Client.SizeBoundedString.Read,
	OversizeString,
	`to be smaller than or equal to 64`
)

--> The same prefix over a packet that does not carry those bytes. This is the spec that tells the
--> two orderings apart: checking after the read reports an out-of-bounds access from deep inside
--> `buffer.readstring`, naming neither the field nor the bound it violated.
local TruncatedString = buffer.create(1)
buffer.writeu8(TruncatedString, 0, 255)
ExpectRejection(
	"A string length is checked before the read, not after",
	Client.SizeBoundedString.Read,
	TruncatedString,
	`to be smaller than or equal to 64`
)

--> `string(300..400)` encodes relative to its minimum, so the bound has to be checked against the
--> reconstructed length (255 + 300 = 555) and not against the numeral on the wire.
local OversizeOffsetString = buffer.create(1)
buffer.writeu8(OversizeOffsetString, 0, 255)
ExpectRejection(
	"An offset-encoded length is bounded after reconstruction",
	Client.OffsetString.Read,
	OversizeOffsetString,
	`to be smaller than or equal to 400`
)

--> A bounded buffer names a size the decoder would otherwise allocate before checking it.
local OversizeBuffer = buffer.create(2)
buffer.writeu16(OversizeBuffer, 0, 65535)
ExpectRejection(
	"A buffer larger than its bound is rejected before it is allocated",
	Client.BoundedBuffer.Read,
	OversizeBuffer,
	`to be smaller than or equal to 1000`
)

--> NaN has no magnitude that compares within a range, so a vector carrying one must fail the check
--> written `not (Magnitude >= Min)` rather than slip past one written `Magnitude < Min`.
local NanVector = buffer.create(12)
for Offset = 0, 8, 4 do
	buffer.writef32(NanVector, Offset, 0 / 0)
end
ExpectRejection("A vector with a NaN component fails its range", Client.RangedVector.Read, NanVector, `magnitude`)

--> An unbounded buffer has no declared size to check, so the space left in the packet is the only
--> thing standing between a two-byte payload and a 64 KB allocation.
local UnboundedBuffer = buffer.create(2)
buffer.writeu16(UnboundedBuffer, 0, 65535)
ExpectRejection(
	"An unbounded length is bounded by the packet",
	Client.Buffer.Read,
	UnboundedBuffer,
	`bytes left in the packet`
)

--> `table.create(Length)` reserves every slot before the loop runs, so a count the packet cannot
--> back still buys the allocation even though the first iteration fails. `ColorArray` is `Color3[]`
--> at three bytes an element, so 65535 of them would need 196605 bytes the packet does not have.
local OversizeArray = buffer.create(2)
buffer.writeu16(OversizeArray, 0, 65535)
ExpectRejection(
	"An array is refused before its slots are reserved",
	Client.ColorArray.Read,
	OversizeArray,
	`bytes left in the packet`
)

--> A packed `boolean[]` costs an eighth of a byte an element, so its guard is on the bytes the run
--> takes rather than on the count. 65535 elements need 8192 bytes; ten are not enough.
local OversizePacked = buffer.create(2 + 10)
buffer.writeu16(OversizePacked, 0, 65535)
ExpectRejection(
	"A packed boolean array is refused before its slots are reserved",
	Client.PackedBooleans.Read,
	OversizePacked,
	`bytes left in the packet`
)

--> And the converse, which a guard written against a whole byte per element would get wrong: 800
--> elements in the 100 bytes they honestly take.
do
	local Name = "A packed boolean array that fits is not refused"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Honest = buffer.create(2 + 100)
	buffer.writeu16(Honest, 0, 800)
	local Success, Result = pcall(Client.PackedBooleans.Read, Honest)
	if not Success or #Result ~= 800 then
		ErrorPrint(`Failed "{Name}": {if Success then `read {#Result} elements` else tostring(Result)}.`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

--> The instance table travels beside the buffer as the remote's second argument, and a client
--> chooses both. `unknown` reads from it without checking, so a buffer that claims values the table
--> does not hold used to decode as nil -- and inside a loop, to decode as nil for as long as the
--> count said. A real packet replayed with its instances removed is the cheapest way to show it.
do
	local Name = "A packet that under-supplies instances is dropped"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE

	--> Connected before anything is sent. A decoded event whose listener arrives later is held in
	--> the queue and delivered on connect, so a counter attached afterwards would score the honest
	--> packet and never look at the replay.
	local Received = 0
	local Disconnect = Server.UnknownInbound.On(function()
		Received += 1
	end)

	local Captured: buffer?
	local Spy = Remote.OnServerEvent:Connect(function(_Player, Buffer: buffer)
		Captured = Buffer
	end)

	Client.UnknownInbound.Fire(newproxy())
	task.wait(1 / 30)
	Spy.Disconnect()

	local Packet = Captured
	if not Packet then
		Disconnect()
		ErrorPrint(`Failed "{Name}": the client sent no packet to replay.`)
		return
	end

	--> The same packet, honestly delivered, has to arrive -- otherwise the replay proving nothing
	--> would look like a pass.
	if Received ~= 1 then
		Disconnect()
		ErrorPrint(`Failed "{Name}": the honest packet was not delivered ({Received} events).`)
	end

	Remote.OnServerEvent:Fire(Shared.Player, Packet, {})
	task.wait(1 / 30)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "{Name}": the replay decoded despite carrying none of the instances it claims.`)
	end

	OkPrint(`Test "{Name}" passed!`)
end
