import { CalendarClock, CalendarDays, FileText, Gauge, LocateFixed, Shield } from "lucide-react"
import type * as React from "react"

import type { AccountSummary } from "@/types/portal"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { activeIpHint, daysLabel, protocolLabel, statusVariant } from "@/lib/portal"

function Item({ label, value, note, icon }: { label: string; value: string; note?: string; icon?: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <dt className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
        {icon}
        {label}
      </dt>
      <dd className="text-base font-bold text-foreground sm:text-lg">{value}</dd>
      {note ? <p className="text-xs text-muted-foreground sm:text-sm">{note}</p> : null}
    </div>
  )
}

export function SummaryCard({ summary }: { summary: AccountSummary }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="inline-flex items-center gap-2">
          <FileText className="size-4" />
          Ringkasan
        </CardTitle>
      </CardHeader>
      <CardContent>
        <dl className="grid gap-4 sm:gap-6">
          <div className="flex flex-wrap gap-2 sm:gap-3">
            <Badge variant="accent">{protocolLabel(summary.protocol)}</Badge>
            <Badge variant={statusVariant(summary.status)}>{summary.status}</Badge>
          </div>
          <Item label="Berlaku Sampai" value={summary.valid_until} icon={<CalendarClock className="size-4" />} />
          <Item label="Masa Aktif" value={daysLabel(summary.days_remaining)} icon={<CalendarDays className="size-4" />} />
          <Item label="Limit IP" value={summary.ip_limit_text} icon={<Shield className="size-4" />} />
          <Item label="Limit Speed" value={summary.speed_limit_text} icon={<Gauge className="size-4" />} />
          <Item label="IP Aktif" value={summary.active_ip} note={activeIpHint(summary)} icon={<LocateFixed className="size-4" />} />
        </dl>
      </CardContent>
    </Card>
  )
}
