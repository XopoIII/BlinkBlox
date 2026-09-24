import React from 'react'
import { useRouter } from "next/router"
import { DocsThemeConfig } from 'nextra-theme-docs'

const config: DocsThemeConfig = {
  useNextSeoProps() {
		const { asPath } = useRouter()
		if (asPath !== "/") {
			return {
				titleTemplate: "%s – BlinkBlox",
			}
		}
	},
  logo: (
      <>
        <img
          width="40"
          height="40"
          src="https://raw.githubusercontent.com/XopoIII/BlinkBlox/main/docs/public/letter.png"
        />
      </>
  ),
  project: {
    link: 'https://github.com/XopoIII/BlinkBlox',
  },
  docsRepositoryBase: 'https://github.com/XopoIII/BlinkBlox',
  footer: {
    text: 'BlinkBlox — MIT licensed. Originally by Axen, maintained fork by XopoIII.',
  },
  head: (
    <>
      <link rel="shortcut icon" href="https://raw.githubusercontent.com/XopoIII/BlinkBlox/main/docs/public/letter.png" type="img/png"/>
      <meta property="og:description" content="An IDL compiler written in Luau for ROBLOX buffer networking." />
    </>
  )
}

export default config
