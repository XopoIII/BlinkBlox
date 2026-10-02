--!strict
--- The bridge each "Coming from" guide prints, run against real generated modules.
---
--- A guide offers a short wrapper that gives a BlinkBlox module another tool's call names, for a
--- game to paste in while its call sites move. Nothing else runs that code, and a wrapper that does
--- not work is worse than none: it is the first thing a migrating game leans on. So the fence marked
--- `bridge` is taken out of the page and driven here through the other tool's names, on a server and
--- client built from a schema of its own.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Shared = require("./Shared")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local GUIDES = "../docs/src/content/docs/guides"

local SCHEMA = [[
event Equip {
	From: Client,
	Type: Reliable,
	Call: SingleSync,
	Rate: 100,
	Data: (slot: u8, name: string(..16))
}

scope Shop {
	event Stock {
		From: Server,
		Type: Reliable,
		Call: ManySync,
		Data: u16
	}
}
]]

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

--- The body of the page's fence marked `bridge`.
local function Bridge(Page: string): string
	local Lines = string.split(fs.readFile(`{GUIDES}/{Page}.mdx`), "\n")
	local Body: { string } = {}
	local IsInside = false

	for _, Line in Lines do
		if IsInside and string.match(Line, "^```%s*$") then
			return table.concat(Body, "\n")
		elseif IsInside then
			table.insert(Body, Line)
		elseif string.match(Line, "^```luau%s") and string.find(Line, " bridge", 1, true) then
			IsInside = true
		end
	end

	return ErrorPrint(`{Page}.mdx has no fence marked "bridge".`) :: any
end

--- Carries what each side has batched to the other, as the remotes would.
local function Exchange(Pair: Isolated.Pair)
	Pair.Client.StepReplication()
	for _, Packet in Pair.Sent do
		Pair.Feed(true, Packet.Buffer, Packet.Instances)
	end
	table.clear(Pair.Sent)

	Pair.Server.StepReplication()
	for _, Packet in Pair.Delivered do
		Pair.FeedClient(true, Packet.Buffer, Packet.Instances)
	end
	table.clear(Pair.Delivered)
end

RunClosure("The zap guide's bridge answers to zap's names", function()
	local ZapNames = luau.load(Bridge("coming-from-zap"))()
	local Pair = Isolated.Build(Isolated.Parse(SCHEMA), "BRIDGEZAP")
	local Server, Client = ZapNames(Pair.Server), ZapNames(Pair.Client)

	local Heard: { any } = {}
	Server.Equip.SetCallback(function(Player, Slot, Name)
		Heard = { Player, Slot, Name }
	end)

	local Stock: number?
	Client.Shop.Stock.On(function(Value)
		Stock = Value
	end)

	Client.Equip.Fire(3, "sword")
	Server.Shop.Stock.FireSet({ [Shared.Player] = true }, 512)
	Exchange(Pair)
	--> SendEvents is the same step under zap's name.
	Check("SendEvents", Server.SendEvents == Pair.Server.StepReplication, "SendEvents is not StepReplication")

	Check(
		"SetCallback",
		Heard[1] == Shared.Player and Heard[2] == 3 and Heard[3] == "sword",
		"the listener heard nothing"
	)
	Check("FireSet", Stock == 512, `the client heard {Stock}`)
	Check("Fire", Server.Shop.Stock.Fire == Pair.Server.Shop.Stock.Fire, "the module's own names are gone")
end)

--> ByteNet's packets carry one value and name the player last, so the schema's events do too and
--> the bridge has to turn each call around.
local ONE_VALUE = [[
event Equip {
	From: Client,
	Type: Reliable,
	Call: ManyAsync,
	Rate: 100,
	Data: struct { slot: u8, name: string(..16) }
}

scope Shop {
	event Stock {
		From: Server,
		Type: Reliable,
		Call: ManyAsync,
		Data: u16
	}
}
]]

RunClosure("The ByteNet guide's bridge answers to ByteNet's names and argument order", function()
	local ByteNetNames = luau.load(Bridge("coming-from-bytenet"))()
	local Pair = Isolated.Build(Isolated.Parse(ONE_VALUE), "BRIDGEBYTENET")
	local Server, Client = ByteNetNames(Pair.Server, true), ByteNetNames(Pair.Client, false)

	local Heard: { any } = {}
	Server.Equip.listen(function(Data, Player)
		Heard = { Data.slot, Data.name, Player }
	end)

	local Stock: { number } = {}
	Client.Shop.Stock.listen(function(Value)
		table.insert(Stock, Value)
	end)

	Client.Equip.send({ slot = 3, name = "sword" })
	Server.Shop.Stock.sendTo(1, Shared.Player)
	Server.Shop.Stock.sendToList(2, { Shared.Player })
	Exchange(Pair)

	Check("listen", Heard[1] == 3 and Heard[2] == "sword" and Heard[3] == Shared.Player, "the server heard nothing")
	Check("sendTo", Stock[1] == 1 and Stock[2] == 2, `the client heard {table.concat(Stock, ", ")}`)
	--> An event has the members of its direction only: the schema decided, where ByteNet did not.
	Check("Direction", Server.Equip.sendTo == nil and Client.Shop.Stock.send == nil, "a send the schema forbids exists")
end)

