--!strict
--- Specs for the datatypes of Prefabs/Datatypes: Vector2, UDim, UDim2, NumberRange, ColorSequence,
--- TweenInfo and `Enum(Name)`. Each goes through an exported type's Write and Read and back, and each
--- reader that can be handed a value the constructor would throw on refuses it by its own message.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local roblox = require("@lune/roblox")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local Enum = roblox.Enum

local Pair = Isolated.Build(
	Isolated.Parse([[
option WriteValidations = true
export type Point = Vector2
export type Padding = UDim
export type Frame = UDim2
export type Spread = NumberRange
export type Gradient = ColorSequence
export type Motion = TweenInfo
export type Surface = Enum(Material)
export type Surfaces = Enum(Material)[]
export type MaybeKey = Enum(KeyCode)?
export struct Style {
    Size: UDim2,
    Anchor: Vector2,
    Fade: ColorSequence,
    Font: Enum(Font),
}
]]),
	"DATATYPES",
	false,
	{ Color3 = roblox.Color3 }
)

local Server = Pair.Server

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

--- Whether `Read` refuses `Bytes`, with a message containing `Expected`.
local function Refuses(Name: string, Type: any, Bytes: buffer, Expected: string)
	local Success, Failure = pcall(Type.Read, Bytes)
	Check(Name, not Success, "the reader accepted it")
	Check(Name, string.find(tostring(Failure), Expected, 1, true) ~= nil, `refused with "{Failure}"`)
end

local function Bytes(Fill: (buffer) -> (), Length: number): buffer
	local Built = buffer.create(Length)
	Fill(Built)
	return Built
end

RunClosure("Vector2, UDim, UDim2 and NumberRange round-trip", function()
	local Point = roblox.Vector2.new(1.5, -2.25)
	Check("Vector2", Server.Point.Read(Server.Point.Write(Point)) == Point, "changed")

	local Padding = roblox.UDim.new(0.5, -12)
	Check("UDim", Server.Padding.Read(Server.Padding.Write(Padding)) == Padding, "changed")

	local Frame = roblox.UDim2.new(0.25, 100, 1, -36)
	Check("UDim2", Server.Frame.Read(Server.Frame.Write(Frame)) == Frame, "changed")

	local Spread = roblox.NumberRange.new(0.5, 4)
	Check("NumberRange", Server.Spread.Read(Server.Spread.Write(Spread)) == Spread, "changed")
end)

