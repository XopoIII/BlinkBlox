--!strict
--- Random values for a schema type.
---
--- The property specs in Properties.luau draw values here, send them through the generated modules,
--- and judge what comes back by Oracle.luau. Neither file reads the generated code: they walk the
--- parsed schema, so a serialiser that disagrees with the schema disagrees with them.
---
--- The draws lean on the edges on purpose. A uniform draw from `u32` or a 65535-byte string almost
--- never lands on the value a bug needs -- a range's own bound, a length of 256, an f16 subnormal --
--- and those are where the last release's serialiser bugs were.
local Narrow = require("@compiler/Generator/Prefabs/Narrow")
local Oracle = require("./Oracle")
local Settings = require("@compiler/Settings")

type Node = { Type: string, Name: string, Value: any, Tokens: any }

local Generate = {}

--- While set, draws ignore the ranges the schema declares -- lengths past their bound, integers past
--- their range but inside their type, floats that are not exactly representable -- to check what the
--- sender does with a value the receiver would not accept. Roblox datatypes aside, nothing drawn
--- this way is a value the language rules out writing.
Generate.Wild = false

--- Raised for a type these specs do not draw: Roblox datatypes and instances, which have specs of
--- their own and would need the mocked globals to construct.
Generate.Unsupported = "Unsupported"

local INTEGERS = { u8 = true, u16 = true, u24 = true, u32 = true, i8 = true, i16 = true, i24 = true, i32 = true }
local FLOATS = { f16 = true, f24 = true, f32 = true, f64 = true }

--> Past this, a draw of a length or a count stays near the lower bound unless it takes an edge.
local SMALL = 8

--> Elements one draw may hold in all. Edges are drawn at every level, and `u8[][][]` with a length
--> of 256 at each is sixteen million elements; past the budget, lengths fall back to the small end.
local BUDGET = 4096
local Remaining = BUDGET

local function Chance(Probability: number): boolean
	return math.random() < Probability
end

