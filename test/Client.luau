--!strict
local Shared = require("./Shared")

local Signal = Shared.Signal
local ClientEnviornment = Shared.GetEnvironment()

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

	Shared.Bridge:Fire("Client", Reliable and "BLINK_RELIABLE_REMOTE" or "BLINK_UNRELIABLE_REMOTE", Buffer, Instances)
end

--> The generated modules assert the class of each remote before using it, so a mock that cannot
--> answer IsA is indistinguishable from the planted stand-in that assert exists to catch.
local function IsA(ClassName: string)
	return function(_self, Queried: string)
		return Queried == ClassName
	end
end

local SetBLINK_RELIABLE_REMOTE, GetBLINK_RELIABLE_REMOTE = Shared.AttributeMethods("BLINK_RELIABLE_REMOTE")
ClientEnviornment.Instances.BLINK_RELIABLE_REMOTE = {
	SetAttribute = SetBLINK_RELIABLE_REMOTE,
	GetAttribute = GetBLINK_RELIABLE_REMOTE,
	FireServer = function(_self, ...)
		Fire(true, ...)
	end,
	OnClientEvent = Signal.new(),
	IsA = IsA("RemoteEvent"),
}

local SetBLINK_UNRELIABLE_REMOTE, GetBLINK_UNRELIABLE_REMOTE = Shared.AttributeMethods("BLINK_UNRELIABLE_REMOTE")
ClientEnviornment.Instances.BLINK_UNRELIABLE_REMOTE = {
	SetAttribute = SetBLINK_UNRELIABLE_REMOTE,
	GetAttribute = GetBLINK_UNRELIABLE_REMOTE,
	FireServer = function(_self, ...)
		Fire(false, ...)
	end,
	OnClientEvent = Signal.new(),
	IsA = IsA("UnreliableRemoteEvent"),
}

Shared.Bridge:Connect(function(From: string, Remote: string, Buffer: buffer, Instances: { Instance })
	if From == "Client" then
		return
	end

	for Index, Value in Instances do
		if Value == Shared.ServerOnlyInstance then
			Instances[Index] = nil
		end
	end

	ClientEnviornment.Instances[Remote].OnClientEvent:Fire(Buffer, Instances)
end)

return ClientEnviornment
