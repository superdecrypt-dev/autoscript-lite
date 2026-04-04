import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function formatBytes(value: number | null | undefined) {
  const amount = Math.max(0, Number(value || 0))
  const units = ["B", "KiB", "MiB", "GiB", "TiB"]
  let index = 0
  let current = amount

  while (current >= 1024 && index < units.length - 1) {
    current /= 1024
    index += 1
  }

  if (index === 0) return `${Math.round(current)} ${units[index]}`
  if (current >= 100) return `${current.toFixed(0)} ${units[index]}`
  if (current >= 10) return `${current.toFixed(1)} ${units[index]}`
  return `${current.toFixed(2)} ${units[index]}`
}

export function formatRate(value: number | null | undefined) {
  return `${formatBytes(value)}/s`
}

export function compactWindowLabel(seconds: number) {
  if (seconds < 60) return `${seconds}s`
  return `${Math.max(1, Math.round(seconds / 60))}m`
}
