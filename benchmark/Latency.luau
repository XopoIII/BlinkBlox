--!strict
--- Measures when an unreliable event fired from the client arrives, by how it is sent, in Studio. Run
--- from this directory:
---
---     luneblox run Latency
---
--- Builds latency/ into Latency.rbxl and opens it through run-in-roblox; press F5 when Studio asks, as
--- for the benchmark. The client fires four events a frame early in the frame (RenderStepped) or late
--- (Heartbeat, after the flush), sent at once, gathered for a Heartbeat flush as `BatchUnreliable`
--- does, or gathered for a `task.defer`. Prints each mode's median and 90th percentile time from fire
--- to arrival and the remote calls it made. See latency/Client.client.luau.
local process = require("@lune/process")
local serde = require("@lune/serde")

local function Step(Program: string, Arguments: { string }): process.ExecResult
	print(`> {Program} {table.concat(Arguments, " ")}`)
	local Result = process.exec(Program, Arguments)
	if not Result.ok then
		error(`{Program} failed: {Result.stderr}`, 0)
	end
	return Result
end

Step("rojo", { "build", "latency/latency.project.json", "--output", "Latency.rbxl" })
local Run = Step("run-in-roblox", { "--place", "Latency.rbxl", "--script", "run.luau" })

local Json: string? = nil
local Output = string.split(Run.stdout, "--RESULTS JSON--")
for Index = 2, #Output do
	local Line = string.gsub(Output[Index], "\n", "")
	if string.sub(Line, 1, 1) == "[" then
		Json = Line
		break
	end
end

assert(Json, "The probe printed no result")
print("|Mode|Fired|Arrived|Remote calls|Median ms|P90 ms|")
print("|---|---|---|---|---|---|")
for _, Row in serde.decode("json", Json) do
	print(string.format("|%s|%d|%d|%d|%.2f|%.2f|", Row.Mode, Row.Fired, Row.Arrived, Row.Calls, Row.Median, Row.P90))
end
