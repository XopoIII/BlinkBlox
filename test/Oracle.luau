--!strict
--- Which values a schema type admits, and when two of them are the same -- worked out from the parsed
--- schema alone, never from the generated code, so a serialiser that disagrees with the schema
--- disagrees with this. Properties.luau judges what the generated modules return by it; Generate.luau
--- draws values it admits.
local Narrow = require("@compiler/Generator/Prefabs/Narrow")
local Settings = require("@compiler/Settings")

type Node = { Type: string, Name: string, Value: any, Tokens: any }

local Oracle = {}

local INTEGERS = { u8 = true, u16 = true, u32 = true, i8 = true, i16 = true, i32 = true }
local FLOATS = { f16 = true, f32 = true, f64 = true }

local function PrimitiveName(Node: Node): string
	return Node.Tokens.Primitive.Value
end

--- A number as an f32 holds it.
function Oracle.F32(Value: number): number
	local Scratch = buffer.create(4)
	buffer.writef32(Scratch, 0, Value)
	return buffer.readf32(Scratch, 0)
end

local F32 = Oracle.F32

--- Whether a number is one this primitive type admits, range included.
function Oracle.Admits(Node: Node, Value: number): boolean
	local Name = PrimitiveName(Node)
	local Range = Node.Value.Range

	if INTEGERS[Name] then
		local Bounds = Range or Settings.Primtives[Name].Bounds
		return Value == math.floor(Value) and Value >= Bounds.Min and Value <= Bounds.Max
	elseif Name == "f32" and Value == Value and F32(Value) ~= Value then
		return false
	end

	if not Range then
		return true
	end

	--> A ranged float refuses NaN, and checks the bounds as the receiver narrows them.
	local Min, Max = Narrow.Bounds(Name, Range.Min, Range.Max)
	return Value == Value and Value >= Min and Value <= Max
end

local function Count(Table: { [any]: any }): number
	local Total = 0
	for _ in Table do
		Total += 1
	end

	return Total
end

--- Why `Value` is not a value of `Node`, or nil when it is. Strict about shape: a decoder that adds a
--- field, leaves one out or fills a hole is as wrong as one that decodes a number out of range.
function Oracle.Valid(Node: Node, Value: any): string?
	local Body = Node.Value

	if Node.Type == "Primitive" then
		local Name = PrimitiveName(Node)
		if INTEGERS[Name] or FLOATS[Name] then
			if type(Value) ~= "number" then
				return `expected a number, got {typeof(Value)}`
			elseif not Oracle.Admits(Node, Value) then
				return `{Value} is not a {Name}{if Body.Range then ` in {Body.Range.Min}..{Body.Range.Max}` else ""}`
			elseif Name == "f16" and Value == Value and Narrow.f16(Value) ~= Value then
				return `{Value} is not a half-precision value`
			end

			return nil
		elseif Name == "boolean" then
			return if type(Value) == "boolean" then nil else `expected a boolean, got {typeof(Value)}`
		end

		local Wanted = if Name == "string" then "string" else "buffer"
		if typeof(Value) ~= Wanted then
			return `expected a {Wanted}, got {typeof(Value)}`
		end

		local Size = if Name == "string" then #Value else buffer.len(Value)
		local Range = Body.Range or { Min = 0, Max = 65535 }
		if Size < Range.Min or Size > Range.Max then
			return `a length of {Size} is outside {Range.Min}..{Range.Max}`
		end

		return nil
	elseif Node.Type == "Optional" then
		return if Value == nil then nil else Oracle.Valid(Body.Of, Value)
	elseif Node.Type == "Enum" then
		return if table.find(Body.Values, Value) then nil else `"{Value}" is not one of the enum's values`
	elseif type(Value) ~= "table" then
		return `expected a table for {Node.Type}, got {typeof(Value)}`
	end

	if Node.Type == "Set" then
		if Count(Value) ~= #Body.Values then
			return `a set of {#Body.Values} flags decoded with {Count(Value)} entries`
		end

		for _, Flag in Body.Values do
			if type(Value[Flag]) ~= "boolean" then
				return `flag "{Flag}" is not a boolean`
			end
		end

		return nil
	elseif Node.Type == "Struct" or Node.Type == "TagEnum" then
		local Fields: { Node } = Body.Values
		local Expected = 0
		if Node.Type == "TagEnum" then
			local Variant: Node? = nil
			for _, Candidate in Body.Values do
				if Candidate.Name == Value[Body.Tag] then
					Variant = Candidate
				end
			end

			if not Variant then
				return `"{Value[Body.Tag]}" is not a variant`
			end

			Fields = (Variant :: Node).Value.Values
			Expected = 1
		end

		for _, Field in Fields do
			local Reason = Oracle.Valid(Field, Value[Field.Name])
			if Reason then
				return `{Field.Name}: {Reason}`
			end

			if Value[Field.Name] ~= nil then
				Expected += 1
			end
		end

		return if Count(Value) == Expected then nil else `decoded {Count(Value)} fields, expected {Expected}`
	elseif Node.Type == "Array" then
		--> The length of a decoded array is its highest index, not `#`: an array of optionals keeps
		--> its holes, and `#` may stop at any of them. Trailing nils leave no trace in a table, so
		--> only an array that cannot hold nil is held to its lower bound.
		local Range = Body.Range
		local Highest = 0
		for Key in Value do
			if type(Key) ~= "number" or Key < 1 or Key ~= math.floor(Key) then
				return `an array has the key {Key}`
			end

			Highest = math.max(Highest, Key)
		end

		local Size = if Range.Min == Range.Max then Range.Max else Highest
		local Holes = Body.Of.Type == "Optional"
		if Highest > Range.Max or (not Holes and (Size < Range.Min or Count(Value) ~= Size)) then
			return `{Count(Value)} elements up to index {Highest}, outside {Range.Min}..{Range.Max}`
		end

		for Index = 1, Size do
			local Reason = Oracle.Valid(Body.Of, Value[Index])
			if Reason then
				return `[{Index}]: {Reason}`
			end
		end

		return nil
	elseif Node.Type == "Map" then
		if Count(Value) > 65535 then
			return `a map of {Count(Value)} entries`
		end

		for Key, Entry in Value do
			local Reason = Oracle.Valid(Body.Values[1], Key) or Oracle.Valid(Body.Values[2], Entry)
			if Reason then
				return `[{Key}]: {Reason}`
			end
		end

		return nil
	end

	return `unexpected node {Node.Type}`
