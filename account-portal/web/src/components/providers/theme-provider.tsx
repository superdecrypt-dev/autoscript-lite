import { type PropsWithChildren, useEffect, useMemo, useState } from "react"

import { ThemeContext, type ThemePreference } from "@/hooks/use-theme"

const STORAGE_KEY = "autoscript-account-portal-theme"

function resolveTheme(preference: ThemePreference, systemDark: boolean) {
  if (preference === "system") {
    return systemDark ? "dark" : "light"
  }

  return preference
}

export function ThemeProvider({ children }: PropsWithChildren) {
  const [preference, setPreference] = useState<ThemePreference>(() => {
    if (typeof document === "undefined") return "system"
    const stored = document.documentElement.dataset.themePreference
    return stored === "light" || stored === "dark" || stored === "system" ? stored : "system"
  })
  const [systemDark, setSystemDark] = useState(() => {
    if (typeof document === "undefined") return false
    return document.documentElement.classList.contains("dark")
  })

  useEffect(() => {
    if (typeof window === "undefined") return

    const media = window.matchMedia("(prefers-color-scheme: dark)")
    setSystemDark(media.matches)

    const handleChange = (event: MediaQueryListEvent) => {
      setSystemDark(event.matches)
    }

    media.addEventListener("change", handleChange)
    return () => media.removeEventListener("change", handleChange)
  }, [])

  const resolvedTheme = resolveTheme(preference, systemDark)

  useEffect(() => {
    if (typeof document === "undefined") return
    document.documentElement.classList.toggle("dark", resolvedTheme === "dark")
    document.documentElement.dataset.themePreference = preference
    document.documentElement.style.colorScheme = resolvedTheme
  }, [preference, resolvedTheme])

  const value = useMemo(
    () => ({
      preference,
      resolvedTheme,
      setPreference: (nextPreference: ThemePreference) => {
        setPreference(nextPreference)
        if (typeof window !== "undefined") {
          window.localStorage.setItem(STORAGE_KEY, nextPreference)
        }
      },
    }),
    [preference, resolvedTheme],
  )

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}
