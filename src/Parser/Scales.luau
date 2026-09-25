--!strict
--!native
--!optimize 2

--- A number's modifiers, written in angle brackets where a vector or a CFrame takes its components:
--- a scale, `u16<0.1>`, and `saturate`, in either order and at most once each -- `u16<0.1, saturate>`.
---
--- `saturate` is an identifier here rather than a keyword, so a field, type or event may still be
--- called that; it means something only inside a number's brackets.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local FixedPoint = require("../Modules/FixedPoint")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type NumberRange = ParserClass.NumberRange

export type Modifiers = { Scale: number?, Saturate: boolean?, Token: Token }

local SATURATE = "saturate"
local DOUBLE_BOUNDS = Settings.Primtives.f64.Bounds :: NumberRange

local Parser = ParserClass.Class

--- Whether `Primitive` is one of the number types -- the integers and the floats -- which are the
--- ones that take these modifiers rather than components.
function Parser.IsNumber(_self: Parser, Primitive: Settings.Primitive): boolean
	return Primitive.Component and Primitive.Bounds ~= nil
end

function Parser.NumberModifiers(self: Parser, Primitive: Settings.Primitive, Type: Token): Modifiers?
	local Open = self:TryConsume("OpenChevrons")
	if not Open then
		return nil
	end

	local Scale: number?
	local Saturate: boolean?

	while true do
		local Token = self:Peek()
		if Token.Type == "Number" then
			self:Consume("Number")

			if Scale then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "Repeated scale")
					:Primary(Token, "A number has one scale")
					:Emit()
			elseif not Primitive.Integer then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "Only an integer takes a scale")
					:Primary(Token, "Remove this scale")
					:Secondary(Type, `"{Type.Value}" is a float, which carries its own fraction`)
					:Note(
						`Scale an integer instead: \`u16<{Token.Value}>\` sends round(v / {Token.Value}) in two bytes.`
					)
					:Emit()
			end

			local Value = tonumber(Token.Value)
			if not Value or Value <= 0 or Value == math.huge then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "A scale must be greater than zero")
					:Primary(Token, `"{Token.Value}" is not a positive step`)
					:Note("The scale is the step between the values the type carries: `u16<0.1>` counts tenths.")
					:Emit()
			end

			Scale = Value :: number
		elseif Token.Type == "Identifier" and Token.Value == SATURATE then
			self:Consume("Identifier")

			if Saturate then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "Repeated saturate")
					:Primary(Token, "Remove this one")
					:Emit()
			end

			Saturate = true
		else
			self:Diagnostic(Error.AnalyzeInvalidModifier, "Unknown number modifier")
				:Primary(Token, `Expected a scale such as 0.1, or "saturate"`)
				:Secondary(Type, `"{Type.Value}" is a number, which takes no components`)
				:Emit()
		end

		local Close = self:TryConsume("CloseChevrons")
		if Close then
			return { Scale = Scale, Saturate = Saturate, Token = Open }
		end

		self:Consume("Comma")

		--> A trailing comma, as every other list in the language accepts.
		Close = self:TryConsume("CloseChevrons")
		if Close then
			return { Scale = Scale, Saturate = Saturate, Token = Open }
		end
	end
end

--- The range `Primitive` covers once scaled: its integer bounds as whole numbers of steps.
function Parser.ScaledBounds(_self: Parser, Primitive: Settings.Primitive, Scale: number): NumberRange
	local Bounds = Primitive.Bounds or DOUBLE_BOUNDS
	return Settings.NumberRange.new(FixedPoint.Decode(Bounds.Min, Scale), FixedPoint.Decode(Bounds.Max, Scale))
end

--- Refuses a bound of a scaled range that falls between two steps. `u16<0.1>(0..0.05)` would put
--- the receiver's check between the values the type can carry.
function Parser.CheckScaledRange(self: Parser, Range: NumberRange, Token: Token, Scale: number)
	for _, Bound in { Range.Min, Range.Max } do
		if not FixedPoint.IsMultiple(Bound, Scale) then
			self:Diagnostic(Error.AnalyzeInvalidRange, "Bound is not a whole number of steps")
				:Primary(Token, `{Bound} is not a multiple of the scale {Scale}`)
				:Note("A scaled number carries whole steps only, so each bound of its range has to be one.")
				:Emit()
		end
	end
end

return Parser
