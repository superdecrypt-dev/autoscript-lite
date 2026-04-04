import * as TabsPrimitive from "@radix-ui/react-tabs"

import { cn } from "@/lib/utils"

export const Tabs = TabsPrimitive.Root

export function TabsList({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.List>) {
  return (
    <TabsPrimitive.List
      className={cn("flex min-w-0 max-w-full flex-nowrap gap-1 rounded-full border border-border bg-muted/60 p-1", className)}
      {...props}
    />
  )
}

export function TabsTrigger({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Trigger>) {
  return (
    <TabsPrimitive.Trigger
      className={cn(
        "inline-flex shrink-0 whitespace-nowrap min-w-[4.25rem] items-center justify-center rounded-full px-3 py-1.5 text-xs font-semibold text-muted-foreground transition sm:min-w-16 sm:px-4 sm:py-2 sm:text-sm data-[state=active]:bg-primary data-[state=active]:text-primary-foreground",
        className,
      )}
      {...props}
    />
  )
}

export function TabsContent({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Content>) {
  return <TabsPrimitive.Content className={cn("mt-4 min-w-0 max-w-full", className)} {...props} />
}
