import { Database, HardDrive, PieChart } from "lucide-react"

import type { AccountSummary } from "@/types/portal"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { quotaPercent } from "@/lib/portal"

export function QuotaCard({ summary }: { summary: AccountSummary }) {
  const percent = quotaPercent(summary)
  const tone = percent >= 90 ? "destructive" : percent >= 60 ? "warning" : "success"
  const label = percent >= 90 ? "Hampir Habis" : percent >= 60 ? "Perlu Dipantau" : "Aman"

  return (
    <Card>
      <CardHeader>
        <CardTitle className="inline-flex items-center gap-2">
          <Database className="size-4" />
          Quota
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4 sm:space-y-5 xl:space-y-4 2xl:space-y-5">
        <div className="flex flex-wrap items-center gap-2 sm:gap-3">
          <Badge variant="accent">{percent}% terpakai</Badge>
          <Badge variant={tone}>{label}</Badge>
        </div>
        <div className="h-3 overflow-hidden rounded-full bg-muted">
          <div className="h-full rounded-full bg-primary transition-[width]" style={{ width: `${percent}%` }} />
        </div>
        <dl className="grid gap-4">
          <div className="space-y-1">
            <dt className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
              <Database className="size-4" />
              Limit
            </dt>
            <dd className="break-words text-[1.55rem] font-black tracking-tight text-foreground sm:text-2xl xl:text-[1.8rem] 2xl:text-2xl">{summary.quota_limit}</dd>
          </div>
          <div className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-1 2xl:grid-cols-2">
            <div className="min-w-0 rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4 xl:p-4 2xl:p-4">
              <dt className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                <PieChart className="size-4" />
                Terpakai
              </dt>
              <dd className="mt-2 break-words text-base font-bold leading-tight text-foreground sm:text-xl xl:text-lg 2xl:text-xl">{summary.quota_used}</dd>
            </div>
            <div className="min-w-0 rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4 xl:p-4 2xl:p-4">
              <dt className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                <HardDrive className="size-4" />
                Sisa
              </dt>
              <dd className="mt-2 break-words text-base font-bold leading-tight text-foreground sm:text-xl xl:text-lg 2xl:text-xl">{summary.quota_remaining}</dd>
            </div>
          </div>
        </dl>
      </CardContent>
    </Card>
  )
}
