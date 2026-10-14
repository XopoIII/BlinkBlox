--!strict
--- Specs for the directives a generated module opens with.
---
--- `--!native` heads the server module and nothing else. Every Roblox server compiles native code;
--- a client device that cannot logs a failure for each module that asks it to, so the client and the
--- types module are emitted without it. The rest of the header is the same for all three.
local Assertions = require("./Assertions")
local Generator = require("@compiler/Generator")
local Harness = require("./Harness")
local Isolated = require("./Isolated")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local SCHEMA = [[
event Ping { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }
event Pong { From: Server, Type: Reliable, Call: SingleSync, Data: u8 }
]]

local COMMON = "--!strict\n--!optimize 2\n--!nolint LocalShadow\n"

RunClosure("Only the server module asks to be compiled natively", function()
	local Tree = Isolated.Parse(SCHEMA)
	local Outputs = {
		Server = Generator.Generate("Server", Tree),
		Client = Generator.Generate("Client", Tree),
		Types = Generator.GenerateShared(Tree),
	}

	for Name, Source in Outputs do
		local Native = string.find(Source, "--!native", 1, true) ~= nil
		if Name == "Server" then
			if string.sub(Source, 1, 23) ~= "--!strict\n--!native\n--!" then
				ErrorPrint(`Failed "Directives": the server module does not open with --!strict and --!native.`)
			end
		elseif Native then
			ErrorPrint(`Failed "Directives": the {Name} module asks to be compiled natively.`)
		elseif string.sub(Source, 1, #COMMON) ~= COMMON then
			ErrorPrint(`Failed "Directives": the {Name} module lost the rest of its header.`)
		end
	end
end)
