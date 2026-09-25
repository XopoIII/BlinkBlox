--!strict
--- Measures how large a buffer an UnreliableRemoteEvent carries, in Studio. Run from this directory:
---
---     lune run Probe
---
--- Builds probe/ into Probe.rbxl and opens it through run-in-roblox; press F5 when Studio asks, as for
--- the benchmark. Prints, for each direction and each number of Instances sent beside the buffer, the
--- largest buffer that arrived and the smallest that did not, and Studio's own messages about the
--- events it dropped. `MaxUnreliableSize` should sit at or below the largest buffer that arrived with
--- no Instances, in both directions. See probe/Common.luau for why this has to be measured.
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

Step("rojo", { "build", "probe/probe.project.json", "--output", "Probe.rbxl" })
local Run = Step("run-in-roblox", { "--place", "Probe.rbxl", "--script", "run.luau" })

local Json: string? = nil
local Output = string.split(Run.stdout, "--RESULTS JSON--")
for Index = 2, #Output do
	local Line = string.gsub(Output[Index], "\n", "")
	if string.sub(Line, 1, 1) == "{" then
		Json = Line
		break
	end
end

assert(Json, "The probe printed no result")
local Result = serde.decode("json", Json)

local function Show(Direction: string, Series: { any })
	print(`\n{Direction}`)
	print("|Instances|Largest delivered|Smallest dropped|Encoding cost|")
	print("|---|---|---|---|")
	for _, Row in Series do
		local Largest = Row.LargestDelivered
		local Cost = if Largest then tostring(Result.PayloadLimit - Largest) else "-"
		print(`|{Row.Instances}|{Largest or "-"}|{Row.SmallestDropped or "-"}|{Cost}|`)
	end
end

Show("Client to server", Result.ClientToServer)
Show("Server to client", Result.ServerToClient)

print("\nStudio said:")
for _, Message in Result.ServerLogs do
	print(`  server: {Message}`)
end
for _, Message in Result.ClientLogs do
	print(`  client: {Message}`)
end
