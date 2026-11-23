--> NetRay Compile with the checks and the compression it ships off by default, from
--> definitions/Scenarios.netray.checked. See netray.luau, whose shape this is.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../netray-checked/Server")
end
return require("../netray-checked/Client")
