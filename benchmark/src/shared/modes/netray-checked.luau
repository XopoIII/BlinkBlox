--> NetRay Compile with `Validate = Full`, receive budgets and Snapshot's delta compression on: the
--> other configuration, from definitions/Definition.netray.checked.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../netray-checked/Server")
elseif RunService:IsClient() then
	return require("../netray-checked/Client")
end
