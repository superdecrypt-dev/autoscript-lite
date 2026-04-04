import { useEffect, useMemo, useRef, useState } from "react"

import { getAccountSummary, getAccountTraffic } from "@/lib/api"
import type { AccountSummary, TrafficPayload } from "@/types/portal"

type QueryState<T> = {
  data: T | null
  loading: boolean
  error: string | null
  stale: boolean
}

function usePollingQuery<T>({
  enabled,
  baseDelay,
  maxDelay,
  queryKey,
  fetcher,
}: {
  enabled: boolean
  baseDelay: number
  maxDelay: number
  queryKey: string
  fetcher: () => Promise<T>
}) {
  const [state, setState] = useState<QueryState<T>>({
    data: null,
    loading: enabled,
    error: null,
    stale: false,
  })

  const timeoutRef = useRef<number | null>(null)
  const delayRef = useRef(baseDelay)
  const visibleRef = useRef(typeof document === "undefined" ? true : !document.hidden)

  useEffect(() => {
    if (!enabled) {
      setState({
        data: null,
        loading: false,
        error: null,
        stale: false,
      })
      return
    }

    let cancelled = false
    delayRef.current = baseDelay
    visibleRef.current = typeof document === "undefined" ? true : !document.hidden

    const clearTimer = () => {
      if (timeoutRef.current) {
        window.clearTimeout(timeoutRef.current)
        timeoutRef.current = null
      }
    }

    const schedule = (delay: number) => {
      clearTimer()
      timeoutRef.current = window.setTimeout(run, delay)
    }

    const run = async () => {
      if (!visibleRef.current) {
        delayRef.current = Math.min(maxDelay, Math.max(delayRef.current, baseDelay * 5))
        schedule(delayRef.current)
        return
      }

      try {
        const payload = await fetcher()
        if (cancelled) return

        delayRef.current = baseDelay
        setState({
          data: payload,
          loading: false,
          error: null,
          stale: false,
        })
      } catch (error) {
        if (cancelled) return

        delayRef.current = Math.min(maxDelay, Math.round(delayRef.current * 1.8))
        setState((current) => ({
          data: current.data,
          loading: false,
          error: error instanceof Error ? error.message : "Unknown error",
          stale: current.data !== null,
        }))
      } finally {
        if (!cancelled) {
          schedule(delayRef.current)
        }
      }
    }

    setState({
      data: null,
      loading: true,
      error: null,
      stale: false,
    })
    run()

    const handleVisibilityChange = () => {
      visibleRef.current = !document.hidden
      if (visibleRef.current) {
        delayRef.current = baseDelay
        clearTimer()
        void run()
      }
    }

    document.addEventListener("visibilitychange", handleVisibilityChange)

    return () => {
      cancelled = true
      clearTimer()
      document.removeEventListener("visibilitychange", handleVisibilityChange)
    }
  }, [enabled, baseDelay, maxDelay, fetcher, queryKey])

  return state
}

export function useAccountSummary(token: string | undefined) {
  const enabled = Boolean(token)
  const fetcher = useMemo(() => () => getAccountSummary(token ?? ""), [token])

  return usePollingQuery<AccountSummary>({
    enabled,
    baseDelay: 15_000,
    maxDelay: 60_000,
    queryKey: `summary:${token ?? ""}`,
    fetcher,
  })
}

export function useAccountTraffic(token: string | undefined, mobile: boolean) {
  const enabled = Boolean(token)
  const fetcher = useMemo(() => () => getAccountTraffic(token ?? ""), [token])

  return usePollingQuery<TrafficPayload>({
    enabled,
    baseDelay: 1_000,
    maxDelay: 30_000,
    queryKey: `traffic:${token ?? ""}:${mobile ? "mobile" : "desktop"}`,
    fetcher,
  })
}
