--> NetRay Compile with the field-mask compression, from definitions/Scenarios.netray.fields. See
--> netray-checked.luau, whose shape this is.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../netray-fields/Server")
end
return require("../netray-fields/Client")
