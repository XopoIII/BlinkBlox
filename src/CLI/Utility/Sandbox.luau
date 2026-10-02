--!strict
--- Runs a game's definitions file with a recording stub in place of the library it defines with.
---
--- A runtime library's definitions are a Luau module written for Roblox: it reaches the library
--- through `game` or `script`, and often requires a module or two of the game's own. None of that
--- exists here, so the file is run in an environment that answers for it:
---
---   - a `require` of the library -- by path, alias or Instance, whichever names it -- gets the stub;
---   - a `require` of a file that can be found beside the one requiring it is run the same way;
---   - any other `require`, and every Roblox global, gets a placeholder that can be indexed and
---     called without end, and the requires answered that way are returned for the reader to see.
---
--- The file is code and it is run. It is given no filesystem, network or process library, but the
--- command reads someone's definitions the way `require` would, and the docs say so.

---- Imports ----

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Draft = require("../../Convert/Draft")
local PathParser = require("../../Modules/Path")

---- Settings ----

--- A recording stub: the library's name as a `require` spells it, and a fresh module with the
--- function that returns what was defined through it.
export type Stub = {
	NAME: string,
	VERSION: string,
	new: () -> ({ [string]: any }, () -> Draft.Draft),
}

---- Constants ----

local Sandbox = {}

--- What a definitions file may ask whether it is running on: it is read as the server would run it.
local ANSWERS: { [string]: boolean } = { IsServer = true, IsStudio = true, IsRunning = true, IsClient = false }

--- Roblox globals a definitions file may touch on its way to the library.
local GLOBALS = {
	"game",
	"script",
	"workspace",
	"shared",
	"Enum",
	"Instance",
	"task",
	"Vector2",
	"Vector3",
	"CFrame",
	"Color3",
	"BrickColor",
	"DateTime",
	"UDim",
	"UDim2",
	"NumberRange",
	"TweenInfo",
}

---- Private Functions ----

--- The last name in a path or an alias, without its extension: `@pkg/ByteNet.luau` is `ByteNet`.
local function Leaf(Path: string): string
	local Name = string.match(Path, "([^/\\]+)$") or Path
	return (string.gsub(Name, "%.luau?$", ""))
end

--- The file `Name` means beside `Directory`, in the spellings `require` accepts.
local function Find(Directory: string, Name: string): string?
	for _, Candidate in { Name, `{Name}.luau`, `{Name}.lua`, `{Name}/init.luau`, `{Name}/init.lua` } do
		local Path = `{Directory}{Candidate}`
		if fs.isFile(Path) then
			return Path
		end
	end

	return nil
end

---- Public Functions ----

--- Runs the definitions at `Path` with `Module` standing in for the library called `Tool`. Returns
--- the names of the requires it could not follow. Raises the file and the reason when the
--- definitions themselves fail.
function Sandbox.Run(Path: string, Tool: string, Module: any): { string }
	local Unfollowed: { string } = {}
	local Names: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
	local Loaded: { [string]: any } = {}
	local Load: (File: string) -> any

	--- A value that is whatever it is asked to be: any field of it and any call of it is another.
	local function Placeholder(Name: string): any
		local Self = setmetatable({}, {
			__index = function(_, Key: any)
				return Placeholder(tostring(Key))
			end,
			__newindex = function() end,
			__call = function(_, First: any, Second: any): any
				if ANSWERS[Name] ~= nil then
					return ANSWERS[Name]
				end

				--> `GetService("Players")`, `WaitForChild("ByteNet")`: the string is what it returns.
				local Asked = if type(Second) == "string" then Second elseif type(First) == "string" then First else nil
				return Placeholder(Asked or Name)
			end,
			__iter = function()
				return next, {}
			end,
			__len = function()
				return 0
			end,
			__tostring = function()
				return Name
			end,
		})

		Names[Self] = Name
		return Self
	end

	local function Environment(Directory: string): { [string]: any }
		local Globals: { [string]: any } = { _G = {}, print = function() end, warn = function() end }
		for _, Name in GLOBALS do
			Globals[Name] = Placeholder(Name)
		end

		function Globals.require(Target: any): any
			local Name = if type(Target) == "string" then Leaf(Target) else Names[Target]
			if Name and string.lower(Name) == string.lower(Tool) then
				return Module
			end

			--> A path is looked up as written; an Instance only has a name, so its file is looked for
			--> beside the one requiring it, where a module's siblings are kept.
			local File = if type(Target) == "string"
				then Find(Directory, Target)
				elseif Name then Find(Directory, Name)
				else nil
			if File then
				return Load(File)
			end

			table.insert(Unfollowed, Name or tostring(Target))
			return Placeholder(Name or "module")
		end

		return Globals
	end

	function Load(File: string): any
		local Key = PathParser.Normalise(File)
		if Loaded[Key] ~= nil then
			return Loaded[Key]
		end

		--> Two files that require each other get a placeholder for the one still loading.
		Loaded[Key] = Placeholder(Leaf(File))

		local Chunk = luau.load(fs.readFile(File), {
			debugName = Key,
			environment = Environment(PathParser.Directory(File) or "./"),
		})
		local Success, Result = pcall(Chunk)
		if not Success then
			error(`{Key}: {Result}`, 0)
		end

		if Result ~= nil then
			Loaded[Key] = Result
		end
		return Loaded[Key]
	end

	Load(Path)
	return Unfollowed
end

--- The draft of what the definitions at `Path` define, recorded by `Stub`: one of src/Convert/Stubs.
--- Each require that could not be followed is noted in it.
function Sandbox.Record(Path: string, Stub: Stub): Draft.Draft
	local Module, Collect = Stub.new()
	local Unfollowed = Sandbox.Run(Path, Stub.NAME, Module)

	local Into = Collect()
	for _, Name in Unfollowed do
		table.insert(Into.Notes, {
			Severity = "Dropped",
			Message = `require of {Name} was not followed: a placeholder stood in for it, `
				.. "so anything the definitions took from it is missing",
		})
	end

	return Into
end

---- Initialization ----

---- Connections ----

return Sandbox
