import { Copy, Download, Link2 } from "lucide-react"
import { useEffect, useState } from "react"

import type { AccountSummary } from "@/types/portal"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"

function copy(value: string) {
  void navigator.clipboard.writeText(value)
}

export function ImportLinksCard({ summary }: { summary: AccountSummary }) {
  if (summary.import_links.length === 0) return null

  const defaultValue =
    summary.import_links.find((item) => item.label.toLowerCase() === "websocket")?.label ?? summary.import_links[0]?.label
  const [selectedValue, setSelectedValue] = useState(defaultValue)

  useEffect(() => {
    if (!summary.import_links.some((item) => item.label === selectedValue)) {
      setSelectedValue(defaultValue)
    }
  }, [defaultValue, selectedValue, summary.import_links])

  return (
    <Card className="min-w-0 lg:col-span-2">
      <CardHeader>
        <CardTitle className="inline-flex items-center gap-2">
          <Link2 className="size-4" />
          Link Import
        </CardTitle>
      </CardHeader>
      <CardContent className="min-w-0">
        <Tabs value={selectedValue} onValueChange={setSelectedValue}>
          <TabsList
            className="w-full justify-start overflow-x-auto overflow-y-hidden border-primary/10 bg-muted/40 p-1.5 [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden"
          >
            {summary.import_links.map((item, index) => (
              <TabsTrigger
                key={item.label}
                value={item.label}
                className="flex-none px-3 py-2 text-center transition-[transform,box-shadow,background-color,color] duration-200 ease-out hover:-translate-y-0.5 hover:shadow-[0_10px_24px_rgba(15,8,3,0.08)] data-[state=active]:shadow-[0_14px_32px_rgba(214,107,34,0.22)]"
                style={{
                  animation: `import-chip-in 420ms cubic-bezier(0.22, 1, 0.36, 1) both`,
                  animationDelay: `${index * 45}ms`,
                }}
              >
                {item.label}
              </TabsTrigger>
            ))}
          </TabsList>
          {summary.import_links.map((item) => (
            <TabsContent key={item.label} value={item.label} className="min-w-0">
              <div className="min-w-0 rounded-[1.25rem] border border-primary/20 bg-background/80 p-3.5 [animation:import-pane-in_260ms_cubic-bezier(0.22,1,0.36,1)] sm:rounded-[1.75rem] sm:p-5">
                <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-start sm:justify-between">
                  <div className="min-w-0">
                    <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
                      <Link2 className="size-4" />
                      Mode Aktif
                    </p>
                    <h3 className="mt-2 text-xl font-black tracking-tight text-foreground sm:text-2xl">{item.label}</h3>
                  </div>
                  <div className="flex w-full flex-col gap-2 sm:w-auto sm:flex-row">
                    {summary.protocol === "vless" &&
                    summary.xray_json_available &&
                    item.label === "VLESS XHTTP/3 (UDP/QUIC)" ? (
                      <Button
                        asChild
                        variant="outline"
                        className="h-9 w-full text-xs transition-[transform,box-shadow] duration-200 ease-out hover:-translate-y-0.5 hover:shadow-[0_12px_26px_rgba(214,107,34,0.14)] sm:h-10 sm:w-auto sm:text-sm"
                      >
                        <a href={summary.xray_json_url} download>
                          <Download className="size-4" />
                          Unduh Xray JSON
                        </a>
                      </Button>
                    ) : null}
                    <Button className="h-9 w-full text-xs transition-[transform,box-shadow] duration-200 ease-out hover:-translate-y-0.5 hover:shadow-[0_12px_26px_rgba(214,107,34,0.2)] sm:h-10 sm:w-auto sm:text-sm" onClick={() => copy(item.url)}>
                      <Copy className="size-4" />
                      Copy Link
                    </Button>
                  </div>
                </div>
                <p className="mt-4 max-w-full overflow-hidden rounded-[1.1rem] border border-border bg-card/80 p-3 font-mono text-[11px] leading-6 text-foreground [overflow-wrap:anywhere] sm:rounded-3xl sm:p-4 sm:text-sm">
                  {item.url}
                </p>
              </div>
            </TabsContent>
          ))}
        </Tabs>
      </CardContent>
    </Card>
  )
}
