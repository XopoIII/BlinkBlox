--!strict
--- The compiler's own range type. Deliberately NOT Roblox's `NumberRange` userdata: the CLI runs on
--- Lune where that global does not exist, and every range in the AST is a plain table.
export type NumberRange = { Min: number, Max: number }
local NumberRange = {
	new = function(Min: number, Max: number?): NumberRange
		return {
			Min = Min,
			Max = Max or Min,
		}
	end,
}

export type Case = "Camel" | "Snake" | "Pascal"
export type Cases = {
	Fire: string,
	FireAll: string,
	FireList: string,
	FireExcept: string,
	On: string,
	Invoke: string,
	Predict: string,
	StepReplication: string,
	SetRateLimitHandler: string,
	Next: string,
	Iter: string,
	Read: string,
	Write: string,
}

export type Primitive = {
	Bounds: NumberRange?,
	Integer: boolean?,
	Component: boolean,
	AllowsRange: boolean,
	AllowsOptional: boolean,
	AllowedComponents: number,

	--- Bytes this primitive occupies on the wire when its size is FIXED. Zero means the size is not
	--- a property of the primitive alone: `string` and `buffer` depend on their range, `vector` and
	--- `CFrame` on their component types, and `Instance`/`unknown` occupy no buffer bytes at all --
	--- they ride the remote's second argument. `src/Modules/Size.luau` handles those cases and reads
	--- this field for everything else.
	---
	--- It lives here rather than next to the prefabs that emit the writes because the Studio plugin
	--- cannot reach `src/Generator/Prefabs.luau` -- it never loads `Blocks` -- and the size analysis
	--- has to run in the editor for the oversize-unreliable diagnostic to appear there.
	Bytes: number,
}

local Indexes = {
	Pascal = 1,
	Camel = 2,
	Snake = 3,
}

local Cases: { [string]: { string } } = {
	On = { "On", "on", "on" },
	Invoke = { "Invoke", "invoke", "invoke" },
	Predict = { "Predict", "predict", "predict" },
	Fire = { "Fire", "fire", "fire" },
	FireAll = { "FireAll", "fireAll", "fire_all" },
	FireList = { "FireList", "fireList", "fire_list" },
	FireExcept = { "FireExcept", "fireExcept", "fire_except" },
	StepReplication = { "StepReplication", "stepReplication", "step_replication" },
	SetRateLimitHandler = { "SetRateLimitHandler", "setRateLimitHandler", "set_rate_limit_handler" },
	Next = { "Next", "next", "next" },
	Iter = { "Iter", "iter", "iter" },
	Read = { "Read", "read", "read" },
	Write = { "Write", "write", "write" },
}

local Primitives: { [string]: Primitive } = {
	u8 = {
		Bounds = NumberRange.new(0, 255),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 1,
	},
	u16 = {
		Bounds = NumberRange.new(0, 65535),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	u32 = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	i8 = {
		Bounds = NumberRange.new(-128, 127),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 1,
	},
	i16 = {
		Bounds = NumberRange.new(-32768, 32767),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	i32 = {
		Bounds = NumberRange.new(-2147483648, 2147483647),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	f16 = {
		Bounds = NumberRange.new(-65504, 65504),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	f32 = {
		Bounds = NumberRange.new(-16777216, 16777216),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	f64 = {
		Bounds = NumberRange.new(-2 ^ 53, 2 ^ 53),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
	boolean = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		--> Zero because a boolean is not measured in bytes at all: it takes one bit of the enclosing
		--> block's bitfield, and `src/Modules/Size.luau` counts it there.
		Bytes = 0,
	},
	string = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	vector = {
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 1,
		Bytes = 0,
	},
	buffer = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	Color3 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 3,
	},
	CFrame = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 2,
		Bytes = 0,
	},
	Instance = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	BrickColor = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	unknown = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = false,
		AllowedComponents = 0,
		Bytes = 0,
	},
	DateTime = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
	DateTimeMillis = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
}

return {
	Keywords = {
		map = true,
		set = true,
		type = true,
		enum = true,
		struct = true,

		event = true,
		["function"] = true,

		scope = true,
		option = true,

		export = true,
	},

	Primtives = Primitives,
	GetCasing = function(Case: Case): Cases
		local Index = Indexes[Case]
		if not Index then
			error(`Unknown casing "{Case}", expectd one of "Pascal" or "Camel" or "Snake"`)
		end

		local Casing: any = {}
		for Key, Options in Cases do
			Casing[Key] = Options[Index]
		end
		return Casing
	end,
}
