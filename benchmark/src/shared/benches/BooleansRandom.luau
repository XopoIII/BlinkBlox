--> A thousand different payloads, one for each event fired in a frame.
-->
--> Roblox compresses a remote's buffers with zstd before they go out. When every event in a packet
--> is the same, the packet compresses to almost nothing, and the bandwidth reported measures that
--> compression rather than the encoding. Payloads that differ from each other, with every bit
--> random, leave the compressor nothing to find.
local POOL = 1000
local LENGTH = 1000

local Pool = table.create(POOL)
for Index = 1, POOL do
	local Payload = table.create(LENGTH)
	for Element = 1, LENGTH do
		Payload[Element] = math.random(0, 1) == 1
	end
	Pool[Index] = Payload
end
return Pool
