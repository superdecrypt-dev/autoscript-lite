import { cva, type VariantProps } from "class-variance-authority"
import type * as React from "react"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "inline-flex items-center rounded-full border px-3 py-1 text-xs font-bold uppercase tracking-[0.14em]",
  {
    variants: {
      variant: {
        default: "border-border bg-secondary text-secondary-foreground",
        success: "border-emerald-500/35 bg-emerald-500/10 text-emerald-700 dark:text-emerald-200",
        warning: "border-amber-500/35 bg-amber-500/10 text-amber-700 dark:text-amber-200",
        destructive: "border-rose-500/35 bg-rose-500/10 text-rose-700 dark:text-rose-200",
        accent: "border-primary/35 bg-primary/10 text-primary",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
)

export interface BadgeProps extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

export function Badge({ className, variant, ...props }: BadgeProps) {
  return <div className={cn(badgeVariants({ variant }), className)} {...props} />
}
