import { ChevronDown, Globe2, Link2, Network } from "lucide-react"
import { useState } from "react"

import type { AccountSummary } from "@/types/portal"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog"
import { useMediaQuery } from "@/hooks/use-media-query"

export function AccessCard({ summary }: { summary: AccountSummary }) {
  const [open, setOpen] = useState(false)
  const mobile = useMediaQuery("(max-width: 720px)")
  const portDetails = summary.access_details.filter((item) => !item.label.includes("Path") && !item.label.includes("Service"))
  const pathDetails = summary.access_details.filter((item) => item.label.includes("Path") || item.label.includes("Service"))

  return (
    <Card className="lg:col-span-2">
      <CardHeader>
        <CardTitle className="inline-flex items-center gap-2">
          <Globe2 className="size-4" />
          Info Akses
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 sm:space-y-4">
        <div className="space-y-1">
          <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
            <Globe2 className="size-4" />
            Domain
          </p>
          <p className="break-all text-base font-bold text-foreground sm:text-lg">{summary.access_domain}</p>
        </div>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button variant="secondary" className="h-9 w-full justify-between rounded-full px-3 text-xs sm:h-10 sm:px-4 sm:text-sm">
              Lihat Info Akses
              <ChevronDown className={`size-4 transition ${open ? "rotate-180" : ""}`} />
            </Button>
          </DialogTrigger>
          <DialogContent mobileSheet={mobile} className={mobile ? "gap-4" : "max-w-[46rem] gap-5"}>
            {mobile ? <div className="mx-auto h-1.5 w-14 rounded-full bg-border/80" /> : null}
            <DialogHeader>
              <DialogTitle className="inline-flex items-center gap-2 text-base font-bold uppercase tracking-[0.18em] text-muted-foreground">
                <Globe2 className="size-4" />
                Info Akses
              </DialogTitle>
            </DialogHeader>
            <div className="grid max-h-[calc(82svh-7rem)] gap-4 overflow-y-auto pr-1">
              <section className="rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4">
                <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                  <Globe2 className="size-4" />
                  Domain
                </p>
                <p className="mt-3 break-all text-sm font-semibold text-foreground sm:text-base">{summary.access_domain}</p>
              </section>
              <section className="rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4">
                <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                  <Network className="size-4" />
                  Port
                </p>
                <div className="mt-3 grid gap-3">
                  {portDetails.length > 0 ? (
                    portDetails.map((item) => (
                      <div key={`${item.label}-${item.value}`} className="grid gap-1 border-b border-border/70 pb-3 last:border-b-0 last:pb-0">
                        <p className="text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">{item.label}</p>
                        <p className="text-sm font-semibold text-foreground">{item.value}</p>
                      </div>
                    ))
                  ) : (
                    <p className="text-sm font-semibold text-foreground">{summary.access_ports || "-"}</p>
                  )}
                </div>
              </section>
              <section className="rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4">
                <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                  <Link2 className="size-4" />
                  Path & Service
                </p>
                <div className="mt-3 grid gap-3">
                  {pathDetails.length > 0 ? (
                    pathDetails.map((item) => (
                      <div key={`${item.label}-${item.value}`} className="grid gap-1 border-b border-border/70 pb-3 last:border-b-0 last:pb-0">
                        <p className="text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">{item.label}</p>
                        <p className="text-sm font-semibold text-foreground">{item.value}</p>
                      </div>
                    ))
                  ) : (
                    <p className="text-sm font-semibold text-foreground">{summary.access_path || "-"}</p>
                  )}
                </div>
              </section>
            </div>
          </DialogContent>
        </Dialog>
      </CardContent>
    </Card>
  )
}
