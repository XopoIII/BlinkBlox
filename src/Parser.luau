--!strict
--!native
--!optimize 2

local Analysis = require("./Analysis")
local AttributeParser = require("./Modules/Attributes")
local Error = require("./Modules/Error")
local Grammar = require("./Modules/Grammar")
local Lexer = require("./Lexer")
local OptionsParser = require("./Modules/Options")
local PathParser = require("./Modules/Path")
local Size = require("./Modules/Size")
local SourceReader = require("./Modules/Source")
local Table = require("./Modules/Table")

local Settings = require("./Settings")

---- Globals ----

--> Shared with Settings and the generator so all three mean the same table, not Roblox's userdata.
export type NumberRange = Settings.NumberRange
local NumberRange = {
	new = function(Min: number, Max: number?): NumberRange
		return {
			Min = Min,
			Max = Max or Min,
		}
	end,
}

---- Types ----

type Token = Lexer.Token

type Type = "Type" | "Event" | "Scope"
type Node<Type, Body, Tokens> = {
	Type: Type,
	Name: string,
	Value: Body,
	Tokens: Tokens,
}

type Generics = {
	Span: Error.Span,
	List: { string },
	Keys: { [string]: { Generic } },
}

type Reference = {
	Name: Token,
	To: TypeNode,
}

export type Scope = {
	Name: Token,
	Parent: Scope?,
	Symbols: {
		Types: { [string]: Reference },
		Scopes: { [string]: Scope },
	},
}

type EventOption = Grammar.EventOption

type Attributes = {
	Scope: Scope?,
	Range: NumberRange?,
	Export: boolean?,
	Generics: Generics?,
	Parameters: { TypeNode }?,
	Components: { string }?,
}

type AttributesTokens = {
	Range: Token?,
}

export type Options = Grammar.Options

export type Body = Node<"Body", {
	Options: Options,
	Symbols: { [string]: true },
	Declarations: { Declaration },
}, {}>

type Declarations = Grammar.Declarations
export type TypeNode = | Map | Set | Enum | TagEnum | Tuple | Struct | Primitive | Generic | Array | Optional

export type Declaration = Node<Declarations, {
	[any]: any,
}, {
	[any]: any,
}>

export type Array = Node<"Array", {
	Of: TypeNode,
} & Attributes, AttributesTokens>

export type Optional = Node<"Optional", {
	Of: TypeNode,
} & Attributes, AttributesTokens>

export type Set = Node<"Set", {
	Values: { string },
} & Attributes, AttributesTokens>

export type Map = Node<"Map", {
	Values: { TypeNode },
} & Attributes, AttributesTokens>

export type Enum = Node<"Enum", {
	Values: { string },
} & Attributes, AttributesTokens>

export type TagEnum = Node<"TagEnum", {
	Tag: string,
	Values: { Struct },
} & Attributes, AttributesTokens>

export type Struct = Node<"Struct", {
	Values: { TypeNode },
} & Attributes, AttributesTokens>

export type Primitive = Node<"Primitive", {
	Class: string?,
	Primitive: Settings.Primitive,
} & Attributes, {
	Primitive: Token,
} & AttributesTokens>

export type Generic = Node<"Generic", {
	Generic: string,
} & Attributes, AttributesTokens>

--- `Names` is sparse and indexed alongside `Values`: an element may be named, as in
--- `(chefId: f64, dish: string)`, and one that is not has no entry. Naming is for the reader and for
--- the generated signature only -- a type pack is serialised positionally with no field tags, so it
--- never reaches the wire.
export type Tuple = Node<"Tuple", {
	Values: { TypeNode },
	Names: { [number]: string },
} & Attributes, AttributesTokens>

--- The listening API generated for an event. Named so `Parser.Event` can annotate its local without
--- restating the union (it used to reach for it through `index<index<Event, "Value">, "Call">`, which
--- this Luau version does not parse).
export type EventCall = "SingleSync" | "SingleAsync" | "ManySync" | "ManyAsync" | "Polling"

export type Event = Node<
	"Event",
	{
		From: "Client" | "Server",
		--> OrderedUnreliable is Unreliable plus a sequence number: delivery is still not guaranteed,
		--> but a packet arriving after a newer one is discarded rather than applied out of order.
		Type: "Reliable" | "Unreliable" | "OrderedUnreliable",
		Call: EventCall,
		Data: (TypeNode | Tuple)?,
		--> Sustained events per second accepted from one player, and the bucket capacity that lets a
		--> burst through. Absent means unlimited -- see the generator's rate limiting.
		Rate: number?,
		Burst: number?,
	},
	{
		Identifier: Token,
	}
>

export type Function = Node<
	"Function",
	{
		--> Which side INVOKES. The other side listens, exactly as with an event's From -- except that a
		--> function's default is Client, since that was the only direction the language used to have.
		From: "Client" | "Server",
		Yield: "Future" | "Promise" | "Coroutine",
		Data: (TypeNode | Tuple)?,
		Return: (TypeNode | Tuple)?,
		Rate: number?,
		Burst: number?,
	},
	{
		Identifier: Token,
	}
>

export type ScopeNode = Node<
	"Scope",
	{
		Scope: Scope,
		Values: { Declaration },
		--- Set when the scope came from an `import` rather than a `scope` block in this file. Its
		--- declarations carry spans into the IMPORTED source, so any diagnostic about them has to be
		--- raised by the parse of that file -- pointing at those offsets in this one underlines
		--- whatever text happens to sit there.
		Imported: boolean?,
	},
	{}
>

---- Settings ----

--> The language's shape lives in Modules/Grammar; only its use lives here.
type Bucket = Grammar.Bucket

local EVENT = Grammar.EVENT
local FUNCTION = Grammar.FUNCTION
local BUCKETS = Grammar.BUCKETS
local KEYWORDS = Grammar.KEYWORDS
local RESERVED = Grammar.RESERVED
local LUAU_KEYWORDS = Grammar.LUAU_KEYWORDS
local GENERICS_TYPES = Grammar.GENERICS_TYPES

local PRIMITIVES = Settings.Primtives
local ARRAY_BOUNDS = NumberRange.new(0, (PRIMITIVES.u16.Bounds :: NumberRange).Max)
local DOUBLE_BOUNDS = PRIMITIVES.f64.Bounds :: NumberRange

