import path from "node:path"

import tailwindcss from "@tailwindcss/vite"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const portalBase = process.env.PORTAL_WEB_ASSET_BASE || "/account-app/"

// https://vite.dev/config/
export default defineConfig({
  base: portalBase,
  plugins: [react(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes("node_modules/recharts")) {
            return "recharts"
          }
          if (id.includes("node_modules/react-router-dom") || id.includes("node_modules/react-dom") || id.includes("node_modules/react/")) {
            return "react-vendor"
          }
          if (id.includes("node_modules/@radix-ui/")) {
            return "radix-ui"
          }
          if (id.includes("node_modules/lucide-react")) {
            return "icons"
          }
          return undefined
        },
      },
    },
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
})
