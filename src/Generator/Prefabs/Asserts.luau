--!strict
--!native
--!optimize 2

--- The runtime checks the prefabs emit: bounds on a value, and guards that a decoded length is backed
--- by what the packet still holds before anything is allocated for it.
local Common = require("./Common")
local Parser = require("../../Parser")
local Size = require("../../Modules/Size")

type Block = Common.Block
type AssertPrefab = Common.AssertPrefab

local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local RECIEVE_CURSOR = Common.RECIEVE_CURSOR

local Asserts = {
	--> Written as `not (x >= Min)` rather than `x < Min`, here and for vectors: NaN compares false
	--> against everything, so `x < Min` and `x > Max` both let it through, and a client could hand a
	--> ranged float listener a NaN that every check downstream had been told was impossible.
	number = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min}) then error(\`Expected "{Variable}" to be larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max}) then error(\`Expected "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if {Variable} ~= {Max} then error(\`Expected "{Variable}" to be equal to {Max}, got \{{Variable}\} instead.\`) end`,
		}
	end,

	string = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		--> `Measure` names the expression to compare. The read path passes the decoded length so the
		--> bound is checked before the string is read; the write path omits it and measures the value.
		local Length = Measure or `#{Variable}`
		return {
			Lower = `if {Length} < {Min} then error(\`Expected length of "{Variable}" to be larger than or equal to {Min}, got \{{Length}} instead.\`) end`,
			Upper = `if {Length} > {Max} then error(\`Expected length of "{Variable}" to be smaller than or equal to {Max}, got \{{Length}} instead.\`) end`,
			Exact = `if {Length} ~= {Max} then error(\`Expected length of "{Variable}" to equal to {Max}, got \{{Length}} instead.\`) end`,
		}
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable}.Magnitude >= {Min}) then error(\`Expected magnitude of "{Variable}" to be larger than or equal to {Min}, got \{{Variable}.Magnitude} instead.\`) end`,
			Upper = `if not ({Variable}.Magnitude <= {Max}) then error(\`Expected magnitude of "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			Exact = `if {Variable}.Magnitude ~= {Max} then error(\`Expected magnitude of "{Variable}" to equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
		}
	end,

	buffer = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		--> See the note on `Asserts.string` for what `Measure` is for.
		local Length = Measure or `buffer.len({Variable})`
		return {
			Lower = `if {Length} < {Min} then error(\`Expected size of "{Variable}" to be larger than or equal to {Min}, got \{{Length}} instead.\`) end`,
			Upper = `if {Length} > {Max} then error(\`Expected size of "{Variable}" to be smaller than or equal to {Max}, got \{{Length}} instead.\`) end`,
			Exact = `if {Length} ~= {Max} then error(\`Expected size of "{Variable}" to equal to {Max}, got \{{Length}} instead.\`) end`,
		}
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Something has gone wrong")`,
			Upper = `error("Something has gone wrong")`,
			Exact = if Class == "Instance"
				then TypeAssertion
				else `{TypeAssertion}\nif not {Variable}:IsA("{Class}") then error(\`Expected an Instance of type "{Class}", got "\{{Variable}.ClassName}" instead.\`) end`,
		}
	end,
}

--> A length read out of a hostile packet may name more bytes than the packet still holds. Reading
--> that far throws inside `buffer.read*` and the decode loop's pcall turns it into a dropped packet,
--> but `buffer` would have allocated the whole span first. Checking the remaining space keeps a
--> length prefix from buying an allocation, and it is exact rather than conservative: block reads
--> reserve their fixed bytes up front, so at this point the cursor sits where the payload begins.
local function GenerateSpaceGuard(Length: string, Variable: string): string
	return `if {Length} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
end

--- Emits a guard on a decoded element count, before the array behind it is allocated.
---
--- `table.create(Length)` reserves every slot up front, so a count the packet cannot possibly back
--- still buys that allocation even though the loop fails on its first iteration: two bytes reserve
--- 65535 slots, and `u8[]` is enough to ask for them. Comparing the count against what is left of
--- whatever its elements read closes that.
---
--- The comparison uses the MINIMUM an element costs, which is the most that can be assumed about
--- it, so the guard errs towards letting a packet through rather than refusing an honest one. An
--- element that costs nothing either way is refused at compile time instead -- there is no resource
--- left to measure it against.
local function EmitCapacityGuard(Block: Block, Length: string, Variable: string, Of: Parser.TypeNode)
	--> A packed boolean costs an eighth of a byte, which the per-element minimum below would round up
	--> to one -- and then refuse an honest 800-element array for not fitting in its 100 bytes.
	if Size.PacksBooleans(Of :: any) then
		Block:Line(
			`if ({Length} + 7) // 8 > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	local Element = Size.Sealed(Of :: any)

	if Element.Min > 0 then
		local Needed = if Element.Min == 1 then Length else `{Length} * {Element.Min}`
		Block:Line(
			`if {Needed} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	if Element.Refs > 0 then
		local Needed = if Element.Refs == 1 then Length else `{Length} * {Element.Refs}`
		Block:Line(
			`if {Needed} > #RecieveInstances - RecieveInstanceCursor then error(\`Expected "{Variable}" to fit in the \{#RecieveInstances - RecieveInstanceCursor} values left beside the packet, got a length of \{{Length}} instead.\`) end`
		)
	end
end

return {
	Asserts = Asserts,
	GenerateSpaceGuard = GenerateSpaceGuard,
	EmitCapacityGuard = EmitCapacityGuard,
}