local function Pick<T>(List: { T }): T
	return List[math.random(1, #List)]
end

local function PrimitiveName(Node: Node): string
	return Node.Tokens.Primitive.Value
end

--- The value an IEEE half-precision bit pattern stands for, decoded without reference to the
--- compiler's own f16 code, so the two can be checked against each other.
function Generate.HalfFromBits(Bits: number): number
	local Sign = if Bits >= 0x8000 then -1 else 1
	local Exponent = (Bits // 0x400) % 0x20
	local Mantissa = Bits % 0x400

	if Exponent == 0x1F then
		return if Mantissa == 0 then Sign * math.huge else 0 / 0
	elseif Exponent == 0 then
		return Sign * math.ldexp(Mantissa, -24)
	end

	return Sign * math.ldexp(0x400 + Mantissa, Exponent - 25)
end

--- The value an f24 bit pattern stands for -- a sign, six bits of exponent biased by 31 and
--- seventeen of mantissa, laid out as IEEE lays out a half -- decoded without the compiler's code.
function Generate.Float24FromBits(Bits: number): number
	local Sign = if Bits >= 0x800000 then -1 else 1
	local Exponent = (Bits // 0x20000) % 0x40
	local Mantissa = Bits % 0x20000

	if Exponent == 0x3F then
		return if Mantissa == 0 then Sign * math.huge else 0 / 0
	elseif Exponent == 0 then
		return Sign * math.ldexp(Mantissa, -47)
	end

	return Sign * math.ldexp(0x20000 + Mantissa, Exponent - 48)
end

local F32 = Oracle.F32

--- A length or count in [Min, Max], usually small, sometimes on an edge.
local function Length(Min: number, Max: number): number
	local Drawn: number
	if Generate.Wild and Max < 65535 and Chance(0.5) then
		Drawn = math.random(Max + 1, math.min(Max + 300, 65535))
	elseif Min == Max then
		Drawn = Min
	else
		Drawn = math.random(Min, math.min(Max, Min + SMALL))

		local Edge = Pick({ Min, Max, Min + 1, Max - 1, 255, 256, 257 })
		if Chance(0.3) and Edge >= Min and Edge <= Max and Edge <= Remaining then
			Drawn = Edge
		end
	end

	Remaining = math.max(Remaining - Drawn, 0)
	return Drawn
end

--- A scaled integer: a whole number of steps inside its bounds, leaning on their edges -- or, wild,
--- any real near them, between steps, past them, or NaN, since a saturated one takes all of those.
local function Scaled(Node: Node): number
	local Scale = Node.Value.Scale
	local Min, Max = Oracle.Bounds(Node)

	if Generate.Wild then
		local Bounds = Settings.Primtives[PrimitiveName(Node)].Bounds
		local Low, High = Oracle.Decode(Scale, Bounds.Min), Oracle.Decode(Scale, Bounds.Max)
		if Chance(0.4) then
			return Pick({
				Min - Scale * 0.4,
				Min - Scale * 0.6,
				Max + Scale * 0.4,
				Max + Scale * 0.6,
				Low - Scale,
				High + Scale,
				0 / 0,
				math.huge,
				-math.huge,
			})
		end

		return Low + math.random() * (High - Low)
	end

	local Lower, Upper = Oracle.Steps(Scale, Min), Oracle.Steps(Scale, Max)
	local Steps = Lower + math.floor(math.random() * (Upper - Lower + 1))
	if Chance(0.4) then
		local Edge = Pick({ Lower, Upper, Lower + 1, Upper - 1, 0, 1, -1 })
		if Edge >= Lower and Edge <= Upper then
			Steps = Edge
		end
	end

	return Oracle.Decode(Scale, Steps)
end

local function Integer(Node: Node): number
	if Node.Value.Scale then
		return Scaled(Node)
	elseif Generate.Wild and Node.Value.Saturate and Chance(0.3) then
		--> A saturated integer takes a fraction and NaN too, and sends the nearest value it holds.
		return Pick({ 0 / 0, math.huge, -math.huge, 0.5, -0.5, 254.5, 1e9 })
	end

	local Declared = if Generate.Wild then nil else Node.Value.Range
	local Bounds = Declared or Settings.Primtives[PrimitiveName(Node)].Bounds
	local Min, Max = Bounds.Min, Bounds.Max

	if Chance(0.4) then
		local Edge = Pick({ Min, Max, Min + 1, Max - 1, 0, 1, -1 })
		if Edge >= Min and Edge <= Max then
			return Edge
		end
	end

	--> math.random takes 32-bit bounds; a u32's range is drawn as a fraction instead.
	return Min + math.floor(math.random() * (Max - Min + 1))
end

--- Any double at all, leaning on the places a narrowing to f16 or f32 goes wrong: the edges of the
--- subnormals, the largest finite values, and just past them.
local function WildFloat(): number
	if Chance(0.4) then
		local Edge = Pick({
			65504,
			65519,
			65520,
			1e5,
			6.1e-5,
			6.103e-5,
			6.1035e-5,
			5.96e-8,
			2.9e-8,
			3e-8,
			1e-10,
			--> f24's: its largest finite value and where rounding passes it, its smallest normal and
			--> subnormal, and a mantissa that rounds up into the next binade.
			4294950912,
			4294959104,
			9.3132e-10,
			7.1e-15,
			1023.9999999,
		})
		return Edge * Pick({ 1, -1 }) * (1 + (math.random() - 0.5) * 1e-4)
	end

	return (math.random() * 2 - 1) * Pick({ 1, 1000, 1e6, 1e-3, 1e-6, 1e40 })
end

--- A float the type holds exactly, so that it must come back unchanged.
local function Float(Node: Node): number
	local Name = PrimitiveName(Node)
	local Range = Node.Value.Range

	if Generate.Wild then
		return WildFloat()
	end

	for _ = 1, 32 do
		local Value: number
		if Name == "f16" then
			local Bits = if Chance(0.3)
				then Pick({ 0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x0400, 0x7BFF, 0xFBFF, 0x7C00, 0xFC00, 0x7E00 })
				else math.random(0, 0xFFFF)
			Value = Generate.HalfFromBits(Bits)
		elseif Name == "f24" then
			local Bits = if Chance(0.3)
				then Pick({
					0x000000,
					0x800000,
					0x000001,
					0x800001,
					0x01FFFF,
					0x020000,
					0x7DFFFF,
					0xFDFFFF,
					0x7E0000,
					0xFE0000,
					0x7F0000,
				})
				else math.random(0, 0xFFFFFF)
			Value = Generate.Float24FromBits(Bits)
		elseif Chance(0.3) then
			Value =
				Pick({ 0, -0, 1, -1, math.huge, -math.huge, 0 / 0, 2 ^ 24, 2 ^ 24 + 2, 1e-45, 3.4e38, 1e300, -1e300 })
			if Range and Chance(0.5) then
				Value = Pick({ Range.Min, Range.Max })
			end
		else
			local Scale = Pick({ 1, 1000, 1e6, 1e-3 })
			Value = (math.random() * 2 - 1) * Scale
			if Range then
				local Low = math.max(Range.Min, -1e6)
				local High = math.min(Range.Max, 1e6)
				Value = Low + math.random() * (High - Low)
			end
		end

		if Name == "f32" then
			Value = F32(Value)
		end

		--> A saturated float sends NaN and what lies past its bounds as something else, so neither
		--> comes back as itself.
		local Min, Max = Oracle.Bounds(Node)
		local Carried = not Node.Value.Saturate or (Value == Value and Value >= Min and Value <= Max)

		if Carried and Oracle.Admits(Node, Value) then
			return Value
		end
	end

	--> Every range holds its narrowed lower bound, unless it is empty -- which the parser refuses.
	local Low = Narrow.Bounds(Name, Range.Min, Range.Max)
	return Low
end

local function Bytes(Count: number): string
	local Characters = table.create(Count)
	for Index = 1, Count do
		Characters[Index] = string.char(math.random(0, 255))
	end

	return table.concat(Characters)
end

local Draw: (Node: Node) -> any

--- A random value of the type `Node` describes.
function Generate.Value(Node: Node): any
	Remaining = BUDGET
	return Draw(Node)
end

function Draw(Node: Node): any
	local Value = Node.Value

	if Node.Type == "Primitive" then
		local Name = PrimitiveName(Node)
		if INTEGERS[Name] then
			return Integer(Node)
		elseif FLOATS[Name] then
			return Float(Node)
		elseif Name == "boolean" then
			return Chance(0.5)
		elseif Name == "string" or Name == "buffer" then
			local Range = Value.Range
			local Count = Length(if Range then Range.Min else 0, if Range then Range.Max else 65535)
			local Text = Bytes(Count)
			return if Name == "string" then Text else buffer.fromstring(Text)
		end

		error(Generate.Unsupported, 0)
	elseif Node.Type == "Optional" then
		return if Chance(0.3) then nil else Draw(Value.Of)
	elseif Node.Type == "Enum" then
		return Pick(Value.Values)
	elseif Node.Type == "Set" then
		local Flags = {}
		for _, Flag in Value.Values do
			Flags[Flag] = Chance(0.5)
		end

		return Flags
	elseif Node.Type == "Struct" then
		local Fields = {}
		for _, Field in Value.Values do
			Fields[Field.Name] = Draw(Field)
		end

		return Fields
	elseif Node.Type == "TagEnum" then
		local Variant = Pick(Value.Values)
		local Fields = Draw(Variant)
		Fields[Value.Tag] = Variant.Name
		return Fields
	elseif Node.Type == "Array" then
		local Range = Value.Range
		local Count = Length(Range.Min, Range.Max)
		local Elements = table.create(Count)
		--> Only a fixed-length array has a length that holes cannot change: a variable one is sent
		--> with `#`, which a trailing nil shortens.
		local Holes = Range.Min == Range.Max
		for Index = 1, Count do
			local Element = Draw(Value.Of)
			while Element == nil and not Holes do
				Element = Draw(Value.Of)
			end

			Elements[Index] = Element
		end

		return Elements
	elseif Node.Type == "Map" then
		local Map = {}
		for _ = 1, Length(0, SMALL) do
			local Key = Draw(Value.Values[1])
			--> NaN cannot index a table.
			if Key == Key then
				Map[Key] = Draw(Value.Values[2])
			end
		end

		return Map
	end

	error(Generate.Unsupported, 0)
end

--- Whether `Node` contains a map. A map has no order, so it has no single encoding: the same value
--- written twice may list its entries differently.
function Generate.HasMap(Node: Node): boolean
	if Node.Type == "Map" then
		return true
	end

	local Children = if Node.Type == "Array" or Node.Type == "Optional"
		then { Node.Value.Of }
		elseif Node.Type == "Struct" or Node.Type == "TagEnum" then Node.Value.Values
		else {}
	for _, Child in Children do
		if Generate.HasMap(Child) then
			return true
		end
	end

	return false
end

--- Whether `Node` can be drawn at all: no Roblox datatypes, instances or unresolved generics.
function Generate.Supported(Node: Node): boolean
	return (
		pcall(function()
			local function Check(Current: Node)
				if Current.Type == "Primitive" then
					local Name = PrimitiveName(Current)
					if
						not (
							INTEGERS[Name]
							or FLOATS[Name]
							or Name == "boolean"
							or Name == "string"
							or Name == "buffer"
						)
					then
						error(Generate.Unsupported, 0)
					end
				elseif Current.Type == "Generic" or Current.Type == "Tuple" then
					error(Generate.Unsupported, 0)
				end

				local Children = if Current.Type == "Array" or Current.Type == "Optional"
					then { Current.Value.Of }
					elseif
						Current.Type == "Map"
						or Current.Type == "Struct"
						or Current.Type == "TagEnum"
					then Current.Value.Values
					else {}
				for _, Child in Children do
					Check(Child)
				end
			end

			Check(Node)
		end)
	)
end

return Generate
