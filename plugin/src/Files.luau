--!strict
--- The schemas the plugin keeps in the place: one StringValue per file in a folder in ServerStorage,
--- and the template a new place starts with.
---
--- Split out of init.server.luau; the list the side panel draws from these stays there.
local ServerStorage = game:GetService("ServerStorage")

local History = require("./History")

local FILES_FOLDER = "BLINK_CONFIGURATION_FILES"
local TEMPLATE_FILE = {
	Name = "Template",
	Source = table.concat({
		"type Example = u8",
		"event MyEvent {",
		"\tFrom: Server,",
		"\tType: Reliable,",
		"\tCall: SingleSync,",
		"\tData: Example",
		"}",
	}, "\n"),
}

local Files = {}

--- The folder the files live in, created the first time it is asked for.
function Files.Folder(): Folder
	local SaveFolder = ServerStorage:FindFirstChild(FILES_FOLDER)
	if not SaveFolder then
		local Folder = Instance.new("Folder")
		Folder.Name = FILES_FOLDER
		Folder.Parent = ServerStorage
		SaveFolder = Folder
	end

	return SaveFolder
end

--- Writes `Source` under `Name`, replacing a file of that name. One undo step.
function Files.Save(Name: string, Source: string)
	History.Record(`Save {Name}`, function()
		local SaveFolder = Files.Folder()
		local SaveInstance: StringValue? = SaveFolder:FindFirstChild(Name) :: StringValue
		if not SaveInstance then
			local NewSaveInstance = Instance.new("StringValue")
			NewSaveInstance.Name = Name
			NewSaveInstance.Value = Source
			NewSaveInstance.Parent = SaveFolder
			return
		end

		SaveInstance.Value = Source
	end)
end

--- Takes `File` out of the folder, as one undo step. Unparented rather than destroyed, so the step
--- can be undone.
function Files.Delete(File: StringValue)
	History.Record(`Delete {File.Name}`, function()
		File.Parent = nil
	end)
end

--- In a place that has never had the folder, saves the template and returns it to be opened. In one
--- that has, returns nil: an emptied folder is the user's choice, and it is not refilled.
function Files.CreateTemplate(): StringValue?
	if ServerStorage:FindFirstChild(FILES_FOLDER) then
		return nil
	end

	Files.Save(TEMPLATE_FILE.Name, TEMPLATE_FILE.Source)
	return Files.Folder():FindFirstChild(TEMPLATE_FILE.Name) :: StringValue
end

return Files
