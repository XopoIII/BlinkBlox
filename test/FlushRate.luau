--!strict
--- Specs for `option ClientFlushRate`: the client's Heartbeat sends at most that many times a second,
--- and every frame at or below it. Runs the lines the generator emits against a stand-in Heartbeat,
--- one simulated second at a time.
local Assertions = require("./Assertions")
local Fragments = require("@compiler/Generator/Fragments")
local luau = require("@lune/luau")

local RunClosure = Assertions.RunClosure

--- Flushes counted over one second of Heartbeats at `FramesPerSecond`, each frame's delta jittered by
--- up to `Jitter` of the interval, alternately early and late.
local function Flushes(Options: { ClientFlushRate: number? }, FramesPerSecond: number, Jitter: number): number
	local Handler: ((number) -> ())? = nil
	local Count = 0
	local Environment = {
		RunService = {
			Heartbeat = {
				Connect = function(_self, Callback: (number) -> ())
					Handler = Callback
				end,
			},
		},
		StepReplication = function()
			Count += 1
		end,
		math = math,
	}

	local Source = table.concat(Fragments.Heartbeat("Client", Options), "\n")
	luau.load(Source, { environment = Environment })()
	local Step = assert(Handler, "the client never connected its Heartbeat")

	local Frame = 1 / FramesPerSecond
	for Index = 1, FramesPerSecond do
		local Sign = if Index % 2 == 0 then 1 else -1
		Step(Frame * (1 + Sign * Jitter))
	end

	return Count
end

RunClosure("A client at or below the flush rate sends every frame", function()
	for _, Rate in { 30, 60 } do
		local Count = Flushes({}, Rate, 0.05)
		assert(Count == Rate, `{Rate} frames a second sent {Count} times, expected every frame`)
	end
end)

RunClosure("A client above the flush rate sends at most that often", function()
	for _, Rate in { 144, 240, 500 } do
		local Count = Flushes({}, Rate, 0.05)
		assert(Count >= 58 and Count <= 61, `{Rate} frames a second sent {Count} times, expected about 60`)
	end

	local Count = Flushes({ ClientFlushRate = 120 }, 240, 0)
	assert(Count >= 118 and Count <= 121, `ClientFlushRate = 120 at 240 frames sent {Count} times`)
end)

RunClosure("The server's Heartbeat is not rate limited", function()
	local Lines = Fragments.Heartbeat("Server", {})
	assert(
		#Lines == 1 and Lines[1] == "RunService.Heartbeat:Connect(StepReplication)",
		"the server's Heartbeat changed"
	)
end)
