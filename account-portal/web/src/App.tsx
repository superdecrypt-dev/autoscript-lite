import { lazy, Suspense } from "react"
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom"

import { AppShell } from "@/app/shell"
import { ThemeProvider } from "@/components/providers/theme-provider"

const AccountRoute = lazy(() =>
  import("@/routes/account-route").then((module) => ({
    default: module.AccountRoute,
  })),
)

function PlaceholderRoute() {
  return (
    <div className="flex min-h-[60svh] items-center justify-center">
      <div className="max-w-xl text-center">
        <p className="text-sm font-bold uppercase tracking-[0.24em] text-primary">Account Portal Web</p>
        <h1 className="mt-4 text-4xl font-black tracking-tight text-foreground">Frontend React siap untuk cutover</h1>
        <p className="mt-4 text-base leading-7 text-muted-foreground">
          Buka route <code className="rounded bg-muted px-2 py-1 text-sm">/account/:token</code> untuk melihat halaman portal
          versi React yang memanggil API backend yang sudah ada.
        </p>
      </div>
    </div>
  )
}

export default function App() {
  return (
    <ThemeProvider>
      <BrowserRouter>
        <AppShell>
          <Suspense fallback={<div className="py-16 text-center text-muted-foreground">Memuat frontend portal...</div>}>
            <Routes>
              <Route path="/" element={<PlaceholderRoute />} />
              <Route path="/account/:token" element={<AccountRoute />} />
              <Route path="/portal-react/account/:token" element={<AccountRoute />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </Suspense>
        </AppShell>
      </BrowserRouter>
    </ThemeProvider>
  )
}
