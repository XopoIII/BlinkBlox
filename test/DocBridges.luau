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

return {}
