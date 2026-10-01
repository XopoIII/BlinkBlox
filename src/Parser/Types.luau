--!strict
--!native
--!optimize 2

--- The type grammar: the keyword dispatch in `Type`, and primitives.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local Lexer = require("../Lexer")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type Attributes = ParserClass.Attributes
type AttributesTokens = ParserClass.AttributesTokens
type Declarations = ParserClass.Declarations
type TypeNode = ParserClass.TypeNode
type Declaration = ParserClass.Declaration
type Array = ParserClass.Array
type Optional = ParserClass.Optional
type Set = ParserClass.Set
type Map = ParserClass.Map
type Enum = ParserClass.Enum
type TagEnum = ParserClass.TagEnum
type Struct = ParserClass.Struct
type Primitive = ParserClass.Primitive
type Tuple = ParserClass.Tuple

local KEYWORDS = Grammar.KEYWORDS
local PRIMITIVES = Settings.Primtives

local Parser = ParserClass.Class

local function IsDeclarationTypeSimiliar(A: Declarations, B: Declarations): boolean
	if A == B then
		return true
	end

	if A == "Enum" or B == "Enum" then
		return (A == "TagEnum" and B == "Enum") or (A == "Enum" and B == "TagEnum")
	end

	return false
end

--> The parser method each declaring keyword hands its body to. `type` is here for the fast path
--> alone: a `type` keyword never stands where a type is written.
local function KeywordBody(self: Parser, Value: string, Name: Token, AllowType: boolean): TypeNode?
	if Value == "map" then
		return self:Map(Name)
	elseif Value == "set" then
		return self:Set(Name)
	elseif Value == "enum" then
		return self:Enum(Name)
	elseif Value == "type" and AllowType then
		return self:Primitive(Name)
	elseif Value == "struct" then
		return self:Struct(Name)
	end

	return nil
end

--> Fast path: We know the exact type
local function DeclaredType(self: Parser, Name: Token, Keyword: Token): TypeNode
	local Declaration: TypeNode?

	local Value = Keyword.Value
	if Value ~= "struct" then
		self:Consume("Assign")

		--> Handle reference declarations
		local Type = KEYWORDS[Value].Type
		local Token = self:Peek()

		if Token.Type == "Identifier" then
			local Reference = self:Declaration(Name)
			Declaration = Reference
			if not IsDeclarationTypeSimiliar(Reference.Type, Type :: Declarations) then
				self:Diagnostic(Error.AnalyzeReferenceInvalidType, `Cannot cast "{Reference.Type}" to "{Type}"`)
					:Primary(Token, `Expected a reference to "{Type}", got "{Reference.Type}" instead`)
					:Emit()
			end
		end
	end

	--> Wasn't a reference declaration
	return (Declaration or KeywordBody(self, Value, Name, true)) :: TypeNode
end

--> Slow path: We have to figure out what we're declaring :)
local function InferredType(self: Parser, Name: Token, IsDataField: boolean?): TypeNode
	local Declaration: TypeNode?
	local Peek = self:Peek()
	local Type: Lexer.Types = Peek.Type :: Lexer.Types

	if Type == "Keyword" then
		local Value = Peek.Value
		self:Consume("Keyword")
		Declaration = KeywordBody(self, Value, Name, false)
	elseif Type == "Primitive" then
		Declaration = self:Primitive(Name)
	elseif Type == "Identifier" then
		Declaration = self:Declaration(Name)
	elseif Type == "OpenParentheses" and IsDataField then
		Declaration = self:Tuple(Name)
	end

	if not Declaration then
		self:Diagnostic(Error.ParserUnexpectedToken, `Unexpected token`)
			:Primary(Peek, `Expected one of "Identifier" or "Primitive" or "Keyword", got "{Type}" instead`)
			:Emit()
	end

	return Declaration :: TypeNode
end

