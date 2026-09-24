--!strict
--- Specs for ordered unreliable events across the sequence wrap and across players.
---
--- The sequence is a u16. Deciding which of two numbers is newer has to survive the counter going
--- round, and on the server it has to be counted per player: a player left out of sends must not be
--- told that everything after them is stale.
local Assertions = require("./Assertions")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local Client = Modules.Client
local Server = Modules.Server
local RunClosure = Assertions.RunClosure

--> [event index][u16 sequence][u8 value], the shape of an ordered u8 event.
local function Packet(Index: number, Sequence: number, Value: number): buffer
	local Built = buffer.create(4)
	buffer.writeu8(Built, 0, Index)
	buffer.writeu16(Built, 1, Sequence)
	buffer.writeu8(Built, 3, Value)
	return Built
end

RunClosure("An ordered packet from before the wrap is stale after it", function()
	--> The event's index, from a packet the client really sends.
	local Remote = ClientEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	local Original = Remote.FireServer
	local Captured: buffer?
	Remote.FireServer = function(_self, Buffer: buffer)
		Captured = Buffer
	end
	Client.OrderedPosition.Fire(1)
	Remote.FireServer = Original
	assert(Captured, "no ordered packet was sent to take the index from")
	local Index = buffer.readu8(Captured, 0)

	--> A fresh start for the mock player, as if they had just joined. Leaving has to clear what the
	--> server remembers of their sequence, or it would be held against whoever joins next.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)
	task.wait(1 / 30)

	local Received: { number } = {}
	local Disconnect = Server.OrderedPosition.On(function(_Player, Value: number)
		table.insert(Received, Value)
	end)

	local ServerRemote = ServerEnvironment.Instances.BLINK_UNRELIABLE_REMOTE
	--> 65534, then 1 -- three sends later, across the wrap -- then 65530, sent before both.
	ServerRemote.OnServerEvent:Fire(Shared.Player, Packet(Index, 65534, 1), {})
	ServerRemote.OnServerEvent:Fire(Shared.Player, Packet(Index, 1, 2), {})
	ServerRemote.OnServerEvent:Fire(Shared.Player, Packet(Index, 65530, 3), {})
	task.wait(1 / 30)
	Disconnect()

	assert(
		#Received == 2 and Received[1] == 1 and Received[2] == 2,
		`received {table.concat(Received, ", ")}, expected 1 and 2 only`
	)
end)

RunClosure("A player left out of many ordered sends still receives the next", function()
	local Received: { number } = {}
	local Disconnect = Client.OrderedToClient.On(function(Value: number)
		table.insert(Received, Value)
	end)

	--> Fifty packets the mock player does receive, so the last sequence it saw is well above zero.
	for Value = 1, 50 do
		Server.OrderedToClient.Fire(Shared.Player, Value)
	end
	task.wait(1 / 30)

	--> Sends that reach nobody. With one counter for every player, these moved the mock player's next
	--> number to just BELOW the last one it saw, and that packet was refused as stale.
	for _ = 1, 65536 - 10 do
		Server.OrderedToClient.FireList({}, 0)
	end

	Server.OrderedToClient.Fire(Shared.Player, 200)
	task.wait(1 / 30)
	Disconnect()
	Shared.DrainWarnings()

	assert(
		#Received == 51 and Received[51] == 200,
		`received {#Received} packet(s) ending in {tostring(Received[#Received])}, expected 51 ending in 200`
	)
end)

return {}
