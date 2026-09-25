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
			],
		}),
	],
});
