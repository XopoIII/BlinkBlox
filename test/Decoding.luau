--!strict
--- Specs that feed a decoder a length prefix no honest sender would write.
---
--- The point of each is WHERE the read fails, not merely that it does. Reading past the end of a
--- buffer has always thrown, and the decode loop's pcall has always turned that into a dropped
--- packet -- but only after the read, or in `buffer`'s case after an allocation the packet never
--- paid for. Asserting on the message is what distinguishes the two.
local Harness = require("./Harness")
local Modules = require("./Modules")

local Client = Modules.Client
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
	`to be smaller than 64`
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
	`to be smaller than 64`
)

--> `string(300..400)` encodes relative to its minimum, so the bound has to be checked against the
--> reconstructed length (255 + 300 = 555) and not against the numeral on the wire.
local OversizeOffsetString = buffer.create(1)
buffer.writeu8(OversizeOffsetString, 0, 255)
ExpectRejection(
	"An offset-encoded length is bounded after reconstruction",
	Client.OffsetString.Read,
	OversizeOffsetString,
	`to be smaller than 400`
)

--> A bounded buffer names a size the decoder would otherwise allocate before checking it.
local OversizeBuffer = buffer.create(2)
buffer.writeu16(OversizeBuffer, 0, 65535)
ExpectRejection(
	"A buffer larger than its bound is rejected before it is allocated",
	Client.BoundedBuffer.Read,
	OversizeBuffer,
	`to be smaller than 1000`
)

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
