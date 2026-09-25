--> A thousand different payloads, one for each event fired in a frame.
-->
--> Roblox compresses a remote's buffers with zstd before they go out. When every event in a packet
--> is the same, the packet compresses to almost nothing, and the bandwidth reported measures that
--> compression rather than the encoding. Payloads that differ from each other, with every field
--> drawn from the whole range of a u8, leave the compressor nothing to find.
local POOL = 1000
local LENGTH = 100

local Pool = table.create(POOL)
for Index = 1, POOL do
	local Payload = table.create(LENGTH)
	for Element = 1, LENGTH do
		Payload[Element] = {
			id = math.random(0, 255),
			x = math.random(0, 255),
			y = math.random(0, 255),
			z = math.random(0, 255),
			orientation = math.random(0, 255),
			animation = math.random(0, 255),
		}
	end
	Pool[Index] = Payload
end
return Pool
