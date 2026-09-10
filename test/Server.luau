local Shared = require("./Shared")

local Signal = Shared.Signal
local ServerEnviornment = Shared.GetEnvironment()

local function Clone(Source: buffer): buffer
	local Size = buffer.len(Source)
	local Target = buffer.create(Size)
	buffer.copy(Target, 0, Source, 0, Size)
	return Target
end

local function Fire(Reliable: boolean, ...)
	local Arguments = { ... }
	local Buffer = #Arguments == 2 and Arguments[1] or Arguments[2]
	local Instances = Arguments[#Arguments]

	Buffer = Clone(Buffer)
	Instances = table.clone(Instances)

	Shared.Bridge:Fire("Server", Reliable and "BLINK_RELIABLE_REMOTE" or "BLINK_UNRELIABLE_REMOTE", Buffer, Instances)
end

--> The generated modules assert the class of each remote before using it, so a mock that cannot
--> answer IsA is indistinguishable from the planted stand-in that assert exists to catch.
local function IsA(ClassName: string)
	return function(_self, Queried: string)
		return Queried == ClassName
	end
end

ServerEnviornment.Instances.BLINK_RELIABLE_REMOTE = {
	FireClient = function(_self, _Player, ...)
		Fire(true, ...)
	end,
	FireAllClients = function(_self, ...)
		Fire(true, ...)
	end,
	OnServerEvent = Signal.new(),
	IsA = IsA("RemoteEvent"),
}

ServerEnviornment.Instances.BLINK_UNRELIABLE_REMOTE = {
	FireClient = function(_self, _Player, ...)
		Fire(false, ...)
	end,
	FireAllClients = function(_self, ...)
		Fire(false, ...)
	end,
	OnServerEvent = Signal.new(),
	IsA = IsA("UnreliableRemoteEvent"),
}

Shared.Bridge:Connect(function(From: string, Remote: string, Buffer: buffer, Instances: { Instance })
	if From == "Server" then
		return
	end

	ServerEnviornment.Instances[Remote].OnServerEvent:Fire(Shared.Player, Buffer, Instances)
end)

return ServerEnviornment
