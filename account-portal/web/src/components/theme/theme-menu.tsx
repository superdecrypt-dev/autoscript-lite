import { MonitorCog, MoonStar, SunMedium } from "lucide-react"

import { useTheme, type ThemePreference } from "@/hooks/use-theme"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

const options: Array<{
  value: ThemePreference
  label: string
  icon: typeof MonitorCog
}> = [
  { value: "system", label: "System", icon: MonitorCog },
  { value: "dark", label: "Gelap", icon: MoonStar },
  { value: "light", label: "Terang", icon: SunMedium },
]

export function ThemeMenu() {
  const { preference, setPreference } = useTheme()

  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <Button variant="secondary" className="h-9 rounded-full px-3 text-xs uppercase tracking-[0.12em] sm:h-10 sm:px-4 sm:text-sm">
          Tema
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="w-52 border-border/90 bg-card text-card-foreground shadow-[0_18px_40px_rgba(15,8,3,0.14)]"
      >
        <DropdownMenuRadioGroup value={preference} onValueChange={(value) => setPreference(value as ThemePreference)}>
          {options.map((option) => {
            const Icon = option.icon
            return (
              <DropdownMenuRadioItem key={option.value} value={option.value}>
                <span className="inline-flex items-center gap-2 pr-6">
                  <Icon className="size-4" />
                  {option.label}
                </span>
              </DropdownMenuRadioItem>
            )
          })}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
