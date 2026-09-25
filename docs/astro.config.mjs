// @ts-check
import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

// The schema language's TextMate grammar, shared with the editor extensions.
const blinkGrammar = JSON.parse(readFileSync(new URL('./syntax/blink.tmLanguage.json', import.meta.url), 'utf8'));

// Pages moved when the site left Nextra; these keep links in old posts and issues working.
// Astro prefixes the base to the source path but not to the destination, so the destination carries it.
const redirects = {
	'/getting-started/1-installation': '/BlinkBlox/getting-started/installation',
	'/getting-started/2-introduction': '/BlinkBlox/getting-started/quick-start',
	'/getting-started/3-cli': '/BlinkBlox/getting-started/cli',
	'/getting-started/4-plugin': '/BlinkBlox/getting-started/studio-plugin',
	'/language/1-options': '/BlinkBlox/language/options',
	'/language/2-scopes': '/BlinkBlox/language/scopes',
	'/language/3-imports': '/BlinkBlox/language/imports',
	'/language/4-types': '/BlinkBlox/language/types',
	'/language/5-events': '/BlinkBlox/language/events',
	'/language/6-functions': '/BlinkBlox/language/functions',
	'/language/7-profiles': '/BlinkBlox/language/profiles',
};

// The sidebar, in reading order. The llms.txt files below follow the same order.
const sidebar = [
	{
		label: 'Getting Started',
		items: [
			'getting-started/installation',
			'getting-started/quick-start',
			'getting-started/cli',
			'getting-started/studio-plugin',
		],
	},
	{
		label: 'Language',
		items: [
			'language/options',
			'language/scopes',
			'language/imports',
			'language/types',
			'language/events',
			'language/functions',
			'language/profiles',
		],
	},
	{
		label: 'Guides',
		items: [
			'guides/securing-the-server',
			'guides/places-without-a-server',
			'guides/bandwidth',
			'guides/benchmarks',
			'guides/migrating-from-blink',
			'guides/roblox-ts',
			'guides/ai-assistants',
		],
	},
	{
		label: 'Reference',
		items: [
			'reference/generated-api',
			'reference/options',
			'reference/diagnostics',
			'reference/wire-compatibility',
		],
	},
	'changelog',
];

// The plain-text copies of the site for AI assistants; guides/ai-assistants.mdx describes them.
const llmsTxt = {
	details: [
		'BlinkBlox is a maintained fork of Blink, forked at v0.18.8. A schema in the `.blink` language',
		'compiles to a server module, a client module and optionally a types module and TypeScript',
		'definitions, all Luau, that serialise events and functions into buffers. Schema syntax, option',
		'names and defaults differ from upstream Blink and from zap; take them from these pages.',
		'',
		'After writing or changing a schema, run `blinkblox <schema> --check --json`: it compiles without',
		'writing, and prints every diagnostic with its code, file, line and column as one JSON document.',
	].join('\n'),
	// Pages in the sidebar's order; without this they come alphabetically, the changelog second.
	promote: ['index*', ...sidebar.flatMap((entry) => (typeof entry === 'string' ? [entry] : entry.items))],
	// The changelog is the largest page and the benchmark tables the next, and neither is needed to
	// write a schema. The full file keeps them, last; the small one leaves them out.
	demote: ['guides/benchmarks', 'changelog'],
	exclude: ['guides/benchmarks', 'changelog'],
	// A plain <Aside> is a note, and the notes carry rules -- an unranged integer wraps, an exported
	// type cannot hold an Instance -- so the small file keeps them. Tips and collapsed sections go.
	minify: { note: false },
	// CHANGELOG.md's own title repeats the page's; custom.css hides it on the site. Pages start at h2,
	// so it is the only h1 in any page's body, and the selector matcher here takes no combinators.
	customSelectors: { all: ['h1'] },
	optionalLinks: [
		{
			label: 'Changelog',
			url: 'https://xopoiii.github.io/BlinkBlox/changelog/',
			description: 'every release since the fork, with what changed on the wire',
		},
	],
};

export default defineConfig({
	redirects,
	vite: {
		build: {
			rolldownOptions: {
				// Astro marks every MDX page with its own "use astro:head-inject" directive, and Vite 8's
				// bundler warns once per page that it does not know it. Astro reads the directive itself,
				// so only that warning is dropped; every other one still prints.
				onwarn(warning, warn) {
					if (warning.code === 'MODULE_LEVEL_DIRECTIVE' && warning.message.includes('astro:head-inject')) {
						return;
					}
					warn(warning);
				},
			},
		},
	},
	site: 'https://xopoiii.github.io',
	base: '/BlinkBlox',
	integrations: [
		starlight({
			title: 'BlinkBlox',
			// src/pages/404.astro says why.
			disable404Route: true,
			description: 'An IDL compiler for Roblox buffer networking whose generated server is safe to point at the open internet.',
			logo: { src: './src/assets/logo.png', alt: 'BlinkBlox' },
			favicon: '/favicon-32.png',
			head: [
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '192x192', href: '/BlinkBlox/favicon.png' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/BlinkBlox/apple-touch-icon.png' } },
			],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/XopoIII/BlinkBlox' }],
			editLink: { baseUrl: 'https://github.com/XopoIII/BlinkBlox/edit/main/docs/' },
			lastUpdated: true,
			customCss: ['./src/styles/custom.css'],
			expressiveCode: {
				themes: ['catppuccin-mocha', 'catppuccin-latte'],
				shiki: { langs: [{ ...blinkGrammar, name: 'blink', aliases: ['blinkblox'] }] },
			},
			plugins: [starlightLinksValidator(), starlightLlmsTxt(llmsTxt)],
			sidebar,
		}),
	],
});
