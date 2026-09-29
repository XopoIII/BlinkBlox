--!strict
--- A game's code, as it uses the generated modules: every line here must type-check clean, under the
--- old solver and the new one. Checked by scripts/type-check.sh; nothing runs it.
---
--- Test.blink's modules are the largest the tests make, past the size where the new solver gives up
--- inferring a module (see Generator/Returns.luau), so they are the ones that prove the types still
--- reach the code that requires them.
local Players = game:GetService("Players")
local Player = Players:GetPlayers()[1]

local Client = require("../Golden/Test/Client")
local Server = require("../Golden/Test/Server")
local Showroom = require("../Golden/Showroom/ShowroomServer")

Server.ReliableServer.Fire(Player, 5)
Server.ReliableServer.FireAll(5)
Server.ReliableClient.On(function(From: Player, Value: number)
	print(From, Value + 1)
end)
Server.RemoteFunction.On(function(From: Player, Value: number): number
	print(From)
	return Value * 2
end)

Client.ReliableClient.Fire(5)
Client.ReliableServer.On(function(Value: number)
	print(Value + 1)
end)
local Doubled: number = Client.RemoteFunction.Invoke(3)
print(Doubled)

Showroom.Announce.fire(Player, "hello")
Showroom.Ready.on(function(From: Player, Value: number)
	print(From, Value)
end)
local Confirmed: boolean = Showroom.Confirm.invoke(Player, 1)
print(Confirmed)
