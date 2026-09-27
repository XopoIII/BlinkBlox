local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../zap/Server")
end
return require("../zap/Client")