--> Packet's packets carry several values by position, and one with a response is a function.
local SEVERAL_VALUES = [[
event Equip {
	From: Client,
	Type: Reliable,
	Call: ManyAsync,
	Rate: 100,
	Data: (u8, string(..16))
}

event Stock {
	From: Server,
	Type: Reliable,
	Call: ManyAsync,
	Data: u16
}

function Price {
	Yield: Coroutine,
	Rate: 100,
	Data: u16,
	Return: u32
}
]]

RunClosure("The Packet guide's bridge answers to Packet's methods, signals and invokes", function()
	local PacketNames = luau.load(Bridge("coming-from-packet"))()
	local Pair = Isolated.Build(Isolated.Parse(SEVERAL_VALUES), "BRIDGEPACKET")
	local Server, Client = PacketNames(Pair.Server, true), PacketNames(Pair.Client, false)

	local Heard: { any } = {}
	local Connection = Server.Equip.OnServerEvent:Connect(function(Player, Slot, Name)
		Heard = { Player, Slot, Name }
	end)

	local Stock: { number } = {}
	Client.Stock.OnClientEvent:Connect(function(Value)
		table.insert(Stock, Value)
	end)

	Server.Price.OnServerInvoke = function(_Player, Id: number)
		return Id * 2
	end

	local Price: number?
	task.spawn(function()
		Price = Client.Price:Fire(21)
	end)

	Client.Equip:Fire(3, "sword")
	Server.Stock:FireClient(Shared.Player, 1)
	Server.Stock:Fire(2)
	Exchange(Pair)
	--> The answer was batched while the server read the call; a second step carries it back.
	Exchange(Pair)

	Check("Connect", Heard[1] == Shared.Player and Heard[2] == 3 and Heard[3] == "sword", "the server heard nothing")
	Check("Fire", Stock[1] == 1 and Stock[2] == 2, `the client heard {table.concat(Stock, ", ")}`)
	Check("Invoke", Price == 42, `the call returned {Price}`)

	Connection:Disconnect()
	Client.Equip:Fire(4, "bow")
	Exchange(Pair)
	Check("Disconnect", Heard[2] == 3, "a disconnected listener was still called")
end)

RunClosure("The QuickNet guide's bridge answers to QuickNet's methods, signals and invokes", function()
	local QuickNetNames = luau.load(Bridge("coming-from-quicknet"))()
	local Pair = Isolated.Build(Isolated.Parse(SEVERAL_VALUES), "BRIDGEQUICKNET")
	local Server, Client = QuickNetNames(Pair.Server), QuickNetNames(Pair.Client)

	local Heard: { any } = {}
	local Connection = Server.Equip.OnServerEvent:ConnectAsync(function(Player, Slot, Name)
		Heard = { Player, Slot, Name }
	end)

	local Stock: { number } = {}
	Client.Stock.OnClientEvent:Connect(function(Value)
		table.insert(Stock, Value)
	end)

	Server.Price.OnServerInvokeAsync = function(_Player, Id: number)
		return Id * 2
	end

	local Price: number?
	task.spawn(function()
		Price = Client.Price:InvokeServer(21)
	end)

	Client.Equip:FireServer(3, "sword")
	Server.Stock:FireClient(Shared.Player, 1)
	Server.Stock:FireClients({ Shared.Player }, 2)
	Server.Stock:FireAllClients(3)
	Exchange(Pair)
	Exchange(Pair)

	Check("Connect", Heard[1] == Shared.Player and Heard[2] == 3 and Heard[3] == "sword", "the server heard nothing")
	Check("Fire", table.concat(Stock, ",") == "1,2,3", `the client heard {table.concat(Stock, ",")}`)
	Check("Invoke", Price == 42, `the call returned {Price}`)

	Connection:Disconnect()
	Client.Equip:FireServer(4, "bow")
	Exchange(Pair)
	Check("Disconnect", Heard[2] == 3, "a disconnected listener was still called")
end)

return {}