---- Main ----

local Parser = {}
Parser.__index = Parser

export type Parser = typeof(setmetatable(
	{} :: {
		Source: string,

		File: string?,
		Directory: string,

		Lexer: Lexer.Lexer,
		LookAhead: Token?,

		Scope: Scope,
		Symbols: { [string]: true },
		Generics: Generics?,

		--> Files whose parse has STARTED and not yet finished, shared by every parser in one
		--> compilation. See Parser.Import.
		Importing: { [string]: true },

		--> The name being declared right now, so a reference to it from inside its own body can be
		--> told apart from a reference to something that does not exist. See Parser.Declaration.
		Declaring: string?,
		Attributes: AttributeParser.State, --> The profile, and what it excludes. See Modules/Attributes.
	},
	Parser
))

function Parser.new(
	Directory: string?,
	File: string?,
	Importing: { [string]: true }?,
	Attributes: AttributeParser.State?
): Parser
	return setmetatable({
		Source = "",
		File = File,
		Directory = Directory or "./",

		Lexer = Lexer.new("Parsing"),
		Symbols = {},
		Scope = nil :: any,

		--> Inherited when one parser spawns another for an import, fresh for a top-level parse.
		Importing = Importing or {},
		Attributes = Attributes or AttributeParser.new(),
	}, Parser)
end

---- Utility Functions ----

