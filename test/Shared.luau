--!strict
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Player = newproxy(true)
local Metatable = getmetatable(Player)
Metatable.__tostring = function()
	return "Player"
end

--> A clock the tests drive by hand.
---
--> Generated server code reads `os.clock()` to refill rate buckets. Left as the real clock, a rate
--> limiting test would depend on how fast the machine running it happens to be -- the classic test
--> that passes on a laptop and fails in CI. This one starts at zero and only moves when a test says
--> so, which makes "spend the bucket, wait a second, spend it again" an exact assertion.
local Clock = 0

--> Whether the mock player is still in the game. Generated server code asks before writing a
--> player's buffer back into PlayersMap, so a test can drive that path by flipping this.
local PlayerInGame = true

--> Stands in for the Players service as the mock player's parent. Only ever compared against nil.
local PlayerParent = { Name = "Players" }

local PlayerFields = {
	--> The real API the generated code calls. Returning a plain boolean is enough: the code only
	--> ever asks whether the player is still a descendant of Players.
	IsDescendantOf = function(_self, _Ancestor)
		return PlayerInGame
	end,

	--> Used by the inbound guard's warnings. Without it they report "from nil", which would hide
	--> exactly the detail those warnings exist to give.
	Name = "Player",
}

--> A function rather than a table because `Parent` has to track SetPlayerInGame: the receive loop
--> stops decoding once the player detaches, and a frozen field would make that path untestable.
Metatable.__index = function(_self, Key: string)
	if Key == "Parent" then
		return if PlayerInGame then PlayerParent else nil
	end

	return PlayerFields[Key]
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({
		Connections = {},
	}, Signal)
end

function Signal:Fire(...)
	for _, Function in self.Connections do
		task.spawn(Function, ...)
	end
end

function Signal:Connect(Callback: (...unknown) -> unknown)
	local Key = tostring(os.clock())
	self.Connections[Key] = Callback
	return {
		Disconnect = function()
			self.Connections[Key] = nil
		end,
	}
end

--> Game emulation enviornment
local function GetEnvironment()
	local Instances = {}
	local Services = {
		Players = {
			PlayerRemoving = Signal.new(),
			GetPlayers = function(_self)
				return { Player }
			end,
		},

		ReplicatedStorage = {
			Instances = Instances,
			FindFirstChild = function(_self, Name: string)
				assert(Instances[Name], `Attempted to find child: "{Name}", but it was not defined.`)
				return Instances[Name]
			end,
		},

		RunService = {
			Heartbeat = Signal.new(),
			IsClient = function(_self)
				return true
			end,
			IsServer = function(_self)
				return true
			end,
			IsRunning = function(_self)
				return true
			end,
		},
	}

	Services.ReplicatedStorage.WaitForChild = Services.ReplicatedStorage.FindFirstChild

	--> Drives Heartbeat for the generated modules.
	-->
	--> It stops on a deadline rather than running forever, and that is about failure reporting rather
	--> than tidiness. Lune keeps the process alive while a task is pending, so an unhandled error in
	--> a spec used to print its stack and then HANG — the suite reported nothing further and had to
	--> be killed from outside. In CI that turned a failing test into a stuck job with no logs until
	--> the runner gave up.
	-->
	--> The whole suite takes well under a minute; the deadline is generous enough to be invisible in
	--> a healthy run, and short enough that a broken one exits on its own.
	local Deadline = os.clock() + 300

	task.spawn(function()
		while os.clock() < Deadline do
			local DeltaTime = task.wait(1 / 60)
			for _, Function in Services.RunService.Heartbeat.Connections do
				Function(DeltaTime)
			end
		end
	end)

	local Color3 = {}
	function Color3.new(R: number, G: number, B: number): Color3
		return table.freeze({ R = R, G = G, B = B, __typeof = "Color3" }) :: any
	end

	function Color3.fromRGB(R: number, G: number, B: number): Color3
		return Color3.new(R / 255, G / 255, B / 255)
	end

	local DateTime = {}
	function DateTime.fromUnixTimestamp(Timestamp: number): DateTime
		return table.freeze({ UnixTimestamp = Timestamp, __typeof = "DateTime" })
	end

	function DateTime.fromUnixTimestampMillis(TimestampMillis: number): DateTime
		return table.freeze({ UnixTimestampMillis = TimestampMillis, __typeof = "DateTime" })
	end

	local BrickColor = {}
	function BrickColor.new(Number: number): BrickColor
		return table.freeze({ Number = Number, __typeof = "BrickColor" })
	end

	return {
		game = {
			GetService = function(_self, Service: string)
				assert(Services[Service], `Attempted to get service: "{Service}", but it was not defined.`)
				return Services[Service]
			end,
		},

		Color3 = Color3,
		DateTime = DateTime,
		Services = Services,
		Instances = Instances,
		BrickColor = BrickColor,
	}
end

return {
	Signal = Signal,
	Player = Player,

	--> Injected into every mocked module's environment, since `luau.load` replaces globals wholesale
	--> and the generated code would otherwise index a nil `os`.
	Os = {
		clock = function()
			return Clock
		end,
		time = os.time,
		date = os.date,
	},

	--> Moves the mock clock forward. Rate buckets refill lazily off the difference, so this is how a
	--> test buys itself more tokens.
	AdvanceClock = function(Seconds: number)
		Clock += Seconds
	end,
	Bridge = Signal.new(),
	GetEnvironment = GetEnvironment,
	ServerOnlyInstance = roblox.Instance.new("Instance"),

	--> Simulates the player leaving (and coming back), so a test can exercise what generated server
	--> code does when a listener resumes after its player is gone.
	SetPlayerInGame = function(InGame: boolean)
		PlayerInGame = InGame
	end,
}
