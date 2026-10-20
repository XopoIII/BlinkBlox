--!strict
--!native
--!optimize 2

--- The Roblox datatypes for physics and space: PhysicalProperties, Rect, Region3 and Ray. Each is a
--- fixed run of f32; sizes are in Settings.
local Common = require("./Common")

type Block = Common.Block

local Types = Common.Types
local Primitives = Common.Primitives
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab

--> PhysicalProperties: all six fields, since one built from a material cannot be told from one built
--> from numbers -- `new(Enum.Material.Plastic)` has an AcousticAbsorption of 0.3, `new(0.7, 0.3, 0.5)`
--> one of 1. Roblox stores each as f32, so nothing is lost.
do
	--> The constructor clamps each field into its range and lets NaN through, so a hostile packet's
	--> NaN would reach a part's physics. Everything outside the range is refused, NaN included. The
	--> floor is 0 for Density too: the constructor raises it to 0.0001, a value f32 rounds below
	--> 0.0001, so a Density an honest sender wrote would fail a test against 0.0001.
	local FIELDS = {
		{ Name = "Density", Max = 100 },
		{ Name = "Friction", Max = 2 },
		{ Name = "Elasticity", Max = 1 },
		{ Name = "FrictionWeight", Max = 100 },
		{ Name = "ElasticityWeight", Max = 100 },
		{ Name = "AcousticAbsorption", Max = 1 },
	}

	Types.PhysicalProperties = {
		Read = function(Variable: string, Block: Block)
			local Locals = {}
			for _, Field in FIELDS do
				local Local = `Physical{Field.Name}`
				table.insert(Locals, Local)
				Types.f32.Read(Local, Block)
			end
			for Index, Field in FIELDS do
				local Local = Locals[Index]
				Block:Line(
					`if not ({Local} >= 0 and {Local} <= {Field.Max}) then error(\`Expected PhysicalProperties {Field.Name} from 0 to {Field.Max}, got \{{Local}} instead.\`) end`
				)
			end
			Block:Line(`{Block:Declare(Variable)} = PhysicalProperties.new({table.concat(Locals, ", ")})`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Physical = {Value}`)
			for _, Field in FIELDS do
				Types.f32.Write(`Physical.{Field.Name}`, Block)
			end
		end,
	}

	Primitives.PhysicalProperties = {
		Type = "PhysicalProperties",
		Generate = GeneratePrimitivePrefab("PhysicalProperties", Types.PhysicalProperties),
	}
end

--> Rect: Min, then Max. `Rect.new` orders the corners itself, so one built either way arrives as sent.
do
	Types.Rect = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("RectMinX", Block)
			Types.f32.Read("RectMinY", Block)
			Types.f32.Read("RectMaxX", Block)
			Types.f32.Read("RectMaxY", Block)
			Block:Line(`{Block:Declare(Variable)} = Rect.new(RectMinX, RectMinY, RectMaxX, RectMaxY)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Bounds = {Value}`)
			Types.f32.Write("Bounds.Min.X", Block)
			Types.f32.Write("Bounds.Min.Y", Block)
			Types.f32.Write("Bounds.Max.X", Block)
			Types.f32.Write("Bounds.Max.Y", Block)
		end,
	}

	Primitives.Rect = {
		Type = "Rect",
		Generate = GeneratePrimitivePrefab("Rect", Types.Rect),
	}
end

--> Region3: its two corners, which is what `Region3.new` takes. The constructor computes the centre
--> and size from them and rounds both to f32, so a region whose corners are not whole numbers can
--> come back a bit off in its last place; sending the centre and size instead fails as often.
do
	Types.Region3 = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("RegionMinX", Block)
			Types.f32.Read("RegionMinY", Block)
			Types.f32.Read("RegionMinZ", Block)
			Types.f32.Read("RegionMaxX", Block)
			Types.f32.Read("RegionMaxY", Block)
			Types.f32.Read("RegionMaxZ", Block)
			Block:Line(
				`{Block:Declare(Variable)} = Region3.new(Vector3.new(RegionMinX, RegionMinY, RegionMinZ), Vector3.new(RegionMaxX, RegionMaxY, RegionMaxZ))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Region = {Value}`)
			Block:Line("local RegionCenter = Region.CFrame.Position")
			Block:Line("local RegionHalf = Region.Size / 2")
			Types.f32.Write("RegionCenter.X - RegionHalf.X", Block)
			Types.f32.Write("RegionCenter.Y - RegionHalf.Y", Block)
			Types.f32.Write("RegionCenter.Z - RegionHalf.Z", Block)
			Types.f32.Write("RegionCenter.X + RegionHalf.X", Block)
			Types.f32.Write("RegionCenter.Y + RegionHalf.Y", Block)
			Types.f32.Write("RegionCenter.Z + RegionHalf.Z", Block)
		end,
	}

	Primitives.Region3 = {
		Type = "Region3",
		Generate = GeneratePrimitivePrefab("Region3", Types.Region3),
	}
end

--> Ray: Origin, then Direction.
do
	Types.Ray = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("RayOriginX", Block)
			Types.f32.Read("RayOriginY", Block)
			Types.f32.Read("RayOriginZ", Block)
			Types.f32.Read("RayDirectionX", Block)
			Types.f32.Read("RayDirectionY", Block)
			Types.f32.Read("RayDirectionZ", Block)
			Block:Line(
				`{Block:Declare(Variable)} = Ray.new(Vector3.new(RayOriginX, RayOriginY, RayOriginZ), Vector3.new(RayDirectionX, RayDirectionY, RayDirectionZ))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Line = {Value}`)
			Types.f32.Write("Line.Origin.X", Block)
			Types.f32.Write("Line.Origin.Y", Block)
			Types.f32.Write("Line.Origin.Z", Block)
			Types.f32.Write("Line.Direction.X", Block)
			Types.f32.Write("Line.Direction.Y", Block)
			Types.f32.Write("Line.Direction.Z", Block)
		end,
	}

	Primitives.Ray = {
		Type = "Ray",
		Generate = GeneratePrimitivePrefab("Ray", Types.Ray),
	}
end

return {}
