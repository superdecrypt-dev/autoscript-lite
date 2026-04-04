import { Copy, Eye, EyeOff, Key, Lock, User } from "lucide-react"
import { useEffect, useState } from "react"

import type { AccountSummary } from "@/types/portal"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"

function copy(value: string) {
  void navigator.clipboard.writeText(value)
}

export function CredentialsCard({ summary }: { summary: AccountSummary }) {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    setVisible(false)
  }, [summary.token, summary.credentials_available, summary.credentials_password])

  if (!summary.credentials_available) return null

  return (
    <Card>
      <CardHeader>
        <CardTitle className="inline-flex items-center gap-2">
          <Key className="size-4" />
          Kredensial
        </CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3 sm:gap-4">
        <section className="rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4">
          <div className="mb-3 flex items-center justify-between gap-3">
            <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
              <User className="size-4" />
              Username
            </p>
            <Button variant="secondary" size="sm" className="h-8 px-3 text-xs sm:h-9 sm:text-sm" onClick={() => copy(summary.credentials_username)}>
              <Copy className="size-4" />
              Copy
            </Button>
          </div>
          <p className="break-all text-base font-bold text-foreground sm:text-lg">{summary.credentials_username}</p>
        </section>

        <section className="rounded-[1.25rem] border border-border bg-background/70 p-3.5 sm:rounded-3xl sm:p-4">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
            <p className="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-muted-foreground">
              <Lock className="size-4" />
              Password
            </p>
            <div className="flex gap-2">
              <Button variant="secondary" size="icon" className="size-8 sm:size-10" onClick={() => setVisible((current) => !current)}>
                {visible ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
              </Button>
              <Button variant="secondary" size="sm" className="h-8 px-3 text-xs sm:h-9 sm:text-sm" onClick={() => copy(summary.credentials_password)}>
                <Copy className="size-4" />
                Copy
              </Button>
            </div>
          </div>
          <p className="break-all font-mono text-base font-bold text-foreground sm:text-lg">
            {visible ? summary.credentials_password : "••••••••"}
          </p>
        </section>
      </CardContent>
    </Card>
  )
}
