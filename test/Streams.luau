--!strict
--- Specs for a stream's scheduler: when it sends, counted frame by frame on a clock stepped by hand.
---
--- Every expectation is the exact list of frames that sent. At sixty frames a second a rate of 10 is
--- one send every six frames and 20 every three; the first state of an idle stream goes at the first
--- step. See StreamSupport.luau for the schema, and docs/.../language/streams.mdx for the rules.
local Assertions = require("./Assertions")
local Shared = require("./Shared")
local Support = require("./StreamSupport")

local RunClosure = Assertions.RunClosure
local Fresh, Frames, Expect, Heads, Vector =
	Support.Fresh, Support.Frames, Support.Expect, Support.Heads, Support.Vector

RunClosure("A changing stream sends ten times a second at a Rate of 10", function()
	local Pair = Fresh()
	local Sent = Frames(Pair, 60, function(Frame)
		Pair.Server.Heads.Set(Heads(Frame))
	end)

	Expect("frames that sent", Sent, { 1, 7, 13, 19, 25, 31, 37, 43, 49, 55 })
end)

RunClosure("SetFast sends at the Fast rate, and SetFast(false) goes back", function()
	local Pair = Fresh()
	Pair.Server.Heads.SetFast(true)
	local Fast = Frames(Pair, 30, function(Frame)
		Pair.Server.Heads.Set(Heads(Frame))
	end)
	Expect("frames that sent fast", Fast, { 1, 4, 7, 10, 13, 16, 19, 22, 25, 28 })

	--> The last fast send was frame 28, two frames before this run: six frames after it is frame 4.
	Pair.Server.Heads.SetFast(false)
	local Slow = Frames(Pair, 30, function(Frame)
		Pair.Server.Heads.Set(Heads(100 + Frame))
	end)
	Expect("frames that sent after SetFast(false)", Slow, { 4, 10, 16, 22, 28 })
end)

RunClosure("An unchanged state is skipped and sent again every Keepalive", function()
	local Pair = Fresh()
	--> An equal state in a new table each frame: equality is by value, not by reference.
	local Sent = Frames(Pair, 130, function()
		Pair.Server.Heads.Set(Heads(5))
	end)

	--> Frame 1, then exactly one second later -- frame 61, not the due step before it or after it.
	Expect("frames that sent", Sent, { 1, 61, 121 })
end)

RunClosure("A stream that stops moving sends its still state once", function()
	local Pair = Fresh()
	local Sent = Frames(Pair, 80, function(Frame)
		Pair.Server.Heads.Set(Heads(math.min(Frame, 13)))
	end)

	--> 7 and 13 carried changes; 19 is the same as 13 and still goes, so the clients learn the head
	--> stopped; then nothing until the keepalive a second after 19.
	Expect("frames that sent", Sent, { 1, 7, 13, 19, 79 })
end)

RunClosure("A stream that starts still is sent once", function()
	local Pair = Fresh()
	local Sent = Frames(Pair, 20, function()
		Pair.Server.Speed.Set(3)
	end)

	Expect("frames that sent", Sent, { 1 })
end)

RunClosure("Urgent sends at the next step and restarts the interval", function()
	local Pair = Fresh()
	local Sent = Frames(Pair, 16, function(Frame)
		if Frame == 4 then
			Pair.Server.Heads.Urgent()
		end

		--> Unchanged up to the urgent send, so only Urgent can send frame 4; changing after it, so every
		--> due step sends and shows where the interval restarted.
		Pair.Server.Heads.Set(Heads(if Frame <= 4 then 0 else Frame))
	end)

	Expect("frames that sent", Sent, { 1, 4, 10, 16 })
end)

