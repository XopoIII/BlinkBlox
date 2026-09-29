--!strict
--- A game's code getting the generated modules wrong: every line marked `-- type error` must be
--- reported, under the old solver and the new one, and nothing else may be. A module whose types
--- collapsed into `any` would let all of them through. Checked by scripts/type-check.sh.
local Players = game:GetService("Players")
local Player = Players:GetPlayers()[1]

local Client = require("../Golden/Test/Client")
local Server = require("../Golden/Test/Server")
local Showroom = require("../Golden/Showroom/ShowroomServer")

Server.ReliableServer.Fire(Player, "five") -- type error
Client.ReliableClient.Fire("five") -- type error
local Wrong: string = Client.RemoteFunction.Invoke(3) -- type error
Showroom.Announce.fire(Player, 5) -- type error
local AlsoWrong: string = Showroom.Confirm.invoke(Player, 1) -- type error
print(Wrong, AlsoWrong)