--> A primitive's own attributes, ex: vector<u8> and u8(0..00)
local function PrimitiveAttributes(self: Parser, Declaration: Primitive)
	local Primitive = Declaration.Value.Primitive
	local Value = Declaration.Value :: Attributes
	local Tokens = Declaration.Tokens :: AttributesTokens

	if self:IsNumber(Primitive) then
		local Modifiers = self:NumberModifiers(Primitive, Declaration.Tokens.Primitive)
		if Modifiers then
			Value.Scale = Modifiers.Scale
			Value.Saturate = Modifiers.Saturate
			Tokens.Modifiers = Modifiers.Token
		end
	else
		local Components = self:Components(Primitive)
		if Components then
			Value.Components = Components
		end
	end

	local Range = self:Range(Primitive, Value.Scale)
	if Range then
		if not Primitive.AllowsRange then
			local PrimitiveToken = Declaration.Tokens.Primitive
			self:Diagnostic(Error.AnalyzeInvalidRangeType, `Type doesn't accept a range`)
				:Primary(Range.Token, "Remove this range")
				:Secondary(PrimitiveToken, `"{PrimitiveToken.Value}" has no bounds to constrain`)
				:Emit()
		end

		Value.Range = Range.Range
		Tokens.Range = Range.Token
	end

	if Value.Scale and not Primitive.Integer then
		self:Quantize(Declaration, Value.Range)
	end
end

--> ex: u8?
--> A function of the module and not a closure inside Parser.Type: that one was made anew for every
--> type parsed, with the declaration it wraps boxed as its upvalue.
local function WrapInOptional(self: Parser, Name: Token, Declaration: TypeNode): TypeNode
	local Optional = self:Optional()
	if not Optional then
		return Declaration
	end

	if Declaration.Type == "Primitive" then
		local Node = Declaration :: Primitive
		if not Node.Value.Primitive.AllowsOptional then
			self:Diagnostic(Error.AnalyzeInvalidOptionalType, `Type cannot be optional`)
				:Primary(Optional, "Remove this optional")
				:Secondary(Node.Tokens.Primitive, `"{Node.Tokens.Primitive.Value}" has no way to encode absence`)
				:Emit()
		end
	end

	return {
		Type = "Optional",
		Name = Name.Value,
		Value = { Of = Declaration },
		Tokens = {},
	} :: Optional
end

function Parser.Type(self: Parser, Name: Token, Keyword: Token?, IsDataField: boolean?): TypeNode
	local Declaration: TypeNode = if Keyword
		then DeclaredType(self, Name, Keyword)
		else InferredType(self, Name, IsDataField)

	--> Set type attributes
	if Declaration.Type == "Primitive" then
		PrimitiveAttributes(self, Declaration :: Primitive)
	end

	Declaration = WrapInOptional(self, Name, Declaration)

	-- ex: u8[][][]
	while true do
		local Array = self:Array()
		if Array then
			Declaration = {
				Type = "Array",
				Name = Name.Value,
				Value = {
					Of = Declaration,
					Range = Array.Range,
				},
				Tokens = {
					Range = Array.Token,
				},
			} :: Array
		end

		Declaration = WrapInOptional(self, Name, Declaration)

		if Array == nil then
			break
		end
	end

	return Declaration
end

function Parser.Primitive(self: Parser, Name: Token): Primitive
	local Token = self:Consume("Primitive")

	local Class: string?
	local Value = Token.Value
	local Primitive = PRIMITIVES[Value]

	if Value == "Instance" then
		local ClassToken = self:TryConsume("Class")
		Class = if ClassToken then string.sub(ClassToken.Value, 2, #ClassToken.Value - 1) else "Instance"
	elseif Value == "Enum" then
		--> Which enum decides how a Value reads back, so there is no default to fall back on.
		local ClassToken = self:TryConsume("Class")
		if not ClassToken then
			error(
				self:Diagnostic(Error.AnalyzeInvalidEnumType, `Enum needs the name of a Roblox enum`)
					:Primary(Token, `Write the enum's name after it, as in Enum(Material)`)
					:Emit()
			)
		end

		Class = string.sub(ClassToken.Value, 2, #ClassToken.Value - 1)
	end

	return {
		Type = "Primitive",
		Name = Name.Value,
		Value = {
			Class = Class,
			Primitive = Primitive,
		},
		Tokens = {
			Primitive = Token,
		},
	}
end

return Parser
