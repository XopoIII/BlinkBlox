--!strict
--- Finds how large a buffer an UnreliableRemoteEvent really carries.
---
--- Roblox documents a limit of 1000 bytes on an unreliable event's payload, and the payload is
--- every argument of the call as Roblox encodes it -- not the buffer alone. How much the encoding
--- adds is not documented, and `MaxUnreliableSize` bounds the buffer alone, so the budget it can
--- safely take is 1000 less that unknown. This measures it.
---
--- Both sides send buffers of every size in `SIZES`, several times each, in the shape BlinkBlox's
--- generated modules use -- `(Buffer, Instances)` -- and the receiving side records which sizes
--- arrived. Each series sends a different number of Instances beside the buffer, since each is a
--- reference Roblox has to encode as well. The buffers hold random bytes: Roblox compresses buffers,
--- and anything but random data would measure the compressor.
local Common = {}

Common.MIN_SIZE = 600
Common.MAX_SIZE = 1100
Common.REPEATS = 2

--> Instances sent beside the buffer, one series each. 0 is BlinkBlox's shape for an event with none.
Common.SERIES = { 0, 1, 4, 16 }

--> Sends a frame. Remotes are throttled at about 500 requests a second per client, shared between
--> every remote of a type, so this stays well under.
Common.PER_FRAME = 5

--> Seconds to let the last packets land before a side is counted.
Common.SETTLE = 3

--- A buffer of `Size` random bytes, stamped with its size and its series so the receiver can
--- attribute it.
function Common.Payload(Size: number, Series: number): buffer
	local Payload = buffer.create(Size)
	for Offset = 0, Size - 1 do
		buffer.writeu8(Payload, Offset, math.random(0, 255))
	end

	buffer.writeu16(Payload, 0, Size)
	buffer.writeu8(Payload, 2, Series)
	return Payload
end

--- Records a received payload into `Received[Series][Size]`, ignoring anything malformed.
function Common.Record(Received: { [number]: { [number]: boolean } }, Payload: unknown)
	if typeof(Payload) ~= "buffer" or buffer.len(Payload) < 3 then
		return
	end

	local Size = buffer.readu16(Payload, 0)
	local Series = buffer.readu8(Payload, 2)
	if Size ~= buffer.len(Payload) or Received[Series] == nil then
		return
	end

	Received[Series][Size] = true
end

function Common.NewRecord(): { [number]: { [number]: boolean } }
	local Received = {}
	for Index in Common.SERIES do
		Received[Index] = {}
	end
	return Received
end

--- Sends every size of every series through `Send`, `PER_FRAME` a frame.
function Common.SendAll(Send: (Payload: buffer, Instances: { Instance }) -> (), Parts: { Instance })
	local Sent = 0
	for Index, Count in Common.SERIES do
		local Instances = table.move(Parts, 1, Count, 1, {})
		for Size = Common.MIN_SIZE, Common.MAX_SIZE do
			for _ = 1, Common.REPEATS do
				Send(Common.Payload(Size, Index), Instances)
				Sent += 1
				if Sent % Common.PER_FRAME == 0 then
					task.wait()
				end
			end
		end
	end
end

export type Row = { Instances: number, LargestDelivered: number?, SmallestDropped: number? }

--- For each series: the largest size that arrived, and the smallest that never did.
function Common.Summarise(Received: { [number]: { [number]: boolean } }): { Row }
	local Summary: { Row } = {}
	for Index, Count in Common.SERIES do
		local Largest: number?, Smallest: number? = nil, nil
		for Size = Common.MIN_SIZE, Common.MAX_SIZE do
			if Received[Index][Size] then
				Largest = Size
			elseif Smallest == nil then
				Smallest = Size
			end
		end

		Summary[Index] = { Instances = Count, LargestDelivered = Largest, SmallestDropped = Smallest }
	end
	return Summary
end

return Common
