-- Every construct of zap 0.6.29's grammar, for test/ConvertZap.luau: what converts, what converts
-- with a loss, and what has no equivalent at all.
opt server_output = "./network/Server.luau"
opt client_output = './network/Client.luau'
opt types_output = "./network/Types.luau"
opt casing = "camelCase"
opt typescript = true
opt manual_event_loop = true;
opt remote_scope = "GAME"
opt remote_folder = "Remotes"
opt call_default = "ManySync"
opt yield_type = "promise"
opt async_lib = "require(game:GetService('ReplicatedStorage').Promise)"
opt disable_fire_all = true
opt typescript_max_tuple_length = 5

-- Numbers, with every shape of range.
type Health = u8(0..100)
type Damage = u8(..100)
type Level = u16(1..)
type Slot = u8(3)
type Anything = i32(..)
type Aim = f32(-1..1)
type Precise = f64(0.5..1.5)

--[[ Strings and buffers,
     bounded and not. ]]
type Username = string.utf8(3..20)
type Blob = string.binary
type Chunk = buffer(..800)
type Loose = buffer;

type Position = vector
type Cell = vector(i16, i16, i16)
type Flat = vector(u8, u8)
type Mixed = vector(f32, u8, f32)
type Where = Vector3
type Pose = CFrame
type Snapped = AlignedCFrame
type Tint = Color3
type Team = BrickColor
type Joined = DateTime
type Seen = DateTimeMillis
type Corner = Vector2

type Target = Instance.Player
type Part = Instance(BasePart)
type Any = Instance
type Maybe = Instance.Player?

type Names = string[]
type Party = string(3..20)[1..8]
type Recent = f64[..50]
type Corners = vector[4]
type Sparse = u8?[]
type MaybeList = u8[]?

type Status = enum { Idle, Walking, "Running fast" }

type Mouse = enum "Type" {
	Move { Delta: vector, Position: vector },
	Click {
		Button: enum { Left, Right },
		Position: vector,
	},
}

type Item = struct {
	name: string,
	price: u16, -- in coins
	tags: string(..16)[..4],
	"display name": string?,
}

type Prices = map { [string]: u16 }
type Flags = set { string }
type Optional = map { [u8]: string? }
type Offers = struct { item: Item, until: DateTime }[..32]
type Either = (string | u32 | Instance.Player)
type Free = unknown
type FreeMaybe = unknown?

namespace Shop = {
	type ItemId = u16

	-- A client names what it buys.
	event Buy = {
		from: Client,
		type: Reliable,
		call: SingleAsync,
		data: (item: ItemId, count: u8, note: string),
	}

	namespace Admin = {
		event SetPrice = { from: Client, data: Prices }
	}

	funct Quote = {
		call: Async,
		args: ItemId,
		rets: (price: u16, stock: u8),
	}
}

event Hello = { from: Server }

event Move = {
	from: Client,
	type: Unreliable,
	call: Polling,
	data: (Position, Aim)
}

event Ordered = {
	from: Server,
	type: OrderedUnreliable,
	call: SingleSync,
	data: Offers
}

event Pick = {
	from: Client,
	data: (string | u8)[]
};

event Inventory = {
	from: Client,
	type: Reliable,
	data: struct { items: Item[], owner: Shop.ItemId, extra: Either }
}

funct Ping = {
	call: Sync,
}

funct Rename = {
	call: Async,
	args: (id: u8, label: string),
	rets: boolean
};
