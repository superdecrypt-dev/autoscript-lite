import { CalendarDays, LocateFixed } from "lucide-react"

import type { AccountSummary } from "@/types/portal"

import { ThemeMenu } from "@/components/theme/theme-menu"
import { Badge } from "@/components/ui/badge"
import { Card } from "@/components/ui/card"
import { activeIpHint, daysLabel, nextAction, protocolLabel, statusVariant } from "@/lib/portal"

export function HeroCard({ summary }: { summary: AccountSummary }) {
  const action = nextAction(summary)
  const problemTitle =
    summary.status === "blocked" ? "Akun diblokir" : summary.status === "expired" ? "Masa aktif habis" : ""

  return (
    <Card className="relative max-w-full overflow-visible p-4 sm:p-7 xl:p-8">
      <div className="absolute inset-0 rounded-[inherit] bg-[radial-gradient(circle_at_top_left,rgba(214,107,34,0.12),transparent_34%),radial-gradient(circle_at_top_right,rgba(242,178,79,0.10),transparent_30%)]" />
      <div className="relative grid min-w-0 gap-4 sm:gap-6 xl:grid-cols-[minmax(0,1.45fr)_minmax(340px,0.95fr)] xl:gap-8">
        <div className="min-w-0 space-y-3 sm:space-y-4 xl:pr-6">
          <div className="flex items-center justify-between gap-3 xl:justify-start">
            <p className="text-xs font-bold uppercase tracking-[0.24em] text-primary">Info Akun</p>
            <div className="xl:hidden">
              <ThemeMenu />
            </div>
          </div>
          <div className="min-w-0 space-y-2.5 sm:space-y-3">
            <h1 className="text-[2rem] font-black tracking-tight text-foreground sm:text-5xl xl:text-[3.8rem]">{summary.username}</h1>
            <p className="max-w-2xl text-xs leading-5 text-muted-foreground sm:text-sm sm:leading-6 xl:max-w-xl">
              Status akun, masa aktif, quota, dan IP aktif.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2 sm:gap-3">
            <Badge variant="accent">{protocolLabel(summary.protocol)}</Badge>
            <Badge variant={statusVariant(summary.status)}>{summary.status}</Badge>
          </div>
          {action.text ? (
            <div
              className={`rounded-[1.1rem] border px-3.5 py-2.5 text-xs font-semibold sm:rounded-[1.25rem] sm:px-4 sm:py-3 sm:text-sm ${
                action.tone === "destructive"
                  ? "border-rose-500/30 bg-rose-500/10 text-rose-700 dark:text-rose-200"
                  : "border-amber-500/30 bg-amber-500/10 text-amber-700 dark:text-amber-200"
              }`}
            >
              {action.text}
            </div>
          ) : null}
          {problemTitle ? (
            <div className="rounded-[1.3rem] border border-amber-500/25 bg-amber-500/8 px-3.5 py-3 text-xs leading-5 text-amber-800 dark:text-amber-100 sm:rounded-[1.5rem] sm:px-4 sm:py-4 sm:text-sm sm:leading-6">
              <p className="font-bold">{problemTitle}</p>
              <p>{summary.status === "blocked" ? "Akses akun dibatasi sampai status dipulihkan." : "Akun tidak bisa dipakai sampai diperpanjang."}</p>
            </div>
          ) : null}
        </div>
        <div className="grid min-w-0 content-start gap-3 sm:grid-cols-2 xl:grid-cols-1 xl:gap-4">
          <div className="hidden xl:flex xl:justify-end">
            <ThemeMenu />
          </div>
          <div className="rounded-[1.35rem] border border-border bg-background/70 p-4 sm:rounded-3xl sm:p-5 xl:p-6">
            <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.18em] text-muted-foreground">
              <CalendarDays className="size-4" />
              Masa Aktif
            </p>
            <p className="mt-2 text-[2rem] font-black tracking-tight text-foreground sm:text-4xl">{daysLabel(summary.days_remaining)}</p>
          </div>
          <div className="rounded-[1.35rem] border border-border bg-background/70 p-4 sm:rounded-3xl sm:p-5 xl:p-6">
            <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.18em] text-muted-foreground">
              <LocateFixed className="size-4" />
              IP Aktif
            </p>
            <p className="mt-2 text-[1.7rem] font-black tracking-tight text-foreground sm:text-3xl">{summary.active_ip}</p>
            <p className="mt-2 text-xs text-muted-foreground sm:text-sm">{activeIpHint(summary)}</p>
          </div>
        </div>
      </div>
    </Card>
  )
}