RunClosure("A ColorSequence round-trips its keypoints", function()
	local Sent = roblox.ColorSequence.new({
		roblox.ColorSequenceKeypoint.new(0, roblox.Color3.fromRGB(255, 0, 0)),
		roblox.ColorSequenceKeypoint.new(0.5, roblox.Color3.fromRGB(10, 200, 30)),
		roblox.ColorSequenceKeypoint.new(1, roblox.Color3.fromRGB(0, 0, 255)),
	})

	local Got = Server.Gradient.Read(Server.Gradient.Write(Sent))
	Check("ColorSequence", #Got.Keypoints == 3, `{#Got.Keypoints} keypoints`)
	for Index, Keypoint in Sent.Keypoints do
		local Other = Got.Keypoints[Index]
		Check("ColorSequence", Other.Time == Keypoint.Time, `time {Other.Time} at {Index}`)
		Check("ColorSequence", Other.Value == Keypoint.Value, `colour {Other.Value} at {Index}`)
	end
end)

RunClosure("TweenInfo and Enum(Name) round-trip by Value", function()
	local Motion = (Server :: any).Motion
	local Sent = {
		Time = 0.5,
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.InOut,
		RepeatCount = -1,
		Reverses = true,
		DelayTime = 0.25,
		__typeof = "TweenInfo",
	}
	local Got = Motion.Read(Motion.Write(Sent))
	for Field, Value in Sent do
		Check("TweenInfo", Got[Field] == Value, `{Field} arrived as {Got[Field]}`)
	end

	Check("Enum", Server.Surface.Read(Server.Surface.Write(Enum.Material.Neon)) == Enum.Material.Neon, "changed")
	local Surfaces = { Enum.Material.Plastic, Enum.Material.Grass, Enum.Material.Glass }
	local Many = Server.Surfaces.Read(Server.Surfaces.Write(Surfaces))
	for Index, Item in Surfaces do
		Check("Enum array", Many[Index] == Item, `{Many[Index]} at {Index}`)
	end
	Check("Optional enum", Server.MaybeKey.Read(Server.MaybeKey.Write(nil)) == nil, "nil changed")
	Check("Optional enum", Server.MaybeKey.Read(Server.MaybeKey.Write(Enum.KeyCode.E)) == Enum.KeyCode.E, "changed")
end)

RunClosure("A struct of the new datatypes round-trips", function()
	local Sent = {
		Size = roblox.UDim2.fromScale(0.5, 0.5),
		Anchor = roblox.Vector2.new(0.5, 1),
		Fade = roblox.ColorSequence.new(roblox.Color3.fromRGB(1, 2, 3), roblox.Color3.fromRGB(4, 5, 6)),
		Font = Enum.Font.Gotham,
	}
	local Got = Server.Style.Read(Server.Style.Write(Sent))
	Check("Struct", Got.Size == Sent.Size and Got.Anchor == Sent.Anchor and Got.Font == Sent.Font, "changed")
	Check("Struct", Got.Fade.Keypoints[2].Value == Sent.Fade.Keypoints[2].Value, "the sequence changed")
end)

RunClosure("Readers refuse what the constructors would throw on", function()
	Refuses(
		"NumberRange below",
		Server.Spread,
		Bytes(function(B)
			buffer.writef32(B, 0, 5)
			buffer.writef32(B, 4, 1)
		end, 8),
		"Max at least Min"
	)

	Refuses(
		"NumberRange NaN",
		Server.Spread,
		Bytes(function(B)
			buffer.writef32(B, 0, 0 / 0)
			buffer.writef32(B, 4, 1)
		end, 8),
		"Max at least Min"
	)

	Refuses(
		"ColorSequence of one",
		Server.Gradient,
		Bytes(function(B)
			buffer.writeu8(B, 0, 1)
		end, 8),
		"2 to 20 keypoints"
	)

	Refuses(
		"ColorSequence of 200",
		Server.Gradient,
		Bytes(function(B)
			buffer.writeu8(B, 0, 200)
		end, 8),
		"2 to 20 keypoints"
	)

	Refuses(
		"ColorSequence past the packet",
		Server.Gradient,
		Bytes(function(B)
			buffer.writeu8(B, 0, 20)
		end, 15),
		"to fit in the packet"
	)

	Refuses(
		"ColorSequence out of order",
		Server.Gradient,
		Bytes(function(B)
			buffer.writeu8(B, 0, 3)
			buffer.writef32(B, 1, 0)
			buffer.writef32(B, 8, 0.75)
			buffer.writef32(B, 15, 0.5)
		end, 22),
		"from 0 to 1 in order"
	)

	Refuses(
		"ColorSequence not from 0",
		Server.Gradient,
		Bytes(function(B)
			buffer.writeu8(B, 0, 2)
			buffer.writef32(B, 1, 0.1)
			buffer.writef32(B, 8, 1)
		end, 15),
		"from 0 to 1 in order"
	)

	Refuses(
		"Enum value no item has",
		Server.Surface,
		Bytes(function(B)
			buffer.writeu16(B, 0, 65000)
		end, 2),
		"Expected a value of"
	)
end)

RunClosure("Enum(Name) refuses an item of another enum on send", function()
	local Success, Failure = pcall(Server.Surface.Write, Enum.KeyCode.A)
	Check("Enum send", not Success, "an item of KeyCode was written as a Material")
	Check("Enum send", string.find(tostring(Failure), "Enum.Material", 1, true) ~= nil, `refused with "{Failure}"`)
end)
