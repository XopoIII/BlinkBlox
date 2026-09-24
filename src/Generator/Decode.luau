--!strict
--!native
--!optimize 2

--- What the receiving side's decode loop checks for one declaration after reading it: whether its rate
--- limit lets it through, and whether an ordered packet is newer than the last one seen.
local State = require("./State")

local Decode = {}

--- Claims a bucket slot for an inbound declaration that declares a rate, and returns the call that
--- spends a token from it. Returns nil when nothing limits this declaration, in which case no guard
--- is emitted at all -- an unlimited schema produces exactly the code it always did.
---
--- Server-only: the client trusts the server, and the bucket state lives in the server template.
function Decode.RateGuardExpression(Value: { Rate: number?, Burst: number? }, Name: string): string?
	if State.Context ~= "Server" then
		return nil
	end

	local Rate = Value.Rate or State.Options.DefaultRate
	if not Rate then
		return nil
	end

	--> A burst of one would refuse the very first event of a frame whenever the previous frame used
	--> its budget, so the floor is one whole token.
	local Burst = Value.Burst or math.max(math.ceil(Rate), 1)

	table.insert(State.RateSlots, { Rate = Rate, Burst = Burst })
	local Slot = ((#State.RateSlots - 1) * 4) + 1

	return `RateAccept(Player, {Slot}, {Rate}, {Burst}, "{Name}")`
end

--- The call that decides whether an ordered packet is newer than the last one seen. Nil when the
--- event is not ordered, in which case no check is emitted at all.
---
--- The server keys by player: sixty clients each run their own sequence, and one client's counter
--- says nothing about another's.
function Decode.OrderGuardExpression(IsOrdered: boolean, Index: number): string?
	if not IsOrdered then
		return nil
	end

	if State.Context == "Server" then
		return `OrderAccept(Player, {Index}, OrderIdentifier)`
	end

	return `OrderAccept({Index}, OrderIdentifier)`
end

return Decode
