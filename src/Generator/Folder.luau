--!strict
--- `option RemotesFolder`: the two remotes live in a folder of that name in ReplicatedStorage, rather
--- than beside everything else there. The server makes the folder when it is missing; the client waits
--- for the folder, then for the remotes inside it.
---
--- Applied to the runtime templates' text only when the option is set, so a schema without it
--- compiles to what it always did. Every replacement must match the number of times it is expected
--- to, or generation stops: a template edited without this file would otherwise go on looking in
--- ReplicatedStorage while the server put the remotes in the folder.
local Parser = require("../Parser")

local Folder = {}

local SERVER_FOLDER = [[
local RemoteContainer: Instance = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER) or (function(): Instance
    local Created = Instance.new("Folder")
    Created.Name = REMOTES_FOLDER
    Created.Archivable = false
    Created.Parent = ReplicatedStorage
    return Created
end)()
]]

local function Replace(Text: string, From: string, To: string, Expected: number): string
	local Replaced, Count = string.gsub(Text, From, (string.gsub(To, "%%", "%%%%")))
	assert(Count == Expected, `RemotesFolder: expected {Expected} of "{From}" in the template, found {Count}.`)
	return Replaced
end

--- Whether this build puts its remotes in a folder.
function Folder.Used(Options: Parser.Options): boolean
	return Options.RemotesFolder ~= nil
end

--- The server's remote lookup, making and searching the folder instead of ReplicatedStorage.
function Folder.Server(Lookup: string, Options: Parser.Options): string
	if not Folder.Used(Options) then
		return Lookup
	end

	Lookup = Replace(
		Lookup,
		"ReplicatedStorage:FindFirstChild%(BASE_EVENT_NAME",
		"RemoteContainer:FindFirstChild(BASE_EVENT_NAME",
		2
	)
	Lookup = Replace(Lookup, "%.Parent = ReplicatedStorage\n", ".Parent = RemoteContainer\n", 2)
	return SERVER_FOLDER .. Lookup
end

--- The client's unbounded lookup: the folder through the same patient wait as the remote.
function Folder.Client(Lookup: string, Options: Parser.Options): string
	if not Folder.Used(Options) then
		return Lookup
	end

	Lookup = Replace(
		Lookup,
		"local Reliable: RemoteEvent = Await%(ReplicatedStorage, ",
		"local RemoteContainer = Await(ReplicatedStorage, REMOTES_FOLDER)\nlocal Reliable: RemoteEvent = Await(RemoteContainer, ",
		1
	)
	return Replace(
		Lookup,
		"ReplicatedStorage:WaitForChild%(BASE_EVENT_NAME",
		"RemoteContainer:WaitForChild(BASE_EVENT_NAME",
		1
	)
end

--- The client's bounded lookup (Templates/Connect): the folder first, then both remotes, all within
--- the one CONNECT_TIMEOUT.
function Folder.Connect(Connect: string, Options: Parser.Options): string
	if not Folder.Used(Options) then
		return Connect
	end

	Connect = Replace(
		Connect,
		"ConnectedReliable = ReplicatedStorage:WaitForChild%(REMOTE_NAMES%.Reliable, CONNECT_TIMEOUT%)",
		table.concat({
			"local Container = ReplicatedStorage:WaitForChild(REMOTES_FOLDER, CONNECT_TIMEOUT)",
			"    if Container == nil then",
			"        return false",
			"    end",
			"    ConnectedReliable = Container:WaitForChild(REMOTE_NAMES.Reliable, math.max(Deadline - os.clock(), 0))",
		}, "\n"),
		1
	)
	Connect = Replace(
		Connect,
		"ReplicatedStorage:WaitForChild%(REMOTE_NAMES%.Unreliable",
		"Container:WaitForChild(REMOTE_NAMES.Unreliable",
		1
	)
	return Replace(
		Connect,
		"ReplicatedStorage:FindFirstChild%(REMOTE_NAMES%.Unreliable",
		"Container:FindFirstChild(REMOTE_NAMES.Unreliable",
		1
	)
end

return Folder
