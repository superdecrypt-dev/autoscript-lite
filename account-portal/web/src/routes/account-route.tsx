import { lazy, Suspense, useEffect } from "react"
import { AlertTriangle, RefreshCw } from "lucide-react"
import { useParams } from "react-router-dom"

import { AccessCard } from "@/components/portal/access-card"
import { CredentialsCard } from "@/components/portal/credentials-card"
import { HeroCard } from "@/components/portal/hero-card"
import { ImportLinksCard } from "@/components/portal/import-links-card"
import { QuotaCard } from "@/components/portal/quota-card"
import { SummaryCard } from "@/components/portal/summary-card"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useMediaQuery } from "@/hooks/use-media-query"
import { useAccountSummary, useAccountTraffic } from "@/hooks/use-portal-data"

const TrafficCard = lazy(() =>
  import("@/components/portal/traffic-card").then((module) => ({
    default: module.TrafficCard,
  })),
)

export function AccountRoute() {
  const { token } = useParams<{ token: string }>()
  const mobile = useMediaQuery("(max-width: 720px)")
  const summary = useAccountSummary(token)
  const traffic = useAccountTraffic(token, mobile)

  useEffect(() => {
    if (!summary.data) {
      document.title = "Info Akun"
      return
    }
    document.title = `${summary.data.username} | Info Akun`
  }, [summary.data])

  if (!token) {
    return (
      <Card>
        <CardContent className="p-8">
          <p className="text-lg font-semibold text-foreground">Token portal tidak ditemukan.</p>
        </CardContent>
      </Card>
    )
  }

  if (summary.loading && !summary.data) {
    return (
      <Card>
        <CardContent className="flex min-h-64 items-center justify-center p-8 text-muted-foreground">
          <RefreshCw className="mr-3 size-4 animate-spin" />
          Memuat info akun...
        </CardContent>
      </Card>
    )
  }

  if (!summary.data) {
    return (
      <Card>
        <CardContent className="flex min-h-64 items-center justify-center gap-3 p-8 text-destructive">
          <AlertTriangle className="size-4" />
          {summary.error ?? "Portal akun tidak ditemukan."}
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="grid min-w-0 gap-6">
      {(summary.stale || traffic.stale) && (
        <Badge variant="warning" className="w-fit px-4 py-2 normal-case tracking-normal">
          Menampilkan data terakhir. Koneksi API sedang tertunda.
        </Badge>
      )}
      <HeroCard summary={summary.data} />
      <section className="grid min-w-0 grid-cols-1 gap-6 md:grid-cols-2 xl:grid-cols-[minmax(0,1.52fr)_minmax(380px,0.92fr)] xl:items-start 2xl:grid-cols-[minmax(0,1.6fr)_minmax(410px,0.9fr)]">
        <div className="self-start md:col-span-2 xl:col-span-1">
          <Suspense
            fallback={
              <Card>
                <CardHeader className="pb-3">
                  <CardTitle>Traffic Realtime</CardTitle>
                </CardHeader>
                <CardContent className="text-sm text-muted-foreground">Memuat chart traffic…</CardContent>
              </Card>
            }
          >
            <TrafficCard traffic={traffic.data} mobile={mobile} loading={traffic.loading} error={traffic.error} />
          </Suspense>
        </div>
        <div className="grid self-start gap-6 md:col-span-2 xl:col-span-1">
          <SummaryCard summary={summary.data} />
          <QuotaCard summary={summary.data} />
          <CredentialsCard summary={summary.data} />
          <AccessCard summary={summary.data} />
        </div>
        <div className="self-start md:col-span-2 xl:col-span-2">
          <ImportLinksCard summary={summary.data} />
        </div>
      </section>
    </div>
  )
}
