// Roblox rich text, as the plugin writes it, turned into HTML for the mockups.
//
// The plugin's highlighter and the compiler's diagnostics both produce `<font color=...>` markup for
// a TextLabel. The mockups show that markup as it is, so what a reader sees here is what the plugin
// actually paints, not a second tokeniser's opinion of it.

/** Converts the tags Roblox rich text uses into HTML spans. Anything else passes through. */
export function toHtml(rich: string): string {
	return rich
		.replace(/<font color="#([0-9A-Fa-f]{6})">/g, '<span style="color:#$1">')
		.replace(/<font color="rgb\((\d+), (\d+), (\d+)\)">/g, '<span style="color:rgb($1 $2 $3)">')
		.replace(/<font transparency="([\d.]+)">/g, (_, t: string) => `<span style="opacity:${1 - Number(t)}">`)
		.replace(/<\/font>/g, '</span>');
}

export type Insertion = {
	/** Visible characters before the insertion point; a tab counts as one, as it does in the source. */
	column: number;
	/**
	 * `open` lands after any tags in front of that character, so it sits inside the token's colour;
	 * `close` lands straight after the previous character, before any tag that closes it.
	 */
	side: 'open' | 'close';
	html: string;
};

/** Inserts HTML into a line of rich text at visible-character columns, keeping it well nested. */
export function insert(rich: string, insertions: Insertion[]): string {
	// Stable: two insertions at the same point keep the order they were given in.
	const pending = [...insertions].sort(
		(a, b) => a.column - b.column || (a.side === b.side ? 0 : a.side === 'close' ? -1 : 1),
	);
	let out = '';
	let column = 0;
	let i = 0;

	const flush = (side: 'open' | 'close') => {
		while (pending.length > 0 && pending[0].column === column && pending[0].side === side) {
			out += pending.shift()!.html;
		}
	};

	while (i < rich.length) {
		flush('close');
		if (rich[i] === '<') {
			const end = rich.indexOf('>', i);
			out += rich.slice(i, end + 1);
			i = end + 1;
			continue;
		}

		flush('open');
		const entity = rich[i] === '&' ? /^&[a-z]+;/.exec(rich.slice(i)) : null;
		const length = entity ? entity[0].length : 1;
		out += rich.slice(i, i + length);
		i += length;
		column += 1;
	}

	flush('close');
	flush('open');
	return out;
}
