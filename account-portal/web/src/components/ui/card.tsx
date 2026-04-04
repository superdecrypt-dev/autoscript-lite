import * as React from "react"

import { cn } from "@/lib/utils"

export function Card({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "min-w-0 max-w-full rounded-[1.6rem] border border-border bg-card/95 shadow-[0_18px_52px_rgba(15,8,3,0.08)] backdrop-blur-sm sm:rounded-3xl sm:shadow-[0_24px_80px_rgba(15,8,3,0.12)]",
        className,
      )}
      {...props}
    />
  )
}

export function CardHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("min-w-0 flex flex-col gap-2 p-5 sm:p-6", className)} {...props} />
}

export function CardTitle({ className, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h3 className={cn("text-base font-bold uppercase tracking-[0.18em] text-muted-foreground", className)} {...props} />
}

export function CardDescription({ className, ...props }: React.HTMLAttributes<HTMLParagraphElement>) {
  return <p className={cn("text-sm text-muted-foreground", className)} {...props} />
}

export function CardContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("min-w-0 px-5 pb-5 sm:px-6 sm:pb-6", className)} {...props} />
}
