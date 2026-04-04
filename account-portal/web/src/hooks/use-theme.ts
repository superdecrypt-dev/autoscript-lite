import { createContext, useContext } from "react"

export type ThemePreference = "system" | "light" | "dark"

export type ThemeContextValue = {
  preference: ThemePreference
  resolvedTheme: "light" | "dark"
  setPreference: (value: ThemePreference) => void
}

export const ThemeContext = createContext<ThemeContextValue | null>(null)

export function useTheme() {
  const value = useContext(ThemeContext)
  if (!value) {
    throw new Error("useTheme must be used inside ThemeProvider")
  }
  return value
}
