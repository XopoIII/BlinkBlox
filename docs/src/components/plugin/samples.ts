// Generated, not hand-written: the highlighted lines are the output of the plugin's own highlighter
// (plugin/src/Editor/Highlight.luau with the palette in plugin/src/Editor/Theme.luau), and the
// diagnostics are what src/Modules/Error.luau renders when it runs inside Roblox, captured from the
// compiler for these exact sources. Regenerate them the same way rather than editing by hand.

/** The template a place starts with (plugin/src/Files.luau). */
export const template = {
	source: "type Example = u8\nevent MyEvent {\n\tFrom: Server,\n\tType: Reliable,\n\tCall: SingleSync,\n\tData: Example\n}",
	lines: [
		"<font color=\"#6796E6\">type</font> <font color=\"#9CDCFE\">Example</font> = <font color=\"#4EC9B0\">u8</font>",
		"<font color=\"#6796E6\">event</font> <font color=\"#9CDCFE\">MyEvent</font> <font color=\"#FFFFFF\">{</font>",
		"\t<font color=\"#FFFFFF\">From</font>: <font color=\"#9CDCFE\">Server</font>,",
		"\t<font color=\"#FFFFFF\">Type</font>: <font color=\"#9CDCFE\">Reliable</font>,",
		"\t<font color=\"#FFFFFF\">Call</font>: <font color=\"#9CDCFE\">SingleSync</font>,",
		"\t<font color=\"#FFFFFF\">Data</font>: <font color=\"#9CDCFE\">Example</font>",
		"<font color=\"#FFFFFF\">}</font>"
	],
};

/** A struct being typed: the field type is half-written. */
export const typing = {
	source: "type Health = u8(0..100)\n\nstruct Hit {\n\tTarget: Instance(Player),\n\tDamage: u\n}",
	lines: [
		"<font color=\"#6796E6\">type</font> <font color=\"#9CDCFE\">Health</font> = <font color=\"#4EC9B0\">u8</font>(<font color=\"#B5CEA8\">0</font>..<font color=\"#B5CEA8\">100</font>)",
		"",
		"<font color=\"#6796E6\">struct</font> <font color=\"#9CDCFE\">Hit</font> <font color=\"#FFFFFF\">{</font>",
		"\t<font color=\"#FFFFFF\">Target</font>: <font color=\"#4EC9B0\">Instance</font>(<font color=\"#B5CEA8\">Player</font>),",
		"\t<font color=\"#FFFFFF\">Damage</font>: <font color=\"#9CDCFE\">u</font>",
		"<font color=\"#FFFFFF\">}</font>"
	],
	diagnostic: {
		severity: "Error" as const,
		name: "AnalyzeUnknownReference",
		code: 3007,
		message: "Unknown reference",
		label: "Unknown reference",
		line: 5,
		/** The whole diagnostic as the compiler renders it inside Roblox (rich text). */
		rendered: "<font color=\"rgb(255, 0, 0)\">[E3007] Error</font>: Unknown reference\n    ╭-[input.blink:1:6]\n    |\n005 | \tDamage: u\n               <font color=\"rgb(255, 0, 0)\"></font><font color=\"rgb(255, 0, 0)\">-</font><font color=\"rgb(255, 0, 0)\"></font>\n               <font color=\"rgb(255, 0, 0)\">|</font>\n               <font color=\"rgb(255, 0, 0)\">╰--</font> <font color=\"rgb(255, 0, 0)\">Unknown reference</font>\n    |\n----╯\n",
	},
};

