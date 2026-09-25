--!strict
--- How an event's listener is called: live, from the decode loop or Predict, and replayed, from the
--- queue that `.On` flushes. Split out of Event.luau, which had reached the size cap.
---
--- On the server every one of those calls reports a listener's error through `ListenerFailed` or
--- `RunListener` (Templates/Limits.luau), which hand it to the game's `SetListenerErrorHandler` or,
--- with none installed, leave it to surface as it always did. The client has no such handler: what
--- its listeners run was sent by the trusted server, so their errors stay in the output.
local Blocks = require("./Blocks")

export type Options = {
	Name: string,
	Context: string,
	IsSync: boolean,
	--- The listener expression: the Single event's connection, or `Listener` inside a Many loop.
	Path: string,
	--- Set a Sync event's name for SyncValidation's report before its listener runs.
	Validate: boolean,
}

--- The lines that call a listener with `Arguments`, the sender first on the server.
local function Call(Options: Options, Arguments: string): Blocks.Block
	local Block = Blocks.Block()
	if Options.Validate then
		Block = Block:Line(`SerdesEvent = "{Options.Name}"`)
	end

	local OnServer = Options.Context == "Server"

	--> A Sync listener runs inside the decode loop's pcall, so an error in game code used to be
	--> reported as a packet that could not be decoded -- blamed on the sender, silently on the server
	--> unless the game had installed a handler, and taking the rest of the packet and any later
	--> listeners with it. It is caught here instead, where the cursor already sits past the event:
	--> reported to the game's handler, or raised on a thread of its own, which is where an Async
	--> listener's error has always surfaced.
	if Options.IsSync then
		local Raise = "task.spawn(error, ListenerFailure, 0)"
		local Failed = if OnServer
			then `if not ListenerRan and not ListenerFailed(Player, "{Options.Name}", ListenerFailure) then {Raise} end`
			else `if not ListenerRan then {Raise} end`

		return Block:Line(`local ListenerRan, ListenerFailure = pcall({Options.Path}, {Arguments})`):Line(Failed)
	end

	if OnServer then
		return Block:Line(`Spawn(RunListener, "{Options.Name}", {Options.Path}, {Arguments})`)
	end

	return Block:Line(`Spawn({Options.Path}, {Arguments})`)
end

--- The line that replays one queued row, `Arguments`, to the listener `.On` was just given. On the
--- server the row begins with its sender, and the call goes through RunListener, which runs the
--- listener bare with no handler installed -- a Sync listener's error still reaches `.On`'s caller --
--- and protected with one.
local function Replay(Options: Options): string
	local Row = "table.unpack(Arguments, 1, Arguments.n)"
	if Options.Context == "Server" then
		local Run = `RunListener, "{Options.Name}", Listener, {Row}`
		return if Options.IsSync then `RunListener("{Options.Name}", Listener, {Row})` else `Spawn({Run})`
	end

	return if Options.IsSync then `Listener({Row})` else `Spawn(Listener, {Row})`
end

return {
	Call = Call,
	Replay = Replay,
}