local function IsInteger(Number: number): boolean
	return (Number // 1) == Number
end

local function IsDeclarationTypeSimiliar(A: Declarations, B: Declarations): boolean
	if A == B then
		return true
	end

	if A == "Enum" or B == "Enum" then
		return (A == "TagEnum" and B == "Enum") or (A == "Enum" and B == "TagEnum")
	end

	return false
end

---- Lexer Functions -----

function Parser.Peek(self: Parser): Token
	local Token = self.LookAhead
	if not Token then
		error(
			Error.new(Error.ParserUnexpectedEndOfFile, self.Source, "Unexpected end of file", self.File)
				:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
				:Emit()
		)
	end

	return Token
end

function Parser.Consume(self: Parser, Type: Lexer.Types): Token
	local Token = self.LookAhead
	if not Token then
		Error.new(Error.ParserUnexpectedEndOfFile, self.Source, "Unexpected end of file", self.File)
			:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
			:Emit()

		--> Above already errors
		error("Unexpected end of file")
	end

	if Token.Type ~= Type then
		Error.new(Error.ParserUnexpectedToken, self.Source, `Unexpected token`, self.File)
			:Primary(Token, `Expected "{Type}", found "{Token.Type}"`)
			:Emit()
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

function Parser.TryConsume(self: Parser, Type: Lexer.Types): Token?
	local Token = self.LookAhead
	if not Token then
		return
	end

	if Token.Type ~= Type then
		return
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

function Parser.ConsumeAny(self: Parser, ...: Lexer.Types): Token
	local Types = { ... }
	for _, Type: Lexer.Types in Types do
		local Token = self:TryConsume(Type)
		if Token then
			return Token
		end
	end

	local Token = self:Peek()
	error(
		Error.new(Error.ParserUnexpectedToken, self.Source, `Unexpected token`, self.File)
			:Primary(Token, `Expected one of "{table.concat(Types, `", "`)}", found "{Token.Type}"`)
			:Emit()
	)
end

function Parser.ConsumeAll(self: Parser, ...: Lexer.Types): ...Token
	local Tokens = {}
	for _, Type: Lexer.Types in { ... } do
		table.insert(Tokens, self:Consume(Type))
	end

	return table.unpack(Tokens)
end

--> Used to consume identifiers without getting "Expected Identifier, got Keyword" errors
--> Boolean flag here is code smell but this codebase is already EOL and will soonish be replaced by the rewrite

function Parser.ConsumeText(self: Parser, ConsumePrimitives: boolean?, ConsumeStrings: boolean?): Token
	--> Get text token
	local Token: Token

	if ConsumeStrings and self:Peek().Type == "String" then
		Token = self:Consume("String")
	else
		if ConsumePrimitives then
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier", "Primitive")
		else
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier")
		end
	end

	--> Convert token to identifier token
	return {
		End = Token.End,
		Start = Token.Start,
		Type = "Identifier",
		Value = Token.Value,
	}
end

---- Utility Parsing Functions ----

function Parser.Reference(self: Parser, Bucket: Bucket, Identifier: string): (Scope | Reference)?
	local Path = string.split(Identifier, ".")
	local Scope: Scope? = self.Scope

	local Offset = 1
	local Length = #Path
	local Result

	while Scope do
		local Index = Path[Offset]
		if not Index then
			break
		end

		local Symbols = Scope.Symbols
		local Symbol = if Offset == Length then Symbols[Bucket][Index] else Symbols.Scopes[Index]

		--> Nothing found in the current scope search upwards
		if Symbol == nil then
			Scope = Scope.Parent
			continue
		end

		--> We found a scope, start searching in it
		if Symbol and Offset < Length then
			Offset += 1
			Scope = Symbol :: any
			continue
		end

		--> Found the reference
		Result = Symbol
		break
	end

	return Result
end

function Parser.SetReference(self: Parser, Bucket: Bucket, Identifier: Token, Declaration: Declaration)
	local Name = Identifier.Value

	if RESERVED[Name] then
		Error.new(Error.AnalyzeReservedIdentifier, self.Source, `Reserved identifier`, self.File)
			:Primary(Identifier, `"{Name}" is reserved and cannot be used as an identifier.`)
			:Emit()
	end

	self.Symbols[Name] = true
	self.Scope.Symbols[Bucket][Name] = {
		To = Declaration,
		Name = Identifier,
	} :: Reference
end

function Parser.GetGenerics(self: Parser): Generics?
	if self.Generics then
		return self.Generics
	end

	local OpenChevrons = self:TryConsume("OpenChevrons")
	if not OpenChevrons then
		return
	end

	--> Parse generics
	local Generics: Generics = {
		Keys = {},
		List = {},
		Span = {
			Start = OpenChevrons.Start,
			End = OpenChevrons.End + 1,
		},
	}

	while true do
		if self:TryConsume("CloseChevrons") then
			break
		end

		local Token = self:ConsumeText()

		Generics.Span.End = Token.End
		Generics.Keys[Token.Value] = {}
		table.insert(Generics.List, Token.Value)

		if self:Peek().Type ~= "CloseChevrons" then
			self:Consume("Comma")
		end
	end

	self.Generics = Generics
	return Generics
end

function Parser.NumberRange(self: Parser, Token: Lexer.Token, Bounds: NumberRange, Integer: boolean?): NumberRange
	local Value = Token.Value
	Value = string.sub(Value, 2, #Value - 1)

	local function ParseRange(): NumberRange
		local Single = tonumber(string.match(Value, `^(%-?%d*%.?%d+)$`))
		if Single then
			return NumberRange.new(Single)
		end

		local LowerBounds = tonumber(string.match(Value, `^(%-?%d*%.?%d+)%.%.$`))
		if LowerBounds then
			return NumberRange.new(LowerBounds, Bounds.Max)
		end

		local UpperBounds = tonumber(string.match(Value, `^%.%.(%-?%d*%.?%d+)$`))
		if UpperBounds then
			return NumberRange.new(Bounds.Min, UpperBounds)
		end

		local Lower, Upper = string.match(Value, `^(%-?%d*%.?%d+)%.%.(%-?%d*%.?%d+)$`)
		local Minimum, Maximum = tonumber(Lower), tonumber(Upper)
		if Minimum and Maximum then
			return NumberRange.new(Minimum, Maximum)
		end

		Error.new(Error.AnalyzeInvalidRange, self.Source, "Malformed range", self.File)
			:Primary(Token, "Unable to parse range")
			:Emit()

		error("never")
	end

	local Range = ParseRange()

	--> check int
	if Integer and (IsInteger(Range.Min) == false or IsInteger(Range.Max) == false) then
		Error.new(Error.AnalyzeInvalidRange, self.Source, "Expected an integer", self.File)
			:Primary(Token, "Expected an integer")
			:Emit()

		error("never")
	end

	--> check bounds
	if Range.Min < Bounds.Min or Range.Max > Bounds.Max then
		Error.new(Error.AnalyzeInvalidRange, self.Source, "Range outside bounds", self.File)
			:Primary(Token, `Expected a range within ({Bounds.Min}..{Bounds.Max})`)
			:Emit()

		error("never")
	end

	return Range
end

function Parser.Range(self: Parser, Primitive: Settings.Primitive): { Range: NumberRange, Token: Token }?
	local Token = self:TryConsume("Range")
	if Token == nil then
		return
	end

	local ParsedRange = self:NumberRange(Token, Primitive.Bounds or DOUBLE_BOUNDS, Primitive.Integer)

	return {
		Range = ParsedRange,
		Token = Token,
	}
end

function Parser.Array(self: Parser): { Range: NumberRange, Token: Token }?
	local Token = self:TryConsume("Array")
	if not Token then
		return
	end

	local Value = Token.Value

	--> Empty bounds
	if Value == "[]" then
		return {
			Range = ARRAY_BOUNDS,
			Token = Token,
		}
	end

	--> Parse range
	local ParsedRange = self:NumberRange(Token, ARRAY_BOUNDS, true)

	return {
		Range = ParsedRange,
		Token = Token,
	}
end

function Parser.Components(self: Parser, Primitive: Settings.Primitive): { string }?
	local OpenChevrons = self:TryConsume("OpenChevrons")
	if not OpenChevrons then
		return
	end

	if Primitive.AllowedComponents == 0 then
		error(
			Error.new(Error.AnalyzeInvalidComponents, self.Source, `Type doesn't accept components`, self.File)
				:Primary(OpenChevrons, `Remove component here`)
				:Emit()
		)
	end

	local Components = {}
	local Primitives = {}
	local Closed = false

	for _ = 1, Primitive.AllowedComponents do
		table.insert(Primitives, self:Consume("Primitive"))
		if self:TryConsume("CloseChevrons") then
			Closed = true
			break
		end

		self:Consume("Comma")
	end

	if not Closed then
		local Extra = self:Peek()
		error(
			Error.new(Error.AnalyzeInvalidComponents, self.Source, `Too many components`, self.File)
				:Primary(Extra, `Expected at most {Primitive.AllowedComponents} component(s)`)
				:Emit()
		)
	end

	for _, Token in Primitives do
		local Component = Token.Value
		local ComponentPrimitive = PRIMITIVES[Component]

		if not ComponentPrimitive then
			error(
				Error.new(Error.AnalyzeInvalidComponents, self.Source, `Unknown primitive used as component`, self.File)
					:Primary(Token, `"{Component}" is invalid`)
					:Emit()
			)
		end

		if not ComponentPrimitive.Component then
			error(
				Error.new(Error.AnalyzeInvalidComponents, self.Source, `Invalid primitive used as component`, self.File)
					:Primary(Token, `"{Component}" cannot be used as a component`)
					:Emit()
			)
		end

		table.insert(Components, Component)
	end

	return Components
end

function Parser.Optional(self: Parser): Token?
	return self:TryConsume("Optional")
end

--> Here's the logic:
--> When a generic is used it will reuse the same table under the hood
--> When replacing the generic the table's contents are changed to what it is being replaced with
--> Issues start to arise when you have another generic type that references a generic ex:
--> map GenericMap<K, V> = {[K]: V}
--> struct GenericStruct<T> { Map: GenericMap<string, T> }
--> struct MergeStruct { ..GenericStruct<u8> }
--> GenericStruct is merged just fine but GenericMap loses the reference to the table for `T` somewhere along the process (likely at the deep clone stage)

function Parser.ReplaceGenerics(self: Parser, Of: TypeNode): TypeNode
	local Clone = Table.DeepClone(Of) :: Struct
	local Generics = Clone.Value.Generics :: Generics
	local Replacements: { [string]: TypeNode } = {}

	Clone.Value.Generics = nil

	--> Parse generics input
	self:Consume("OpenChevrons")

	for Index = 1, #Generics.List do
		local Key = Generics.List[Index]
		local List = Generics.Keys[Key]

		local Token = self:Peek()
		local Declaration = self:Type(Token)
		Replacements[Key] = Declaration

		for _, Generic in List do
			local Replacement = Table.DeepClone(Declaration)

			Generic.Type = Replacement.Type
			Generic.Value = Replacement.Value
			Generic.Tokens = Replacement.Tokens
		end

		if Index < #Generics.List then
			self:Consume("Comma")
		end
	end

	self:Consume("CloseChevrons")

	--> hack to find lost references
	local function Traverse(Type: TypeNode)
		if Type.Type == "Array" or Type.Type == "Optional" then
			Traverse(Type.Value.Of)
		elseif Type.Type == "TagEnum" or Type.Type == "Struct" or Type.Type == "Map" then
			for _, Nested in Type.Value.Values :: { any } do
				Traverse(Nested)
			end
		elseif Type.Type == "Generic" then
			local Key = Type.Value.Generic
			local Declaration = Replacements[Key]
			if Declaration == nil then
				return
			end

			local Replacement = Table.DeepClone(Declaration)

			Type.Type = Replacement.Type
			Type.Value = Replacement.Value
			Type.Tokens = Replacement.Tokens
		end
	end

	Traverse(Clone)

	return Clone
end

---- Top-Level Parsing Functions ----

function Parser.Parse(self: Parser, Source: string, Scope: Scope?): Body
	--> Set state
	self.Scope = Scope or { Name = { Value = "", Start = 0, End = 0 } :: any, Symbols = { Types = {}, Scopes = {} } }
	self.Source = Source
	table.clear(self.Symbols)

	--> Start the lexer
	self.Lexer:Initialize(Source)
	self.LookAhead = self.Lexer:GetNextToken()

	--> Cast because Luau will not match a metatable-backed type against a structural one, however
	--> exactly it fits. Modules/Options and Modules/Attributes want members this has; naming them in
	--> Reader types there rather than requiring Parser back is what keeps them out of a require cycle.
	local Options = OptionsParser.Parse(self :: any)
	local Declarations = self:Declarations()

	Options.SyncValidation = if Options.SyncValidation ~= nil then Options.SyncValidation else true

	Analysis.Run(self.Source, self.File, Declarations, Options)

	return {
		Type = "Body",
		Name = Scope and Scope.Name.Value or "Body",
		Value = {
			Symbols = table.clone(self.Symbols),
			Options = Options,
			Declarations = Declarations,
		},
		Tokens = {},
	}
end

function Parser.Import(self: Parser): ScopeNode
	self:Consume("Import")

	local Path = self:Consume("String")
	local ImportPath = Path.Value
	local ImportSource, ImportDirectory, Resolved = SourceReader.Read(ImportPath, self.Directory)

	if not ImportSource then
		error(
			Error.new(Error.AnalyzeUnknownImport, self.Source, `Unknown require`, self.File)
				:Primary(Path, `Unknown require: "{ImportPath}"`)
				:Emit()
		)
	end

	local Name: string
	local Token = Path

	if self:TryConsume("As") then
		--> Use user provided namespace identifier
		Token = self:ConsumeText()
		Name = Token.Value
	elseif task ~= nil then
		--> ROBLOX
		local Indices = string.split(ImportPath, ".")
		Name = Indices[#Indices]
	else
		if PathParser.PathType(ImportPath) == "absolute" and string.sub(ImportPath, 1, 2) ~= "./" then
			ImportPath = `./{ImportPath}`
		end

		--> Use file name as namespace identifier
		local Filename = PathParser.Filename(ImportPath)
		assert(Filename, "Unable to parse file path for filename!")

		Name = Filename
		Token.Value = Filename
	end

	local Existing = self:Reference("Scopes", Name)
	if Existing then
		Error.new(Error.AnalyzeDuplicateDeclaration, self.Source, `Duplicate declaration: "{Name}"`, self.File)
			:Secondary(Existing.Name, "Previously declared here")
			:Primary(Token, "Duplicate declared here")
			:Emit()
	end

	local Parent = self.Scope
	local Scope: Scope = {
		Name = Token,
		Symbols = {
			Types = {},
			Scopes = {},
		},
	}

	--> Two files that import each other used to recurse until the Luau stack gave out, which
	--> reports a stack overflow from somewhere deep in the lexer and names neither file. There is no
	--> memoisation here -- an import is re-parsed every time it is reached -- so the only thing that
	--> ends the recursion is noticing it.
	-->
	--> Keyed on the file, and cleared once the parse RETURNS rather than left set, because a diamond
	--> (two files importing a third) reaches the same file twice by two routes and is perfectly
	--> legal. Only a file reached while it is still being parsed is a cycle.
	local Key = PathParser.Normalise(Resolved or ImportPath)
	if self.Importing[Key] then
		error(
			Error.new(Error.AnalyzeCyclicImport, self.Source, `Cyclic import`, self.File)
				:Primary(Path, `"{ImportPath}" is already being imported, so this would never finish`)
				:Emit()
		)
	end

	local AST: Body
	local ImportParser = Parser.new(ImportDirectory, ImportPath, self.Importing, self.Attributes)

	self.Importing[Key] = true
	local Success, ErrorText = pcall(function()
		AST = ImportParser:Parse(ImportSource, Scope)
	end)
	self.Importing[Key] = nil

	--> Level 0: the text is already a rendered diagnostic, and re-raising it at the default level
	--> prepends this file and line every time it passes through an import. A cycle three files deep
	--> arrived with three "Parser:905:" prefixes in front of the frame the reader actually wants.
	if not Success then
		error(ErrorText, 0)
	end

	Scope.Parent = Parent
	self.Symbols[Name] = true
	Parent.Symbols.Scopes[Name] = Scope

	return {
		Type = "Scope",
		Name = Name,
		Value = {
			Scope = Scope,
			Values = AST.Value.Declarations,
			Imported = true,
		},
		Tokens = {},
	}
end

function Parser.Declarations(self: Parser): { Declaration }
	local Declarations = {}
	while true do
		if self:TryConsume("EndOfFile") then
			break
		end

		if self.Scope and self:TryConsume("CloseBraces") then
			break
		end

		local Previous = AttributeParser.Open(self :: any)
		local LookAhead = self:Peek()
		if LookAhead.Type == "Import" then
			AttributeParser.Close(self :: any, Previous, self:Import(), Declarations)
			continue
		end

		--> Is standalone/exported?
		local Export: Token?
		if LookAhead.Type == "Keyword" and LookAhead.Value == "export" then
			Export = self:Consume("Keyword")
		end

		local Keyword = self:Consume("Keyword")
		local Name = self:ConsumeText()
		local Declaration: Declaration

		if Keyword.Value == "option" then
			Error.new(Error.AnalyzeOptionAfterStart, self.Source, "Option set after start of file", self.File)
				:Primary(Keyword, "Move to the start of the file")
				:Emit()
		end

		--> Prevent duplicates
		local KeywordSettings = KEYWORDS[Keyword.Value]
		local Type = KeywordSettings.Class

		local Bucket: Bucket = BUCKETS[Type]
		local Existing = self:Reference(Bucket, Name.Value)

		if Existing then
			Error.new(Error.AnalyzeDuplicateDeclaration, self.Source, `Duplicate declaration`, self.File)
				:Secondary(Existing.Name, "Previously declared here")
				:Primary(Name, "Duplicate declared here")
				:Emit()
		end

		--> Generics
		local Generics: Generics?
		if KeywordSettings.Generics then
			Generics = self:GetGenerics()
		end

		--> Parse declaration
		-->
		--> Saved and restored rather than cleared: a namespace parses its members while its own
		--> declaration is still open, and clearing would lose the outer name on the way back out.
		local Enclosing = self.Declaring
		self.Declaring = Name.Value

		if Type == "Type" then
			local Node = self:Type(Name, Keyword)
			local Value: Attributes = Node.Value
			Value.Scope = self.Scope
			Declaration = Node
		elseif Type == "Event" then
			Declaration = self:Event(Name)
		elseif Type == "Function" then
			Declaration = self:Function(Name)
		elseif Type == "Scope" then
			Declaration = self:Namespace(Name)
		end

		self.Declaring = Enclosing

		AttributeParser.Close(self :: any, Previous, Declaration, Declarations)

		if Export then
			--> Prevent non exportable types from being exported
			if not KeywordSettings.Exportable then
				Error.new(
					Error.AnalyzeInvalidExport,
					self.Source,
					`Declaration of type "{Keyword.Value}" is not exportable`,
					self.File
				)
					:Primary(Export, `Remove export here`)
					:Emit()
			--> Prevent types with generics from being exported
			elseif Generics then
				Error.new(Error.AnalyzeInvalidExport, self.Source, `Generic types can't be exported`, self.File)
					:Primary(Export, `Remove export here`)
					:Emit()
			end

			--> An exported type gets a standalone Read/Write pair. Instances and unknowns are never
			--> encoded into the buffer -- they are appended to a table that travels as the remote's
			--> second argument -- and an export has no remote and no such table, so the value would
			--> be silently lost on write and read back as nil. Nothing checked this before.
			local Measured = Size.Sealed(Declaration :: any)
			if Measured.Refs > 0 then
				Error.new(
					Error.AnalyzeInvalidExport,
					self.Source,
					`Types containing an Instance or unknown can't be exported`,
					self.File
				)
					:Primary(Export, "Remove export here")
					:Secondary(Name, `"{Name.Value}" carries a value that travels beside the buffer`)
					:Note("An exported Read/Write pair only has the buffer, so such a value cannot survive it.")
					:Emit()
			end

			Declaration.Value.Export = true
		end

		if Generics then
			if Declaration.Type == "Enum" then
				Error.new(Error.AnalyzeInvalidGenerics, self.Source, `Unit enums don't support generics`, self.File)
					:Primary(Generics.Span, "Remove generics")
					:Emit()
			end

			self.Generics = nil
			Declaration.Value.Generics = Generics
		end

		if Type ~= "Scope" then
			self:SetReference(Bucket, Name, Declaration)
		end
	end

	return Declarations
end

---- Structure Parsing Functions ----

function Parser.GetOptionFromToken(self: Parser, Token: Token, Structure: { EventOption }): EventOption
	local Value = Token.Value
	for _, Option in Structure do
		local Key = Option.Key
		if Key == Value or string.lower(Key) == Value then
			return Option
		end
	end

	local OptionsString = ""
	for Index, Option in Structure do
		OptionsString ..= `{Index ~= 1 and " or " or ""}"{Option.Key}"`
	end

	error(
		Error.new(Error.ParserUnknownOption, self.Source, `Unknown option "{Value}"`, self.File)
			:Primary(Token, `Expected one of {OptionsString}`)
			:Emit()
	)
end

function Parser.Structure(self: Parser, Name: Token, Structure: { EventOption }): { [string]: any }
	local Fields: { [string]: any } = {}
	local Open, Close: Lexer.Token? = self:Consume("OpenBraces"), nil

	while true do
		Close = self:TryConsume("CloseBraces")
		if Close then
			break
		end

		local Value: any
		local Field = self:ConsumeText()
		local Option = self:GetOptionFromToken(Field, Structure)
		self:Consume("FieldAssign")

		--> Prevent duplicate fields
		if Fields[Option.Key] then
			Error.new(Error.AnalyzeDuplicateField, self.Source, `Field "{Option.Key}" was already specified`, self.File)
				:Primary(Field, `Already specified earlier in the structure`)
				:Emit()
		end

		--> `Poll: true` is the 0.x spelling of `Call: Polling`. Both still work and compile to exactly
		--> the same thing -- Parser.Event folds one into the other -- but only `Call` appears in the
		--> documentation, so a schema written with `Poll` is using a spelling nothing tells you about
		--> and nothing warns you off. `UseColon` has warned for the same reason since it stopped
		--> doing anything; this one still works, which is why it warns rather than errors.
		if Option.Key == "Poll" then
			Error.new(Error.AnalyzeDeprecatedOption, self.Source, `Field "Poll" is deprecated`, self.File, "Warning")
				:Primary(Field, "Use `Call: Polling` instead")
				:Note("The two compile to the same thing, but only `Call` is documented.")
				:Warn()
		end

		--> Parse non data/return field
		if Option.Numeric then
			local Token = self:Consume(Option.Type)
			local Numeric = tonumber(Token.Value)

			if not Numeric or Numeric <= 0 then
				Error.new(Error.ParserUnknownOption, self.Source, `Invalid value for "{Option.Key}"`, self.File)
					:Primary(Token, "Expected a number greater than zero")
					:Emit()
			end

			--> Stored as a number: every consumer does arithmetic with it.
			Value = Numeric
		elseif Option.Key ~= "Data" and Option.Key ~= "Return" then
			local Token = self:Consume(Option.Type)
			Value = Token.Value

			if not table.find(Option.Values, Value) then
				Error.new(Error.ParserUnknownOption, self.Source, `Unknown option "{Value}"`, self.File)
					:Primary(Token, `Expected one of "{table.concat(Option.Values, `" or "`)}"`)
					:Emit()
			end
		else
			Value = self:Type(Name, nil, true)
		end

		Fields[Option.Key] = Value
		Close = self:TryConsume("CloseBraces")

		if Close then
			break
		end

		self:Consume("Comma")
	end

	--> Check if all required fields where supplied
	for _, Option in Structure do
		if Option.Optional then
			continue
		end

		if Fields[Option.Key] ~= nil then
			continue
		end

		local Span: Error.Span = {
			End = math.max((Close :: Lexer.Token).End - 2, Open.Start),
			Start = Open.Start,
		}

		Error.new(Error.ParserExpectedExtraToken, self.Source, `Field "{Option.Key}" is missing`, self.File)
			:Primary(Span, `Add missing field "{Option.Key}"`)
			:Emit()
	end

	return Fields
end

function Parser.Event(self: Parser, Name: Token): Event
	local Structure = self:Structure(Name, EVENT)
	local Call: EventCall = Structure.Call
	if Structure.Poll then
		Call = "Polling"
	end

	return {
		Type = "Event",
		Name = Name.Value,
		Value = {
			From = Structure.From,
			Type = Structure.Type,
			Call = Call,
			Data = Structure.Data,
			Rate = Structure.Rate,
			Burst = Structure.Burst,
		},
		Tokens = {
			Identifier = Name,
		},
	}
end

function Parser.Function(self: Parser, Name: Token): Function
	local Structure = self:Structure(Name, FUNCTION)

	return {
		Type = "Function",
		Name = Name.Value,
		Value = {
			From = Structure.From or "Client",
			Yield = Structure.Yield,
			Data = Structure.Data,
			Return = Structure.Return,
			Rate = Structure.Rate,
			Burst = Structure.Burst,
		},
		Tokens = {
			Identifier = Name,
		},
	}
end

function Parser.Namespace(self: Parser, Name: Token): ScopeNode
	self:Consume("OpenBraces")

	--> Open scope
	local Parent = self.Scope
	local Scope: Scope = {
		Name = Name,
		Parent = Parent,
		Symbols = {
			Types = {},
			Scopes = {},
		},
	}

	self.Scope = Scope
	self.Symbols[Name.Value] = true
	Parent.Symbols.Scopes[Name.Value] = Scope

	local Declarations = self:Declarations()

	self.Scope = Parent

	return {
		Type = "Scope",
		Name = Name.Value,
		Value = {
			Scope = Scope,
			Values = Declarations,
		},
		Tokens = {},
	}
end

---- Type Parsing Functions ----

function Parser.Type(self: Parser, Name: Token, Keyword: Token?, IsDataField: boolean?): TypeNode
	local Declaration: TypeNode

	--> Fast path: We know the exact type
	if Keyword then
		local Value = Keyword.Value
		if Value ~= "struct" then
			self:Consume("Assign")

			--> Handle reference declarations
			local Type = KEYWORDS[Value].Type
			local Token = self:Peek()

			if Token.Type == "Identifier" then
				Declaration = self:Declaration(Name)
				if not IsDeclarationTypeSimiliar(Declaration.Type, Type :: Declarations) then
					Error.new(
						Error.AnalyzeReferenceInvalidType,
						self.Source,
						`Cannot cast "{Declaration.Type}" to "{Type}"`,
						self.File
					)
						:Primary(Token, `Expected a reference to "{Type}", got "{Declaration.Type}" instead`)
						:Emit()
				end
			end
		end

		--> Wasn't a reference declaration
		if not Declaration then
			if Value == "map" then
				Declaration = self:Map(Name)
			elseif Value == "set" then
				Declaration = self:Set(Name)
			elseif Value == "enum" then
				Declaration = self:Enum(Name)
			elseif Value == "type" then
				Declaration = self:Primitive(Name)
			elseif Value == "struct" then
				Declaration = self:Struct(Name)
			end
		end
	end

	--> Slow path: We have to figure out what we're declaring :)
	if not Keyword then
		local Peek = self:Peek()
		local Type: Lexer.Types = Peek.Type :: Lexer.Types

		if Type == "Keyword" then
			local Value = Peek.Value
			self:Consume("Keyword")

			if Value == "map" then
				Declaration = self:Map(Name)
			elseif Value == "set" then
				Declaration = self:Set(Name)
			elseif Value == "enum" then
				Declaration = self:Enum(Name)
			elseif Value == "struct" then
				Declaration = self:Struct(Name)
			end
		elseif Type == "Primitive" then
			Declaration = self:Primitive(Name)
		elseif Type == "Identifier" then
			Declaration = self:Declaration(Name)
		elseif Type == "OpenParentheses" and IsDataField then
			Declaration = self:Tuple(Name)
		end

		if not Declaration then
			Error.new(Error.ParserUnexpectedToken, self.Source, `Unexpected token`, self.File)
				:Primary(Peek, `Expected one of "Identifier" or "Primitive" or "Keyword", got "{Type}" instead`)
				:Emit()
		end
	end

	--> Set type attributes
	local Primitive: Settings.Primitive?
	if Declaration.Type == "Primitive" then
		Primitive = (Declaration :: Primitive).Value.Primitive
	end

	local Value = Declaration.Value :: Attributes
	local Tokens = Declaration.Tokens :: AttributesTokens

	-- ex: vector<u8> and u8(0..00)
	if Primitive then
		local Components = self:Components(Primitive)
		if Components then
			Value.Components = Components
		end

		local Range = self:Range(Primitive)
		if Range then
			if not Primitive.AllowsRange then
				local PrimitiveToken = (Declaration :: Primitive).Tokens.Primitive
				Error.new(Error.AnalyzeInvalidRangeType, self.Source, `Type doesn't accept a range`, self.File)
					:Primary(Range.Token, "Remove this range")
					:Secondary(PrimitiveToken, `"{PrimitiveToken.Value}" has no bounds to constrain`)
					:Emit()
			end

			Value.Range = Range.Range
			Tokens.Range = Range.Token
		end
	end

	local function WrapInOptional()
		-- ex: u8?
		local Optional = self:Optional()
		if Optional then
			if Declaration.Type == "Primitive" then
				local Node = Declaration :: Primitive
				if not Node.Value.Primitive.AllowsOptional then
					Error.new(Error.AnalyzeInvalidOptionalType, self.Source, `Type cannot be optional`, self.File)
						:Primary(Optional, "Remove this optional")
						:Secondary(
							Node.Tokens.Primitive,
							`"{Node.Tokens.Primitive.Value}" has no way to encode absence`
						)
						:Emit()
				end
			end

			Declaration = {
				Type = "Optional",
				Name = Name.Value,
				Value = { Of = Declaration },
				Tokens = {},
			} :: Optional
		end
	end

	WrapInOptional()

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

		WrapInOptional()

		if Array == nil then
			break
		end
	end

	return Declaration
end

function Parser.Set(self: Parser, Name: Token): Set
	self:Consume("OpenBraces")

	local Values: { string } = {}
	while true do
		if self:TryConsume("CloseBraces") then
			break
		end

		local Token = self:ConsumeText(true, true)
		table.insert(Values, Token.Value)

		if self:TryConsume("CloseBraces") then
			break
		end

		self:Consume("Comma")
	end

	return {
		Type = "Set",
		Name = Name.Value,
		Value = {
			Values = Values,
		},
		Tokens = {},
	} :: Set
end

function Parser.Map(self: Parser, Name: Token): Map
	self:ConsumeAll("OpenBraces", "OpenBrackets")

	--> Errors
	local function ParseElement(): (TypeNode, Token)
		local Token = self:Peek()
		local Declaration = self:Type(Name)
		if Declaration.Type == "Optional" then
			Error.new(Error.AnalyzeInvalidOptionalType, self.Source, "Invalid optional type", self.File)
				:Primary(Token, `Maps cannot have optionals as keys or values`)
				:Emit()
		end

		return Declaration, Token
	end

	--> Parse key and value
	local Key, KeyToken = ParseElement()
	self:Consume("CloseBrackets")
	self:Consume("FieldAssign")

	local Value = ParseElement()
	self:Consume("CloseBraces")

	return {
		Type = "Map",
		Name = Name.Value,
		Value = {
			Values = { Key, Value },
		},
		--> Kept so a diagnostic about the key can underline the key rather than the declaration. A
		--> composite key is a node with no token of its own, and Analysis runs after generics are
		--> substituted, by which point there is nothing left to point at without this.
		Tokens = { Key = KeyToken },
	}
end

function Parser.Enum(self: Parser, Name: Token): Enum | TagEnum
	local Values: { string } = {}

	--> Is it a tagged enum?
	local Tag = self:TryConsume("String")
	if Tag then
		return self:TagEnum(Tag, Name)
	end

	self:Consume("OpenBraces")

	while true do
		if self:TryConsume("CloseBraces") then
			break
		end

		local Token = self:ConsumeText(true, true)
		table.insert(Values, Token.Value)

		if self:TryConsume("CloseBraces") then
			break
		end

		self:Consume("Comma")
	end

	return {
		Type = "Enum",
		Name = Name.Value,
		Value = { Values = Values } :: any,
		Tokens = {},
	}
end

function Parser.TagEnum(self: Parser, Tag: Token, Name: Token): TagEnum
	local Values: { Struct } = {}
	self:Consume("OpenBraces")

	while true do
		if self:TryConsume("CloseBraces") then
			break
		end

		local Token: Token

		if self:Peek().Type == "OpenBrackets" then
			self:Consume("OpenBrackets")
			Token = self:Consume("String")
			self:Consume("CloseBrackets")
		else
			Token = self:ConsumeText(true)
		end

		local Struct = self:Struct(Token)
		local Fields = Struct.Value.Values

		--> Don't allow tag field to be set
		for _, Field: TypeNode in Fields do
			if Field.Name == Tag.Value then
				Error.new(Error.AnalyzeReservedIdentifier, self.Source, `Enum tag used as field in variant`, self.File)
					:Secondary(Token, `Used in variant`)
					:Primary(Tag, `Enum tag`)
					:Emit()
			end
		end

		table.insert(Values, Struct)

		if self:TryConsume("CloseBraces") then
			break
		end

		self:Consume("Comma")
	end

	return {
		Type = "TagEnum",
		Name = Name.Value,
		Value = {
			Tag = Tag.Value,
			Values = Values,
		},
		Tokens = {},
	}
end

function Parser.Tuple(self: Parser, Name: Token): Tuple
	local Names: { [number]: string } = {}
	local Taken: { [string]: true } = {}
	local Values: { TypeNode } = {}
	self:Consume("OpenParentheses")

	--> An element may carry a name: `(chefId: f64, dish: string)`. Deciding that needs one token of
	--> lookahead past the candidate -- `(u8)` and `(x: u8)` are indistinguishable where the element
	--> starts, since a bare type is itself a perfectly good element. `self.LookAhead` is the element's
	--> first token and the lexer sits just past it, so a non-advancing GetNextToken is the token after.
	local function TryConsumeName(): Token?
		if self.Lexer:GetNextToken(true).Type ~= "FieldAssign" then
			return nil
		end

		local Text = self:ConsumeText(true)
		self:Consume("FieldAssign")
		return Text
	end

	while true do
		if self:TryConsume("CloseParentheses") then
			break
		end

		local Text = TryConsumeName()
		if Text then
			--> Unlike a struct field, which becomes a table key and is quoted on the way out, this name
			--> becomes a local variable in the generated module. A Luau keyword, or anything that is not
			--> an identifier, would emit code that does not compile -- so it is refused here, where the
			--> author can see which name did it, rather than by luau-analyze over generated output.
			if LUAU_KEYWORDS[Text.Value] or not string.match(Text.Value, "^[%a_][%w_]*$") then
				error(
					Error.new(
						Error.AnalyzeReservedIdentifier,
						self.Source,
						`"{Text.Value}" cannot name a type pack element`,
						self.File
					)
						:Primary(Text, "Not usable as a variable name")
						:Note(
							"A named element becomes a parameter in the generated code, so it has to be a Luau identifier."
						)
						:Emit()
				)
			end

			if Taken[Text.Value] then
				error(
					Error.new(Error.AnalyzeDuplicateField, self.Source, `Duplicate element "{Text.Value}"`, self.File)
						:Primary(Text, `Duplicate element`)
						:Note("Each named element of a type pack becomes a parameter, so the names must differ.")
						:Emit()
				)
			end
		end

		--> The pack's own token goes through even for a named element. The name is recorded beside the
		--> value instead of replacing the node's, so a named and an unnamed element are described
		--> identically -- a diagnostic inside either still points at the declaration, and the
		--> generated comment still reads `chefId: NamedTuple` rather than `chefId: chefId`.
		local Value = self:Type(Name)
		table.insert(Values, Value)

		if Text then
			Taken[Text.Value] = true
			Names[#Values] = Text.Value
		end

		if self:TryConsume("CloseParentheses") then
			break
		end

		self:Consume("Comma")
	end

	return {
		Type = "Tuple",
		Name = Name.Value,
		Value = {
			Values = Values,
			Names = Names,
		},
		Tokens = {},
	}
end

function Parser.Struct(self: Parser, Name: Token): Struct
	local Fields: { [string]: true } = {}
	local Values: { TypeNode } = {}
	self:Consume("OpenBraces")

	while true do
		if self:TryConsume("CloseBraces") then
			break
		end

		--> struct merging
		if self:TryConsume("Merge") then
			local Text = self:Peek()
			local Declaration = self:Declaration(Name)
			if Declaration.Type ~= "Struct" then
				error(
					Error.new(
						Error.AnalyzeReferenceInvalidType,
						self.Source,
						`Expected a struct to merge, got "{Declaration.Type}" instead`,
						self.File
					)
						:Primary(Text, `Expected a "Struct", got "{Declaration.Type}" instead`)
						:Emit()
				)
			end

			local Struct: Struct = Declaration :: Struct
			local StructValues = Struct.Value.Values
			for _, Field in StructValues do
				local FieldIdentifier = Field.Name
				if Fields[FieldIdentifier] then
					error(
						Error.new(
							Error.AnalyzeDuplicateField,
							self.Source,
							`Merged struct contains a duplicate field`,
							self.File
						)
							:Primary(Text, `Field "{FieldIdentifier}" already exists in struct`)
							:Emit()
					)
				end

				table.insert(Values, Field)
				Fields[FieldIdentifier] = true
			end
		else --> fields
			local Text: Token

			if self:Peek().Type == "OpenBrackets" then
				self:Consume("OpenBrackets")
				Text = self:Consume("String")
				self:Consume("CloseBrackets")
			else
				Text = self:ConsumeText(true)
			end

			if Fields[Text.Value] then
				error(
					Error.new(Error.AnalyzeDuplicateField, self.Source, `Duplicate field "{Text.Value}"`, self.File)
						:Primary(Text, `Duplicate field`)
						:Emit()
				)
			end

			self:Consume("FieldAssign")

			Fields[Text.Value] = true
			table.insert(Values, self:Type(Text))
		end

		if self:TryConsume("CloseBraces") then
			break
		end

		self:Consume("Comma")
	end

	return {
		Type = "Struct",
		Name = Name.Value,
		Value = {
			Values = Values,
		},
		Tokens = {},
	}
end

function Parser.Primitive(self: Parser, Name: Token): Primitive
	local Token = self:Consume("Primitive")

	local Class: string?
	local Value = Token.Value
	local Primitive = PRIMITIVES[Value]

	if Value == "Instance" then
		local ClassToken = self:TryConsume("Class")
		Class = if ClassToken then string.sub(ClassToken.Value, 2, #ClassToken.Value - 1) else "Instance"
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

function Parser.Declaration(self: Parser, Name: Token): TypeNode
	local Token = self:ConsumeText()

	--> Generics reference resolution
	local Generics = self.Generics
	local List = (Generics and Generics.Keys[Token.Value])
	if List then
		local Generic: Generic = {
			Type = "Generic",
			Name = Name.Value,
			Value = { Generic = Token.Value },
			Tokens = {},
		}

		table.insert(List, Generic)
		return Generic
	end

	--> Normal reference resolution
	local Reference = self:Reference("Types", Token.Value) :: Reference
	if not Reference then
		--> A type that names itself reported "Unknown reference", which is true and useless: the
		--> name is missing only because a declaration is registered after it closes, and the reader
		--> is left checking their spelling of a word that is on the screen in front of them.
		-->
		--> Recursive types are not supported at all here, optional field or not. References are
		--> resolved and inlined at parse time rather than held as a link, so there is no point at
		--> which the parser could tie the knot.
		if self.Declaring ~= nil and Token.Value == self.Declaring then
			error(
				Error.new(Error.AnalyzeRecursiveType, self.Source, `Recursive type`, self.File)
					:Primary(Token, `"{Token.Value}" refers to itself`)
					:Note(
						"A declaration is only in scope once it closes, and references are inlined where they appear, so a type cannot contain another of itself."
					)
					:Emit()
			)
		end

		error(
			Error.new(Error.AnalyzeUnknownReference, self.Source, `Unknown reference`, self.File)
				:Primary(Token, "Unknown reference")
				:Emit()
		)
	end

	local To = Reference.To
	AttributeParser.Refer(self :: any, Token, To)

	--> Need to use the new node name.
	--> `TypeNode` is a union of node shapes, and Luau permits neither `table.clone` nor a field write
	--> on a union. The rename therefore happens on a loose clone, which is then narrowed back on the
	--> way out; the clone stays shallow either way.
	local Renamed = table.clone(To :: any)
	Renamed.Name = Name.Value
	To = Renamed :: TypeNode

	if GENERICS_TYPES[To.Type] and To.Value.Generics then
		To = self:ReplaceGenerics(To)
	end

	return To
end

return Parser
