--!strict
--> Runtime helpers for the Roblox datatypes that do not fit a fixed run of reads and writes. Each is
--> spliced in only when a schema uses it; see `Prefabs.Required` and Prefabs/Datatypes.luau.

--> An EnumItem travels as its Value and is looked up by it on receipt. Not by its place in
--> `GetEnumItems()`: that list can differ between a client and a server while Roblox rolls an engine
--> change out, and an index would then decode as a neighbouring item without any error. The table is
--> built once per enum, on first use, and a Value no item has is refused.
local EnumItems = [[
local EnumItemLookups: { [Enum]: { [number]: EnumItem } } = {}
local function EnumItemOf(Type: Enum, Value: number): EnumItem
    local Lookup = EnumItemLookups[Type]
    if Lookup == nil then
        local Built = {}
        for _, Item in Type:GetEnumItems() do
            Built[Item.Value] = Item
        end
        EnumItemLookups[Type] = Built
        Lookup = Built
    end

    local Item = Lookup[Value]
    if Item == nil then
        error(`Expected a value of {Type}, got {Value} instead.`)
    end
    return Item
end

]]

--> A count of 2 to 20 keypoints, then each as a f32 time and three u8 channels. Roblox's constructor
--> throws on fewer than two keypoints, on a first not at 0 or a last not at 1, and on times out of
--> order; all of it is checked here first, and the count before anything is read for it, so a hostile
--> packet is refused with a message rather than by whatever the constructor says.
local ColorSequences = [[
local function ReadColorSequence(): ColorSequence
    local Count = buffer.readu8(RecieveBuffer, Read(1))
    if not (Count >= 2 and Count <= 20) then
        error(`Expected a ColorSequence of 2 to 20 keypoints, got {Count} instead.`)
    end
    if Count * 7 > buffer.len(RecieveBuffer) - RecieveCursor then
        error(`Expected a ColorSequence of {Count} keypoints to fit in the packet.`)
    end

    local Offset = Read(Count * 7)
    local Keypoints = table.create(Count) :: { ColorSequenceKeypoint }
    local Previous = 0
    for Index = 1, Count do
        local At = Offset + (Index - 1) * 7
        local Time = buffer.readf32(RecieveBuffer, At)
        if not (Time >= Previous and Time <= 1) or (Index == 1 and Time ~= 0) or (Index == Count and Time ~= 1) then
            error(`Expected ColorSequence keypoint times to run from 0 to 1 in order, got {Time} at {Index}.`)
        end
        Previous = Time
        local Color = Color3.fromRGB(
            buffer.readu8(RecieveBuffer, At + 4),
            buffer.readu8(RecieveBuffer, At + 5),
            buffer.readu8(RecieveBuffer, At + 6)
        )
        Keypoints[Index] = ColorSequenceKeypoint.new(Time, Color)
    end
    return ColorSequence.new(Keypoints)
end

local function WriteColorSequence(Value: ColorSequence)
    local Keypoints = Value.Keypoints
    local Count = #Keypoints
    if not (Count >= 2 and Count <= 20) then
        error(`Expected a ColorSequence of 2 to 20 keypoints, got {Count} instead.`)
    end

    local Offset = Allocate(1 + Count * 7)
    buffer.writeu8(SendBuffer, Offset, Count)
    for Index, Keypoint in Keypoints do
        local At = Offset + 1 + (Index - 1) * 7
        local Color = Keypoint.Value
        buffer.writef32(SendBuffer, At, Keypoint.Time)
        buffer.writeu8(SendBuffer, At + 4, math.clamp(math.round(Color.R * 255), 0, 255))
        buffer.writeu8(SendBuffer, At + 5, math.clamp(math.round(Color.G * 255), 0, 255))
        buffer.writeu8(SendBuffer, At + 6, math.clamp(math.round(Color.B * 255), 0, 255))
    end
end

]]

return {
	EnumItems = EnumItems,
	ColorSequences = ColorSequences,
}
