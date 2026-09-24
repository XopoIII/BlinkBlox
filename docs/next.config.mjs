import { readFileSync } from 'fs'
import nextra from 'nextra'
import { BUNDLED_LANGUAGES, getHighlighter } from 'shiki'

const withNextra = nextra({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
  mdxOptions: {
     rehypePrettyCodeOptions: {
      // Catppuccin Mocha, applied in both site themes — and `styles/globals.css` keeps the block's
      // background dark to match, which is the fix for upstream issue #60.
      //
      // The bug was that this dark palette was painted onto whatever background Nextra chose: in
      // light mode that meant dark-theme tokens on a light block, which is unreadable. Keeping the
      // block dark makes the pairing correct again.
      //
      // A true light palette (Catppuccin Latte ships alongside this file) needs rehype-pretty-code
      // >= 0.10 for its `theme: { light, dark }` form. Nextra 2.13 pins 0.9.11, which reads that
      // object as a single theme, and forcing a newer one pulls in shiki v1 — whose API this config
      // and Nextra 2 both predate (`BUNDLED_LANGUAGES` no longer exists). That is a Nextra 3/4
      // migration, not a config change.
      theme: JSON.parse(
        readFileSync('./public/syntax/mocha.json', 'utf8')
      ),
      getHighlighter: options =>
        getHighlighter({
          ...options,
          langs: [
            ...BUNDLED_LANGUAGES,
            {
              id: 'blink',
              scopeName: 'source.blink',
              aliases: [],
              path: '../../public/syntax/blink.tmLanguage.json'
            }
          ]
        })
    }
  }
})

export default withNextra({
  output: "export",
  basePath: "/BlinkBlox",
  images: {unoptimized: true}
})
