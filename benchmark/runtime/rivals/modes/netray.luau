--> NetRay Compile's generated runtime, from definitions/Scenarios.netray compiled by its own
--> compiler. Unlike zap's and upstream Blink's, NetRay's modules are not self-contained -- Server
--> and Client require Types beside them -- so runtime/rivals/netray is mounted into the universe and
--> the sibling resolves through script.Parent, as Rojo builds it in Studio.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../netray/Server")
end
return require("../netray/Client")
