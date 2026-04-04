import path from "node:path"

import tailwindcss from "@tailwindcss/vite"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const portalBase = process.env.PORTAL_WEB_ASSET_BASE || "/account-app/"

// https://vite.dev/config/
export default defineConfig({
  base: portalBase,
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
})