end

--- Whether `Got` is what a float of type `Name` may legitimately become of `Sent` on the wire. Worked
--- out independently of the compiler's own narrowing: f32 is the platform's, and f16 is held to
--- being a half-precision value within one unit of its last place, with the sign kept.
function Oracle.Narrowed(Name: string, Sent: number, Got: number): boolean
	if Sent ~= Sent then
		return Got ~= Got
	elseif Name == "f64" or INTEGERS[Name] then
		return Sent == Got and (Sent ~= 0 or 1 / Sent == 1 / Got)
	elseif Name == "f32" then
		local Expected = F32(Sent)
		return Expected == Got and (Expected ~= 0 or 1 / Expected == 1 / Got)
	end

	if Got ~= Got or (Got ~= 0 and math.abs(Got) ~= math.huge and Narrow.f16(Got) ~= Got) then
		return false
	elseif math.abs(Sent) > 65504 then
		return Got == (if Sent > 0 then math.huge else -math.huge)
	elseif (1 / Sent > 0) ~= (1 / Got > 0) and Got ~= 0 then
		return false
	end

	local Unit = math.max(math.ldexp(1, math.floor(math.log(math.abs(Sent), 2)) - 10), math.ldexp(1, -24))
	return math.abs(Got - Sent) <= Unit
end

--- Whether two values of `Node` are the same value. Floats compare by bits: NaN equals NaN, and -0
--- does not equal 0, since both are values a sender can mean.
function Oracle.Equal(Node: Node, Left: any, Right: any, Loose: boolean?): boolean
	if Loose and Node.Type == "Primitive" and type(Left) == "number" and type(Right) == "number" then
		return Oracle.Narrowed(PrimitiveName(Node), Left, Right)
	elseif type(Left) == "number" and type(Right) == "number" then
		if Left ~= Left then
			return Right ~= Right
		end

		return Left == Right and (Left ~= 0 or 1 / Left == 1 / Right)
	elseif typeof(Left) == "buffer" and typeof(Right) == "buffer" then
		return buffer.tostring(Left) == buffer.tostring(Right)
	elseif type(Left) ~= "table" or type(Right) ~= "table" then
		return Left == Right
	end

	local Body = Node.Value
	if Node.Type == "Optional" then
		return Oracle.Equal(Body.Of, Left, Right, Loose)
	elseif Node.Type == "Array" then
		local Size = if Body.Range.Min == Body.Range.Max then Body.Range.Max else math.max(#Left, #Right)
		for Index = 1, Size do
			if not Oracle.Equal(Body.Of, Left[Index], Right[Index], Loose) then
				return false
			end
		end

		return Count(Left) == Count(Right)
	elseif Node.Type == "Map" then
		for Key, Entry in Left do
			if not Oracle.Equal(Body.Values[2], Entry, Right[Key], Loose) then
				return false
			end
		end

		return Count(Left) == Count(Right)
	elseif Node.Type == "Struct" or Node.Type == "TagEnum" then
		local Fields: { Node } = Body.Values
		if Node.Type == "TagEnum" then
			if Left[Body.Tag] ~= Right[Body.Tag] then
				return false
			end

			for _, Variant in Body.Values do
				if Variant.Name == Left[Body.Tag] then
					Fields = Variant.Value.Values
				end
			end
		end

		for _, Field in Fields do
			if not Oracle.Equal(Field, Left[Field.Name], Right[Field.Name], Loose) then
				return false
			end
		end

		return true
	elseif Node.Type == "Set" then
		for _, Flag in Body.Values do
			if Left[Flag] ~= Right[Flag] then
				return false
			end
		end

		return true
	end

	return false
end

return Oracle
