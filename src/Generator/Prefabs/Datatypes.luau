--!strict
--!native
--!optimize 2

--- The Roblox datatypes added for interface and effects work: Vector2, UDim, UDim2, NumberRange,
--- ColorSequence, TweenInfo, and a Roblox enum's items as `Enum(Name)`. Sizes are in Settings.
local Common = require("./Common")

type Block = Common.Block
type Generate = Common.Generate

local Types = Common.Types
local Required = Common.Required
local Primitives = Common.Primitives
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab

--> Vector2
do
	Types.Vector2 = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("VectorX", Block)
			Types.f32.Read("VectorY", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector2.new(VectorX, VectorY)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Vector = {Value}`)
			Types.f32.Write("Vector.X", Block)
			Types.f32.Write("Vector.Y", Block)
		end,
	}

	Primitives.Vector2 = {
		Type = "Vector2",
		Generate = GeneratePrimitivePrefab("Vector2", Types.Vector2),
	}
end

--> UDim and UDim2: a scale travels as f32, an offset -- whole pixels -- as i32.
do
	Types.UDim = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("Scale", Block)
			Types.i32.Read("Offset", Block)
			Block:Line(`{Block:Declare(Variable)} = UDim.new(Scale, Offset)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Dimension = {Value}`)
			Types.f32.Write("Dimension.Scale", Block)
			Types.i32.Write("Dimension.Offset", Block)
		end,
	}

	Types.UDim2 = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("ScaleX", Block)
			Types.i32.Read("OffsetX", Block)
			Types.f32.Read("ScaleY", Block)
			Types.i32.Read("OffsetY", Block)
			Block:Line(`{Block:Declare(Variable)} = UDim2.new(ScaleX, OffsetX, ScaleY, OffsetY)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Dimensions = {Value}`)
			Types.f32.Write("Dimensions.X.Scale", Block)
			Types.i32.Write("Dimensions.X.Offset", Block)
			Types.f32.Write("Dimensions.Y.Scale", Block)
			Types.i32.Write("Dimensions.Y.Offset", Block)
		end,
	}

	Primitives.UDim = {
		Type = "UDim",
		Generate = GeneratePrimitivePrefab("UDim", Types.UDim),
	}

	Primitives.UDim2 = {
		Type = "UDim2",
		Generate = GeneratePrimitivePrefab("UDim2", Types.UDim2),
	}
end

--> NumberRange
do
	Types.NumberRange = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("RangeMin", Block)
			Types.f32.Read("RangeMax", Block)
			--> NumberRange.new throws on a Max below Min; NaN on either side fails this too.
			Block:Line(
				`if not (RangeMax >= RangeMin) then error(\`Expected a NumberRange with Max at least Min, got \{RangeMin} and \{RangeMax} instead.\`) end`
			)
			Block:Line(`{Block:Declare(Variable)} = NumberRange.new(RangeMin, RangeMax)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Range = {Value}`)
			Types.f32.Write("Range.Min", Block)
			Types.f32.Write("Range.Max", Block)
		end,
	}

	Primitives.NumberRange = {
		Type = "NumberRange",
		Generate = GeneratePrimitivePrefab("NumberRange", Types.NumberRange),
	}
end

--> ColorSequence: variable length, so read and written by the runtime helpers in Templates/Datatypes.
do
	Types.ColorSequence = {
		Read = function(Variable: string, Block: Block)
			Required.ColorSequences = true
			Block:Line(`{Block:Declare(Variable)} = ReadColorSequence()`)
		end,
		Write = function(Value: string, Block: Block)
			Required.ColorSequences = true
			Block:Line(`WriteColorSequence({Value})`)
		end,
	}

	Primitives.ColorSequence = {
		Type = "ColorSequence",
		Generate = GeneratePrimitivePrefab("ColorSequence", Types.ColorSequence),
	}
end

--> TweenInfo. Its two enums go by Value, as `Enum(Name)` does, and each fits a byte.
do
	Types.TweenInfo = {
		Read = function(Variable: string, Block: Block)
			Required.EnumItems = true
			Types.f32.Read("TweenTime", Block)
			Types.u8.Read("TweenStyle", Block)
			Types.u8.Read("TweenDirection", Block)
			Types.i32.Read("TweenRepeats", Block)
			Types.u8.Read("TweenReverses", Block)
			Types.f32.Read("TweenDelay", Block)
			Block:Line(
				`{Block:Declare(Variable)} = TweenInfo.new(TweenTime, EnumItemOf(Enum.EasingStyle, TweenStyle) :: Enum.EasingStyle, EnumItemOf(Enum.EasingDirection, TweenDirection) :: Enum.EasingDirection, TweenRepeats, TweenReverses ~= 0, TweenDelay)`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Tween = {Value}`)
			Types.f32.Write("Tween.Time", Block)
			Types.u8.Write("Tween.EasingStyle.Value", Block)
			Types.u8.Write("Tween.EasingDirection.Value", Block)
			Types.i32.Write("Tween.RepeatCount", Block)
			Types.u8.Write("if Tween.Reverses then 1 else 0", Block)
			Types.f32.Write("Tween.DelayTime", Block)
		end,
	}

	Primitives.TweenInfo = {
		Type = "TweenInfo",
		Generate = GeneratePrimitivePrefab("TweenInfo", Types.TweenInfo),
	}
end

--> Enum(Name): an item of one Roblox enum, as its Value in a u16.
do
	local GenerateEnum: Generate = function(Declaration, Variable, Read, Write, WriteValidations)
		local Target = Variable or "Value"
		local EnumType = `Enum.{Declaration.Value.Class}`
		Required.EnumItems = true

		if WriteValidations then
			Write:Line(
				`if typeof({Target}) ~= "EnumItem" or {Target}.EnumType ~= {EnumType} then error(\`Expected {Target} to be an item of {EnumType}, got \{{Target}} instead.\`) end`
			)
		end

		--> Checked whatever WriteValidations says, as a length is: a Value past the u16 would wrap and
		--> decode as another item.
		Write:Line(`local EnumValue = {Target}.Value`)
		Write:Line(
			`if not (EnumValue >= 0 and EnumValue <= 65535) then error(\`Expected {Target} to have a Value from 0 to 65535, got \{EnumValue} instead.\`) end`
		)
		Types.u16.Write("EnumValue", Write)

		Types.u16.Read("EnumValue", Read)
		Read:Line(`{Read:Declare(Target)} = EnumItemOf({EnumType}, EnumValue) :: {EnumType}`)
	end

	Primitives.Enum = {
		Type = function(Declaration)
			return `Enum.{Declaration.Value.Class}`
		end,
		Generate = GenerateEnum,
	}
end

return {}
