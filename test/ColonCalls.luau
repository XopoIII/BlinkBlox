--!strict
--- A send called with ':' names what went wrong.
---
--- `Net.Event:Fire(Player, Value)` passes the event's own table first. On the server that table was
--- taken for the player and failed as "attempt to call a nil value" inside the module; on the client
--- it was taken for the value. Upstream's thread met it as a bare `writeu8` error. Both say what to do
--- now, from the paths that run only once the call has already failed.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
option WriteValidations = true
event Down { From: Server, Type: Reliable, Call: ManySync, Data: u8 }
event Up { From: Client, Type: Reliable, Call: ManySync, Data: u8 }
]]

local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "COLONCALLS")

RunClosure("A server send called with ':' says so", function()
	local Event: any = Pair.Server.Down
	local Sent, Failure = pcall(function()
		Event:Fire(Shared.Player, 1)
	end)
	if Sent or not string.find(tostring(Failure), "with ':'", 1, true) then
		ErrorPrint(`a ':' call on the server failed with "{Failure}"`)
	end
end)

RunClosure("A server send called with ':' says so where nothing checks its value", function()
	--> Without WriteValidations nothing looks at the value, and an event with none takes the shifted
	--> arguments without complaint: the table taken for the player reaches the batch, where it is
	--> named. (With a value, the write of the Player it now holds fails first, in `buffer`.)
	local Plain =
		Isolated.Build(Isolated.Parse("event Ping { From: Server, Type: Reliable, Call: ManySync }"), "COLONPLAIN")
	local Event: any = Plain.Server.Ping
	local Sent, Failure = pcall(function()
		Event:Fire(Shared.Player)
	end)
	if Sent or not string.find(tostring(Failure), "not with ':'", 1, true) then
		ErrorPrint(`a ':' call on a server without validations failed with "{Failure}"`)
	end
end)

RunClosure("A client send called with ':' says so", function()
	local Event: any = Pair.Client.Up
	local Sent, Failure = pcall(function()
		Event:Fire(1)
	end)
	if Sent or not string.find(tostring(Failure), "with ':'", 1, true) then
		ErrorPrint(`a ':' call on the client failed with "{Failure}"`)
	end
end)

return {}
