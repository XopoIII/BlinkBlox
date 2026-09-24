--!strict
--- Generating a schema into the place: the three modules written into a `Blink` folder, and the
--- destination remembered between sessions.
---
--- Split out of init.server.luau. Nothing here reaches for `plugin` or `script` itself: the plugin
--- and the instance the permission probe is parented to are passed in, since only the root script
--- has them.
local ScriptEditorService = game:GetService("ScriptEditorService")

local Attributes = require("@compiler/Modules/Attributes")
local Generator = require("@compiler/Generator")
local Parser = require("@compiler/Parser")

local Output = {}

--- Writes a generated module, reusing the one already there.
---
--- This used to create a fresh ModuleScript every time, after ClearAllChildren had destroyed the old
--- one. Everything that referred to the previous instance therefore broke on every regeneration: an
--- ObjectValue pointing at it went nil, an open script tab closed, a breakpoint was lost, and
--- anything keyed on the instance stopped matching. The path-based `require` survived only because
--- the names and the parent folder happened to stay the same.
local function WriteModuleScript(Name: string, Source: string, Parent: Instance)
	local Existing = Parent:FindFirstChild(Name)
	local ModuleScript = if Existing and Existing:IsA("ModuleScript") then Existing else nil

	if not ModuleScript then
		--> Something of another class is sitting on the name. Replacing it is the only way forward,
		--> but it is worth saying so rather than silently destroying whatever it was.
		if Existing then
			warn(`[BLINK]: Replacing a {Existing.ClassName} named "{Name}" in the Blink folder.`)
			Existing:Destroy()
		end

		local Created = Instance.new("ModuleScript")
		Created.Name = Name
		Created.Parent = Parent
		ModuleScript = Created
	end

	--> Source is set after parenting: UpdateSourceAsync works on a document, and an unparented
	--> instance has none. It is used rather than `.Source` because assigning Source refuses anything
	--> at or past 200000 characters, which a large schema passes easily.
	ScriptEditorService:UpdateSourceAsync(ModuleScript :: ModuleScript, function()
		return Source
	end)
end

--- Whether the plugin may create scripts, found out by trying: a Script parented to `Probe` and
--- destroyed at once.
local function RequestScriptPermissions(Probe: Instance): boolean
	local Success = pcall(function()
		-- Parenting through `Instance.new`'s second argument is deprecated; assigning `.Parent`
		-- afterwards is the supported form and keeps the permission probe identical.
		local Script = Instance.new("Script")
		Script.Parent = Probe
		Script:Destroy()
	end)

	return Success
end

--- Compiles `File` and writes its three modules into a `Blink` folder under `Directory`. A failure
--- is handed to `Report` rather than raised, since this runs from a button.
function Output.Generate(File: StringValue, Directory: Instance, Probe: Instance, Report: (Error: string) -> ())
	local Source = File.Value

	--> What `@profile` compiles under is read from a `Profile` attribute on the schema itself, which
	--> the Properties panel can set -- a plugin setting would need a picker nothing has built. Absent,
	--> it is release, as on the command line.
	local Profile = File:GetAttribute("Profile")
	if Profile ~= nil and (type(Profile) ~= "string" or not Attributes.IsProfile(Profile)) then
		Report(`Unknown profile "{Profile}" on {File.Name}: expected dev, debug, test or release.`)
		return
	end

	local SourceParser = Parser.new(nil, nil, nil, Attributes.new(Profile :: string?))
	local Success, Error, AbstractSyntaxTree = pcall(function()
		return nil, SourceParser:Parse(Source)
	end)

	if not Success then
		Report(tostring(Error))
		return
	end

	if not RequestScriptPermissions(Probe) then
		Report("File generation failed, plugin doesn't have script inject permissions.")
		warn("[BLINK]: File generation failed, plugin doesn't have script inject permissions.")
		return
	end

	local ServerSource = Generator.Generate("Server", AbstractSyntaxTree)
	local ClientSource = Generator.Generate("Client", AbstractSyntaxTree)
	local TypesSource = Generator.GenerateShared(AbstractSyntaxTree)

	local BlinkFolder: Folder = Directory:FindFirstChild("Blink") :: Folder
	if not BlinkFolder then
		local Folder = Instance.new("Folder")
		Folder.Name = "Blink"
		Folder.Parent = Directory
		BlinkFolder = Folder
	end

	--> The three generated modules are overwritten in place. Nothing else in the folder is touched.
	-->
	--> This used to be `BlinkFolder:ClearAllChildren()`, which deleted whatever else the user had put
	--> there -- a wrapper module, a configuration script, anything -- with no warning and no undo
	--> beyond Ctrl+Z. Blink owns these three names; it does not own the folder.
	WriteModuleScript("Types", TypesSource, BlinkFolder)
	WriteModuleScript("Server", ServerSource, BlinkFolder)
	WriteModuleScript("Client", ClientSource, BlinkFolder)
end

--- Where the last generation went, so it does not have to be picked out of the Explorer every time.
---
--- Stored as the full name rather than the instance, because a plugin setting has to survive being
--- written to disk. The cost is that an instance renamed between sessions is not found, which is
--- exactly the case where silently generating into the old place would be worse.
local OUTPUT_SETTING = "OutputLocation"

function Output.Remember(Plugin: Plugin, Directory: Instance)
	Plugin:SetSetting(OUTPUT_SETTING, Directory:GetFullName())
end

function Output.Recall(Plugin: Plugin): Instance?
	local Path = Plugin:GetSetting(OUTPUT_SETTING)
	if type(Path) ~= "string" then
		return nil
	end

	local Segments = string.split(Path, ".")
	local Service = table.remove(Segments, 1)
	if not Service then
		return nil
	end

	--> A service that no longer exists, or a name with a dot in it, lands here. Returning nil is the
	--> right answer to both: the user picks again.
	local Found = (pcall(game.GetService, game, Service)) and game:GetService(Service :: any) or nil
	for _, Segment in Segments do
		if not Found then
			return nil
		end

		Found = Found:FindFirstChild(Segment)
	end

	return Found
end

return Output
