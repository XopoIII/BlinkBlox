--!strict
--- Specs for NumberSequence and the datatypes of Prefabs/Spatial: PhysicalProperties, Rect, Region3
--- and Ray. Each goes through an exported type's Write and Read and back, and each reader that can be
--- handed what a hostile client would send refuses it by its own message.
---
--- Lune's constructors check less than Roblox's: its PhysicalProperties.new clamps nothing and its
--- NumberSequence.new accepts any keypoints at all, so here the reader is the only thing between a
--- bad packet and a listener, and a check taken out of it fails the spec that names it.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Parser = require("@compiler/Parser")
local Shared = require("./Shared")
local Size = require("@compiler/Modules/Size")
local roblox = require("@lune/roblox")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local Vector2 = roblox.Vector2
local Vector3 = roblox.Vector3

local Pair = Isolated.Build(
	Isolated.Parse([[
option WriteValidations = true
export type Physics = PhysicalProperties
export type MaybePhysics = PhysicalProperties?
export type Curve = NumberSequence
export type Bounds = Rect
export type Region = Region3
export type Line = Ray
export struct World {
    Custom: PhysicalProperties?,
    Size: NumberSequence,
    Clip: Rect,
    Zone: Region3,
    Aim: Ray,
}

event Applied {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: PhysicalProperties
}
]]),
	"WORLD_DATATYPES"
)

local Server = Pair.Server
local Client = Pair.Client

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

local function Accepts(Name: string, Type: any, Bytes: buffer)
	local Success, Failure = pcall(Type.Read, Bytes)
	Check(Name, Success, `the reader refused it: {Failure}`)
end

local PHYSICAL_FIELDS = {
	{ Name = "Density", Max = 100 },
	{ Name = "Friction", Max = 2 },
	{ Name = "Elasticity", Max = 1 },
	{ Name = "FrictionWeight", Max = 100 },
	{ Name = "ElasticityWeight", Max = 100 },
	{ Name = "AcousticAbsorption", Max = 1 },
}

--- Six f32 fields, each a value an honest sender could write, with `Field` replaced by `Value`.
local function PhysicalBytes(Field: number?, Value: number?): buffer
	local Built = buffer.create(24)
	local Honest = { 0.7, 0.3, 0.5, 1, 1, 0.25 }
	for Index, Number in Honest do
		buffer.writef32(Built, (Index - 1) * 4, if Index == Field then Value :: number else Number)
	end
	return Built
end

RunClosure("PhysicalProperties round-trip every field", function()
	--> Distinct and exact in f32, so a swapped or dropped field shows.
	local Sent = roblox.PhysicalProperties.new(0.75, 1.5, 0.25, 12.5, 40, 0.125)
	local Got = Server.Physics.Read(Server.Physics.Write(Sent))
	for _, Field in PHYSICAL_FIELDS do
		local Name = Field.Name
		Check("PhysicalProperties", (Got :: any)[Name] == (Sent :: any)[Name], `{Name} arrived as {(Got :: any)[Name]}`)
	end

	Check("PhysicalProperties?", Server.MaybePhysics.Read(Server.MaybePhysics.Write(nil)) == nil, "nil changed")
	local Maybe = Server.MaybePhysics.Read(Server.MaybePhysics.Write(Sent))
	Check("PhysicalProperties?", Maybe ~= nil and Maybe.Friction == 1.5, "the value changed")
end)

RunClosure("PhysicalProperties refuses NaN and out-of-range fields, and takes each bound", function()
	for Index, Field in PHYSICAL_FIELDS do
		local Name = Field.Name
		Refuses(`{Name} NaN`, Server.Physics, PhysicalBytes(Index, 0 / 0), `PhysicalProperties {Name}`)
		Refuses(`{Name} over`, Server.Physics, PhysicalBytes(Index, Field.Max * 1.5), `PhysicalProperties {Name}`)
		Refuses(`{Name} under`, Server.Physics, PhysicalBytes(Index, -1), `PhysicalProperties {Name}`)
		Accepts(`{Name} at its maximum`, Server.Physics, PhysicalBytes(Index, Field.Max))
		Accepts(`{Name} at 0`, Server.Physics, PhysicalBytes(Index, 0))
	end
end)