RunClosure("A number within Epsilon of the last one sent is the same state", function()
	local Pair = Fresh()
	local Received: { number } = {}
	Pair.Client.Speed.On(function(Value: number?)
		table.insert(Received, Value or -1)
	end)

	--> Epsilon is 0.25, and every value here is exact in binary.
	local Values = { 1, 1, 1, 1, 1, 1, 1.25, 1.25, 1.25, 1.25, 1.25, 1.25, 1.25, 1.5 }
	local Sent = Frames(Pair, 31, function(Frame)
		local Value = Values[Frame] or (if Frame <= 25 then 1.5 else 1.25)
		Pair.Server.Speed.Set(Value)
	end)

	--> 7 and 13: 1.25 is within 0.25 of the 1 sent. 19: 1.5 is not. 25: the still state after a change.
	--> 31: 1.25 is within 0.25 of the 1.5 sent, and 25 changed nothing.
	Expect("frames that sent", Sent, { 1, 19, 25 })

	for _, Packet in Pair.Outbound do
		Pair.Deliver(Packet)
	end
	Expect("values received", Received, { 1, 1.5, 1.5 })
end)

RunClosure("A vector is the same state while each component is within Epsilon", function()
	local Pair = Fresh()
	local Sent = Frames(Pair, 13, function(Frame)
		--> Each component 0.25 away, though the whole vector is 0.43 away: not a change. Then one
		--> component 0.5 away: a change.
		local Value = if Frame == 1
			then Vector(0, 0, 0)
			elseif Frame <= 7 then Vector(0.25, -0.25, 0.25)
			else Vector(0, 0, 0.5)
		Pair.Server.Aim.Set(Value)
	end)

	Expect("frames that sent", Sent, { 1, 13 })
end)

RunClosure("A table the game changes after Set is compared as it was sent", function()
	local Pair = Fresh()
	local State = Heads(1)
	Pair.Server.Heads.Set(State)
	Expect("first frame", Frames(Pair, 1), { 1 })

	--> Changed in place. Compared against the table itself it would always equal what was sent.
	State[1].At = Vector(2, 0, 0)
	Expect("frames that sent after the change", Frames(Pair, 6), { 6 })
end)

RunClosure("Set(nil) throws and leaves the stream as it was", function()
	local Pair = Fresh()
	Pair.Server.Speed.Set(2)
	local Refused, Failure = pcall(Pair.Server.Speed.Set, nil)
	assert(not Refused, "Set(nil) was accepted")
	assert(
		string.find(tostring(Failure), 'Stream "Speed" cannot be set to nil. Call Clear to clear it.', 1, true),
		`Set(nil) failed with: {Failure}`
	)

	Expect("frames that sent", Frames(Pair, 1), { 1 })
end)

RunClosure("An interval or a keepalive a hair short of due still counts as due", function()
	--> Heartbeat's deltas are floats, so six of 1/60 can add to a hair under 0.1: without the slack the
	--> send would slip a whole frame, and ten a second would become 8.6. Stepped by hand, with times
	--> a nanosecond short of each boundary, far more than the rounding and far less than the slack.
	local Pair = Fresh()
	local function Step(Seconds: number): number
		local Before = #Pair.Outbound
		Shared.AdvanceClock(Seconds)
		Pair.Server.StepReplication()
		return #Pair.Outbound - Before
	end

	Pair.Server.Speed.Set(1)
	Expect("the first state", { Step(Support.FRAME) }, { 1 })

	--> A change, a nanosecond short of the interval: due. Then the still state after it.
	Pair.Server.Speed.Set(2)
	Expect("a change short of the interval", { Step(0.1 - 1e-9) }, { 1 })
	Expect("the still state after it", { Step(0.1) }, { 1 })

	--> Nine due steps with nothing new send nothing; the tenth, a nanosecond short of a second since
	--> the last send, is the keepalive.
	local Sent = {}
	for Index = 1, 10 do
		Sent[Index] = Step(if Index == 10 then 0.1 - 1e-9 else 0.1)
	end
	Expect("sends per step", Sent, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })

	--> And a step a millisecond short of the interval is not due.
	Pair.Server.Speed.Set(3)
	Expect("a change a millisecond short", { Step(0.099) }, { 0 })
end)

return {}