/** A schema with a misspelt reference on line 14. */
export const error = {
	source: "option DefaultRate = 30\n\ntype Health = u8(0..100)\n\nstruct Hit {\n\tTarget: Instance(Player),\n\tDamage: u16(0..500)\n}\n\nevent Damage {\n\tFrom: Client,\n\tType: Reliable,\n\tCall: SingleSync,\n\tData: Hitt\n}",
	lines: [
		"<font color=\"#6796E6\">option</font> <font color=\"#9CDCFE\">DefaultRate</font> = 30",
		"",
		"<font color=\"#6796E6\">type</font> <font color=\"#9CDCFE\">Health</font> = <font color=\"#4EC9B0\">u8</font>(<font color=\"#B5CEA8\">0</font>..<font color=\"#B5CEA8\">100</font>)",
		"",
		"<font color=\"#6796E6\">struct</font> <font color=\"#9CDCFE\">Hit</font> <font color=\"#FFFFFF\">{</font>",
		"\t<font color=\"#FFFFFF\">Target</font>: <font color=\"#4EC9B0\">Instance</font>(<font color=\"#B5CEA8\">Player</font>),",
		"\t<font color=\"#FFFFFF\">Damage</font>: <font color=\"#4EC9B0\">u16</font>(<font color=\"#B5CEA8\">0</font>..<font color=\"#B5CEA8\">500</font>)",
		"<font color=\"#FFFFFF\">}</font>",
		"",
		"<font color=\"#6796E6\">event</font> <font color=\"#9CDCFE\">Damage</font> <font color=\"#FFFFFF\">{</font>",
		"\t<font color=\"#FFFFFF\">From</font>: <font color=\"#9CDCFE\">Client</font>,",
		"\t<font color=\"#FFFFFF\">Type</font>: <font color=\"#9CDCFE\">Reliable</font>,",
		"\t<font color=\"#FFFFFF\">Call</font>: <font color=\"#9CDCFE\">SingleSync</font>,",
		"\t<font color=\"#FFFFFF\">Data</font>: <font color=\"#9CDCFE\">Hitt</font>",
		"<font color=\"#FFFFFF\">}</font>"
	],
	diagnostic: {
		severity: "Error" as const,
		name: "AnalyzeUnknownReference",
		code: 3007,
		message: "Unknown reference",
		label: "Unknown reference",
		line: 14,
		/** The whole diagnostic as the compiler renders it inside Roblox (rich text). */
		rendered: "<font color=\"rgb(255, 0, 0)\">[E3007] Error</font>: Unknown reference\n    ╭-[input.blink:1:15]\n    |\n014 | \tData: Hitt\n             <font color=\"rgb(255, 0, 0)\">--</font><font color=\"rgb(255, 0, 0)\">-</font><font color=\"rgb(255, 0, 0)\">--</font>\n               <font color=\"rgb(255, 0, 0)\">|</font>\n               <font color=\"rgb(255, 0, 0)\">╰--</font> <font color=\"rgb(255, 0, 0)\">Unknown reference</font>\n    |\n----╯\n",
	},
};

/** A schema that rate-limits an event the server sends. */
export const warning = {
	source: "type Health = u8(0..100)\n\nevent HealthChanged {\n\tFrom: Server,\n\tType: Unreliable,\n\tCall: SingleSync,\n\tRate: 10,\n\tData: Health\n}",
	lines: [
		"<font color=\"#6796E6\">type</font> <font color=\"#9CDCFE\">Health</font> = <font color=\"#4EC9B0\">u8</font>(<font color=\"#B5CEA8\">0</font>..<font color=\"#B5CEA8\">100</font>)",
		"",
		"<font color=\"#6796E6\">event</font> <font color=\"#9CDCFE\">HealthChanged</font> <font color=\"#FFFFFF\">{</font>",
		"\t<font color=\"#FFFFFF\">From</font>: <font color=\"#9CDCFE\">Server</font>,",
		"\t<font color=\"#FFFFFF\">Type</font>: <font color=\"#9CDCFE\">Unreliable</font>,",
		"\t<font color=\"#FFFFFF\">Call</font>: <font color=\"#9CDCFE\">SingleSync</font>,",
		"\t<font color=\"#FFFFFF\">Rate</font>: 10,",
		"\t<font color=\"#FFFFFF\">Data</font>: <font color=\"#9CDCFE\">Health</font>",
		"<font color=\"#FFFFFF\">}</font>"
	],
	diagnostic: {
		severity: "Warning" as const,
		name: "AnalyzeMissingRateLimit",
		code: 3020,
		message: "Rate limiting a Server event has no effect",
		label: "This event is sent BY the server, not to it",
		line: 3,
		/** The whole diagnostic as the compiler renders it inside Roblox (rich text). */
		rendered: "<font color=\"rgb(255, 255, 0)\">[W3020] Warning</font>: Rate limiting a Server event has no effect\n    ╭-[input.blink:1:9]\n    |\n003 | event HealthChanged {\n            <font color=\"rgb(255, 255, 0)\">------</font><font color=\"rgb(255, 255, 0)\">-</font><font color=\"rgb(255, 255, 0)\">------</font>\n                  <font color=\"rgb(255, 255, 0)\">|</font>\n                  <font color=\"rgb(255, 255, 0)\">╰--</font> <font color=\"rgb(255, 255, 0)\">This event is sent BY the server, not to it</font>\n    | = note: Rate and concurrency limits apply to inbound traffic only. Remove the field.\n    |\n----╯\n",
	},
};