RunClosure("A NaN PhysicalProperties from a client never reaches the listener", function()
	local Heard: { any } = {}
	Server.Applied.On(function(_Player, Value)
		table.insert(Heard, Value)
	end)
	local Reports: { string? } = {}
	Server.SetDecodeErrorHandler(function(_Player, Event, _Failure)
		table.insert(Reports, Event)
	end)

	--> Real bytes from the client, then the same packet with Friction made NaN.
	local Sent = roblox.PhysicalProperties.new(0.75, 1.5, 0.25, 12.5, 40, 0.125)
	table.clear(Pair.Sent)
	Client.Applied.Fire(Sent)
	Client.StepReplication()
	local Packet = Pair.Sent[1] and Pair.Sent[1].Buffer
	if not Packet or buffer.len(Packet) ~= 25 then
		ErrorPrint(
			`A NaN PhysicalProperties: the client's packet was {if Packet then buffer.len(Packet) else "missing"}.`
		)
		return
	end

	Shared.AdvanceClock(2)
	Pair.Feed(true, Packet)
	Check("Honest packet", #Heard == 1 and Heard[1] == Sent, `the listener heard {#Heard} values`)

	local Hostile = buffer.create(25)
	buffer.copy(Hostile, 0, Packet)
	buffer.writef32(Hostile, 5, 0 / 0)
	Shared.AdvanceClock(2)
	Pair.Feed(true, Hostile)
	Check("NaN packet", #Heard == 1, "the listener heard a NaN PhysicalProperties")
	Check("NaN packet", #Reports == 1 and Reports[1] == "Applied", `{#Reports} decode errors were reported`)

	Server.SetDecodeErrorHandler(nil)
end)

--- A NumberSequence packet: a count, then each keypoint's time, value and envelope.
local function SequenceBytes(Keypoints: { { number } }, Count: number?, Length: number?): buffer
	local Built = buffer.create(Length or 1 + #Keypoints * 12)
	buffer.writeu8(Built, 0, Count or #Keypoints)
	for Index, Keypoint in Keypoints do
		local At = 1 + (Index - 1) * 12
		buffer.writef32(Built, At, Keypoint[1])
		buffer.writef32(Built, At + 4, Keypoint[2])
		buffer.writef32(Built, At + 8, Keypoint[3])
	end
	return Built
end

RunClosure("A NumberSequence round-trips its keypoints", function()
	local Sent = roblox.NumberSequence.new({
		roblox.NumberSequenceKeypoint.new(0, 1.5, 0.25),
		roblox.NumberSequenceKeypoint.new(0.5, -3, 0),
		roblox.NumberSequenceKeypoint.new(1, 8, 2),
	})

	local Got = Server.Curve.Read(Server.Curve.Write(Sent))
	Check("NumberSequence", #Got.Keypoints == 3, `{#Got.Keypoints} keypoints`)
	for Index, Keypoint in Sent.Keypoints do
		local Other = Got.Keypoints[Index]
		Check("NumberSequence", Other.Time == Keypoint.Time, `time {Other.Time} at {Index}`)
		Check("NumberSequence", Other.Value == Keypoint.Value, `value {Other.Value} at {Index}`)
		Check("NumberSequence", Other.Envelope == Keypoint.Envelope, `envelope {Other.Envelope} at {Index}`)
	end
end)

RunClosure("NumberSequence readers refuse what Roblox would throw on, and NaN", function()
	local Ends = { { 0, 1, 0 }, { 1, 2, 0 } }
	Accepts("NumberSequence of two", Server.Curve, SequenceBytes(Ends))
	Refuses("NumberSequence of one", Server.Curve, SequenceBytes({ { 0, 1, 0 } }), "2 to 20 keypoints")
	Refuses("NumberSequence of 21", Server.Curve, SequenceBytes({}, 21, 300), "2 to 20 keypoints")
	Refuses("NumberSequence of 200", Server.Curve, SequenceBytes({}, 200, 300), "2 to 20 keypoints")
	Refuses("NumberSequence past the packet", Server.Curve, SequenceBytes(Ends, 20), "to fit in the packet")
	Refuses(
		"NumberSequence out of order",
		Server.Curve,
		SequenceBytes({ { 0, 1, 0 }, { 0.75, 1, 0 }, { 0.5, 1, 0 }, { 1, 1, 0 } }),
		"from 0 to 1 in order"
	)
	Refuses("NumberSequence not from 0", Server.Curve, SequenceBytes({ { 0.1, 1, 0 }, { 1, 1, 0 } }), "in order")
	Refuses("NumberSequence not to 1", Server.Curve, SequenceBytes({ { 0, 1, 0 }, { 0.9, 1, 0 } }), "in order")
	Refuses("NumberSequence NaN time", Server.Curve, SequenceBytes({ { 0, 1, 0 }, { 0 / 0, 1, 0 } }), "in order")
	Refuses("NumberSequence NaN value", Server.Curve, SequenceBytes({ { 0, 0 / 0, 0 }, { 1, 1, 0 } }), "value")
	Refuses("NumberSequence NaN envelope", Server.Curve, SequenceBytes({ { 0, 1, 0 / 0 }, { 1, 1, 0 } }), "envelope")
	Refuses("NumberSequence negative envelope", Server.Curve, SequenceBytes({ { 0, 1, -1 }, { 1, 1, 0 } }), "envelope")
end)

RunClosure("NumberSequence refuses more than 20 keypoints on send", function()
	local Keypoints = {}
	for Index = 0, 20 do
		table.insert(Keypoints, roblox.NumberSequenceKeypoint.new(Index / 20, 1, 0))
	end
	local Success, Failure = pcall(Server.Curve.Write, roblox.NumberSequence.new(Keypoints))
	Check("NumberSequence send", not Success, "21 keypoints were written")
	Check("NumberSequence send", string.find(tostring(Failure), "2 to 20", 1, true) ~= nil, `refused with "{Failure}"`)
end)

RunClosure("Rect and Ray round-trip", function()
	local Bounds = roblox.Rect.new(Vector2.new(-1.5, 2), Vector2.new(30.25, 40))
	Check("Rect", Server.Bounds.Read(Server.Bounds.Write(Bounds)) == Bounds, "changed")

	local Line = roblox.Ray.new(Vector3.new(1, -2.5, 3), Vector3.new(-4, 5.75, -6))
	Check("Ray", Server.Line.Read(Server.Line.Write(Line)) == Line, "changed")

	local Success = pcall(Server.Bounds.Write, Vector2.new(1, 2) :: any)
	Check("Rect send", not Success, "a Vector2 was written as a Rect")
end)

--- The largest gap between two vectors' components, as a fraction of the largest component either holds.
local function Drift(A: Vector3, B: Vector3, Scale: number): number
	local Gap = math.max(math.abs(A.X - B.X), math.abs(A.Y - B.Y), math.abs(A.Z - B.Z))
	return Gap / math.max(Scale, 1)
end

local function Largest(Region: any): number
	local Center, Extent = Region.CFrame.Position, Region.Size
	return math.max(
		math.abs(Center.X),
		math.abs(Center.Y),
		math.abs(Center.Z),
		math.abs(Extent.X),
		math.abs(Extent.Y),
		math.abs(Extent.Z)
	)
end

RunClosure("Region3 round-trips, exactly when its corners are whole", function()
	math.randomseed(1300)
	local function Whole(Low: number, High: number): number
		return math.random(Low, High)
	end
	local function Number(Low: number, High: number): number
		return Low + math.random() * (High - Low)
	end
	for _ = 1, 200 do
		local Low = Vector3.new(Whole(-500, 500), Whole(-500, 500), Whole(-500, 500))
		local High = Low + Vector3.new(Whole(0, 300), Whole(0, 300), Whole(0, 300))
		local Sent = roblox.Region3.new(Low, High)
		local Got = Server.Region.Read(Server.Region.Write(Sent))
		if Got.CFrame ~= Sent.CFrame or Got.Size ~= Sent.Size then
			ErrorPrint(`Region3: whole corners {Low} to {High} came back as {Got.CFrame.Position}, {Got.Size}.`)
			return
		end
	end

	--> Region3.new rounds its centre and size to f32 itself, so any other region may move by less than
	--> one f32 step of its largest component. A wrong sign or swapped corners moves it by far more.
	for _ = 1, 1000 do
		local Low = Vector3.new(Number(-500, 500), Number(-500, 500), Number(-500, 500))
		local High = Low + Vector3.new(Number(0, 300), Number(0, 300), Number(0, 300))
		local Sent = roblox.Region3.new(Low, High)
		local Got = Server.Region.Read(Server.Region.Write(Sent))
		local Scale = Largest(Sent)
		local Moved =
			math.max(Drift(Got.CFrame.Position, Sent.CFrame.Position, Scale), Drift(Got.Size, Sent.Size, Scale))
		if Moved > 2 ^ -22 then
			ErrorPrint(`Region3: {Low} to {High} moved by {Moved} of its largest component.`)
			return
		end
	end

	local Swapped = roblox.Region3.new(Vector3.new(4, 4, 4), Vector3.new(0, 0, 0))
	local Got = Server.Region.Read(Server.Region.Write(Swapped))
	Check("Region3 swapped", Got.Size == Swapped.Size and Got.CFrame == Swapped.CFrame, `arrived as {Got.Size}`)
end)

RunClosure("A struct of the five round-trips", function()
	local Sent = {
		Custom = roblox.PhysicalProperties.new(2, 0.5, 0.25, 1, 1, 0.5),
		Size = roblox.NumberSequence.new({
			roblox.NumberSequenceKeypoint.new(0, 0, 0),
			roblox.NumberSequenceKeypoint.new(1, 4, 0.5),
		}),
		Clip = roblox.Rect.new(0, 0, 100, 50),
		Zone = roblox.Region3.new(Vector3.new(-8, 0, -8), Vector3.new(8, 16, 8)),
		Aim = roblox.Ray.new(Vector3.new(0, 5, 0), Vector3.new(0, -50, 0)),
	}
	local Got = Server.World.Read(Server.World.Write(Sent))
	Check("World", Got.Custom == Sent.Custom, "the physical properties changed")
	Check("World", Got.Size.Keypoints[2].Value == 4, "the sequence changed")
	Check("World", Got.Clip == Sent.Clip and Got.Aim == Sent.Aim, "the rect or the ray changed")
	Check("World", Got.Zone.CFrame == Sent.Zone.CFrame and Got.Zone.Size == Sent.Zone.Size, "the region changed")

	local Bare = table.clone(Sent) :: any
	Bare.Custom = nil
	Check("World", Server.World.Read(Server.World.Write(Bare)).Custom == nil, "a missing PhysicalProperties arrived")
end)

RunClosure("The five type names are taken, and NumberSequenceKeypoint only beside a NumberSequence", function()
	for _, Name in { "PhysicalProperties", "NumberSequence", "Rect", "Region3", "Ray" } do
		local Accepted, Failure = pcall(Isolated.Parse, `type {Name} = u8`)
		Check(`type {Name}`, not Accepted, "a declaration took a datatype's name")
		Check(`type {Name}`, string.find(tostring(Failure), "E2002", 1, true) ~= nil, `refused with "{Failure}"`)
	end

	local Alone = pcall(Isolated.Parse, "type NumberSequenceKeypoint = u8\nexport type Plain = NumberSequenceKeypoint")
	Check("NumberSequenceKeypoint alone", Alone, "a schema with no NumberSequence could not name it")

	local Beside, Failure =
		pcall(Isolated.Parse, "type NumberSequenceKeypoint = u8\nexport type Curve = NumberSequence")
	Check("NumberSequenceKeypoint beside", not Beside, "it was accepted beside a NumberSequence")
	Check("NumberSequenceKeypoint beside", string.find(tostring(Failure), "E3005", 1, true) ~= nil, `"{Failure}"`)
end)

RunClosure("The size analysis measures each type as the emitter writes it", function()
	--> 241 for twenty keypoints is what decides whether an unreliable event can fit; without it a
	--> NumberSequence measured as its smallest, and five of them passed for 125 bytes.
	local Expected = {
		NumberSequence = { Min = 25, Max = 241 },
		PhysicalProperties = { Min = 24, Max = 24 },
		Rect = { Min = 16, Max = 16 },
		Region3 = { Min = 24, Max = 24 },
		Ray = { Min = 24, Max = 24 },
	}
	for Name, Bounds in Expected do
		local Tree = Parser.new():Parse(`struct T \{ Field: {Name} }`)
		local Measured = Size.Sealed(Tree.Value.Declarations[1])
		Check(
			`{Name} size`,
			Measured.Min == Bounds.Min and Measured.Max == Bounds.Max,
			`measured {Measured.Min} to {Measured.Max}, expected {Bounds.Min} to {Bounds.Max}`
		)
	end

	local Written = Server.Curve.Write(roblox.NumberSequence.new({
		roblox.NumberSequenceKeypoint.new(0, 1, 0),
		roblox.NumberSequenceKeypoint.new(1, 2, 0),
	}))
	Check("NumberSequence written", buffer.len(Written) == 25, `two keypoints took {buffer.len(Written)} bytes`)
end)
