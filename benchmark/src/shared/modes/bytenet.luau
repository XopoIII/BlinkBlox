local ByteNet = require("../../../packages/bytenet")

local function Booleans()
	return ByteNet.definePacket({
		value = ByteNet.array(ByteNet.bool),
	})
end

local function Entities()
	return ByteNet.definePacket({
		value = ByteNet.array(ByteNet.struct({
			id = ByteNet.uint8,
			x = ByteNet.uint8,
			y = ByteNet.uint8,
			z = ByteNet.uint8,
			orientation = ByteNet.uint8,
			animation = ByteNet.uint8,
		})),
	})
end

return ByteNet.defineNamespace("Benchmark", function()
	return {
		Booleans = Booleans(),
		Entities = Entities(),
		BooleansRandom = Booleans(),
		EntitiesRandom = Entities(),
	}
end)
