--!strict
--- What the plugin changes in the place goes through Studio's undo history as one named step: saving
--- or deleting a schema, and generating its modules.
---
--- Without a recording, Studio folds a plugin's changes into whatever step comes next, so Ctrl+Z
--- either missed them or took the user's own edit along with them -- and a deleted schema was gone
--- for good, since `Destroy` locks an instance's Parent and no undo can put it back.
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local History = {}

--- Runs `Change` as the undo step `Name`. A change that throws is rolled back and the error raised
--- again. Outside edit mode, or while another recording is open, `Change` runs unrecorded.
function History.Record(Name: string, Change: () -> ())
	local Recording = ChangeHistoryService:TryBeginRecording(`BlinkBlox: {Name}`)
	local Success: boolean, Error: unknown = pcall(Change)
	if Recording then
		ChangeHistoryService:FinishRecording(
			Recording,
			if Success then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not Success then
		error(Error, 0)
	end
end

return History
