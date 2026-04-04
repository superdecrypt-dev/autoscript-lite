import type { AccountSummary, TrafficPayload } from "@/types/portal"

async function request<T>(path: string) {
  const response = await fetch(path, {
    method: "GET",
    headers: {
      Accept: "application/json",
    },
    cache: "no-store",
  })

  if (!response.ok) {
    throw new Error(`Request failed: ${response.status}`)
  }

  return (await response.json()) as T
}

export function getAccountSummary(token: string) {
  return request<AccountSummary>(`/api/account/${token}/summary`)
}

export function getAccountTraffic(token: string) {
  return request<TrafficPayload>(`/api/account/${token}/traffic`)
}
