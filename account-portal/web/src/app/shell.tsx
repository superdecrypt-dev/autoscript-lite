import type { PropsWithChildren } from "react"

export function AppShell({ children }: PropsWithChildren) {
  return (
    <div className="min-h-svh overflow-x-clip bg-background text-foreground">
      <div className="mx-auto flex min-h-svh w-full min-w-0 max-w-[1480px] flex-col px-4 py-5 sm:px-6 lg:px-8 lg:py-7 xl:px-10">
        {children}
      </div>
    </div>
  )
}
