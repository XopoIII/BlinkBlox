import type { AppProps } from "next/app"

// Exists solely to load the global stylesheet: Next.js only allows a global CSS import from here.
// The stylesheet picks between the light and dark syntax palettes emitted by rehype-pretty-code.
import "../styles/globals.css"

export default function App({ Component, pageProps }: AppProps) {
	return <Component {...pageProps} />
}
