--!strict
--- How the suite decides that what arrived is what was sent: a deep comparison that follows cycles
--- and compares table keys by value, and the report when it does not hold. Re-exported by
--- Assertions.luau, which is where the specs take them from.
local Format = require("../src/Modules/Format")
local Harness = require("./Harness")

local ErrorPrint = Harness.ErrorPrint

local function GetFlags(Amount: number): { [string]: boolean }
	local Flags = {}
	for Index = 1, Amount do
		Flags[`F{Index}`] = (math.random(1, 2) == 2)
	end
	return Flags
end

local function Fail(Name: string, Expect: any, Got: any)
	ErrorPrint(`Failed "{Name}"\nExpected: {Format(Expect)}\nGot: {Format(Got)}.`)
end

local function Equals(a: any, b: any)
	local Cyclic = {}
	local function Compare(Left: any, Right: any)
		local TypeA = type(Left)
		local TypeB = type(Right)

		if TypeA ~= TypeB then
			return false
		end

		if TypeA == "table" then
			if Cyclic[Left] then
				return Cyclic[Left] == Right
			end

			Cyclic[Left] = Right

			local KeysB = {}
			local TableKeysB = {}

			for Key in Right do
				if type(Key) == "table" then
					table.insert(TableKeysB, Key)
				end

				KeysB[Key] = true
			end

			for KeyA, ValueA in pairs(Left) do
				local ValueB = Right[KeyA]
				if type(KeyA) == "table" then
					local Match = false
					for Index, Key in TableKeysB do
						if Equals(KeyA, Key) and Compare(ValueA, Right[Key]) then
							Match = true
							KeysB[Key] = nil
							table.remove(TableKeysB, Index)
							break
						end
					end

					if Match == false then
						return false
					end
				else
					if ValueB == nil then
						return false
					end

					KeysB[KeyA] = nil

					if not Compare(ValueA, ValueB) then
						return false
					end
				end
			end

			if next(KeysB) then
				return false
			end

			return true
		elseif TypeA == "buffer" then
			return buffer.tostring(Left) == buffer.tostring(Right)
		end

		return Left == Right
	end

	return Compare(a, b)
end

return {
	GetFlags = GetFlags,
	Fail = Fail,
	Equals = Equals,
}
