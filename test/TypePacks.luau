--!strict
--- Specs for named type-pack elements -- `Data: (chefId: f64, dish: string)`.
---
--- Naming an element changes the generated SIGNATURE and nothing else: a type pack is serialised
--- positionally, with no field tags, so a named pack has to round-trip byte for byte the way the
--- unnamed packs in Test.luau do. That is what these assert.
---
--- They live apart from Test.luau, like Decoding.luau, because that file is on the size ratchet in
--- scripts/check-file-size.sh and new specs belong in new files rather than on the end of it.
local Assertions = require("./Assertions")
local Modules = require("./Modules")

local Client = Modules.Client
local Server = Modules.Server

local FireAndExpectTuple = Assertions.FireAndExpectTuple
local InvokeAndExpectTuple = Assertions.InvokeAndExpectTuple

FireAndExpectTuple("Named Tuple", Server.NamedTuple, Client.NamedTuple, 1.5, "risotto", 4)
FireAndExpectTuple("Partially named Tuple", Server.PartiallyNamedTuple, Client.PartiallyNamedTuple, 7, "B", 65535)

--> Data and Return name their elements the same way here. The two packs share a scope in the
--> generated body, so a round trip is what proves the Return prefix keeps the locals apart -- without
--> it this declares `id` twice and the module does not compile.
InvokeAndExpectTuple(
	"Named function Tuple",
	Client.NamedTupleFunction,
	Server.NamedTupleFunction,
	{ 255, "in" },
	{ 65535, "out" }
)

return {}
