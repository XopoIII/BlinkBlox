local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Player = newproxy(true)
local Metatable = getmetatable(Player)
Metatable.__tostring = function()
	return "Player"
end

--> Whether the mock player is still in the game. Generated server code asks before writing a
--> player's buffer back into PlayersMap, so a test can drive that path by flipping this.
local PlayerInGame = true

Metatable.__index = {
	--> The real API the generated code calls. Returning a plain boolean is enough: the code only
	--> ever asks whether the player is still a descendant of Players.
	IsDescendantOf = function(_self, _Ancestor)
		return PlayerInGame
	end,
}

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

	task.spawn(function()
		while true do
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
	Bridge = Signal.new(),
	GetEnvironment = GetEnvironment,
	ServerOnlyInstance = roblox.Instance.new("Instance"),

	--> Simulates the player leaving (and coming back), so a test can exercise what generated server
	--> code does when a listener resumes after its player is gone.
	SetPlayerInGame = function(InGame: boolean)
		PlayerInGame = InGame
	end,
}
