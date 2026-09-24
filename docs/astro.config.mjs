// @ts-check
import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

// The schema language's TextMate grammar, shared with the editor extensions.
const blinkGrammar = JSON.parse(readFileSync(new URL('./syntax/blink.tmLanguage.json', import.meta.url), 'utf8'));

// Pages moved when the site left Nextra; these keep links in old posts and issues working.
const redirects = {
	'/getting-started/1-installation': '/getting-started/installation',
	'/getting-started/2-introduction': '/getting-started/quick-start',
	'/getting-started/3-cli': '/getting-started/cli',
	'/getting-started/4-plugin': '/getting-started/studio-plugin',
	'/language/1-options': '/language/options',
	'/language/2-scopes': '/language/scopes',
	'/language/3-imports': '/language/imports',
	'/language/4-types': '/language/types',
	'/language/5-events': '/language/events',
	'/language/6-functions': '/language/functions',
	'/language/7-profiles': '/language/profiles',
};

export default defineConfig({
	redirects,
	site: 'https://xopoiii.github.io',
	base: '/BlinkBlox',
	integrations: [
		starlight({
			title: 'BlinkBlox',
			description: 'An IDL compiler for Roblox buffer networking whose generated server is safe to point at the open internet.',
			logo: { src: './src/assets/letter.png' },
			favicon: '/favicon.png',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/XopoIII/BlinkBlox' }],
			editLink: { baseUrl: 'https://github.com/XopoIII/BlinkBlox/edit/main/docs/' },
			lastUpdated: true,
			customCss: ['./src/styles/custom.css'],
			expressiveCode: {
				themes: ['catppuccin-mocha', 'catppuccin-latte'],
				shiki: { langs: [{ ...blinkGrammar, name: 'blink', aliases: ['blinkblox'] }] },
			},
			plugins: [starlightLinksValidator(), starlightLlmsTxt()],
			sidebar: [
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
						'guides/bandwidth',
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
			],
		}),
	],
});
