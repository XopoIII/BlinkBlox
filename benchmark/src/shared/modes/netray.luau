--> NetRay Compile, an IDL compiler in BlinkBlox's own category. Its definition is
--> definitions/Definition.netray, compiled by NetRay's own compiler into ../netray, whose three
--> modules require each other as siblings.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../netray/Server")
elseif RunService:IsClient() then
	return require("../netray/Client")
end
