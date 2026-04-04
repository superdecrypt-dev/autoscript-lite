import { Activity, AlertTriangle, ArrowDownToLine, ArrowUpFromLine, Gauge, RefreshCw, TrendingUp } from "lucide-react"
import { useId, useMemo, useState } from "react"
import { Area, CartesianGrid, ComposedChart, Line, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"

import { useTheme } from "@/hooks/use-theme"
import type { TrafficPayload } from "@/types/portal"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { compactWindowLabel, formatRate } from "@/lib/utils"

type SeriesKey = "total" | "down" | "up"

type ChartPoint = {
  ts: string
  total: number
  down: number
  up: number
}

type ChartPalette = {
  total: string
  totalSoft: string
  totalGlow: string
  down: string
  downSoft: string
  up: string
  upSoft: string
  grid: string
  tick: string
  cursor: string
  dotFill: string
}

const FALLBACK_WINDOWS = [60, 300, 900]
const SERIES_KEYS: SeriesKey[] = ["total", "down", "up"]

function percentile(sortedValues: number[], ratio: number): number {
  if (!sortedValues.length) return 0
  const index = (sortedValues.length - 1) * ratio
  const lower = Math.floor(index)
  const upper = Math.ceil(index)
  const weight = index - lower
  const lowerValue = sortedValues[lower] ?? 0
  const upperValue = sortedValues[upper] ?? lowerValue
  return lowerValue + (upperValue - lowerValue) * weight
}

function buildChartDomain(points: ChartPoint[], mobile: boolean, activeSeries: SeriesKey[]): [number, number] {
  if (!points.length) return [0, 1]

  const values = points.flatMap((point) =>
    activeSeries
      .map((series) => point[series])
      .filter((value) => Number.isFinite(value) && value > 0),
  )

  if (!values.length) return [0, 1]

  const sortedTotals = [...values].sort((left, right) => left - right)
  if (mobile) {
    const p88 = percentile(sortedTotals, 0.88)
    const max = sortedTotals.at(-1) ?? 1
    return [0, Math.max(p88 * 1.18, max * 0.56, 1)]
  }

  const p94 = percentile(sortedTotals, 0.94)
  const max = sortedTotals.at(-1) ?? 1
  return [0, Math.max(p94 * 1.12, max * 0.72, 1)]
}

function chartPoints(payload: TrafficPayload): ChartPoint[] {
  return payload.points.map((point) => ({
    ts: new Date(point.ts * 1000).toLocaleTimeString("id-ID", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }),
    total: point.total_rate_bps ?? point.rate_bps,
    down: point.down_rate_bps,
    up: point.up_rate_bps,
  }))
}

function TerminalTrafficDot({
  cx,
  cy,
  payload,
  index,
  pointsLength,
  stroke,
  fill,
}: {
  cx?: number
  cy?: number
  payload?: ChartPoint
  index?: number
  pointsLength: number
  stroke: string
  fill: string
}) {
  if (!payload || !payload.total || payload.total <= 0 || cx == null || cy == null || index !== pointsLength - 1) {
    return null
  }

  return (
    <g>
      <circle cx={cx} cy={cy} r={7.5} fill={stroke} fillOpacity={0.18} />
      <circle cx={cx} cy={cy} r={4.2} stroke={stroke} strokeWidth={2.4} fill={fill} />
    </g>
  )
}

function formatScaleTick(value: number) {
  const amount = Math.max(0, Number(value || 0))

  if (amount >= 1024 ** 3) {
    return `${(amount / 1024 ** 3).toFixed(1)} GiB`
  }

  if (amount >= 1024 ** 2) {
    const current = amount / 1024 ** 2
    return `${current >= 10 ? current.toFixed(0) : current.toFixed(1)} MiB`
  }

  if (amount >= 1024) {
    const current = amount / 1024
    return `${current >= 10 ? current.toFixed(0) : current.toFixed(1)} KiB`
  }

  return `${Math.round(amount)} B`
}

export function TrafficCard({
  traffic,
  mobile,
  loading,
  error,
}: {
  traffic: TrafficPayload | null
  mobile: boolean
  loading: boolean
  error: string | null
}) {
  const { resolvedTheme } = useTheme()
  const chartId = useId().replace(/:/g, "")
  const defaultWindow = traffic?.default_window_seconds ?? 300
  const [selectedWindow, setSelectedWindow] = useState(defaultWindow)
  const [seriesVisibility, setSeriesVisibility] = useState<Record<SeriesKey, boolean>>({
    total: true,
    down: true,
    up: true,
  })
  const availableWindows = traffic?.available_windows?.length ? traffic.available_windows : FALLBACK_WINDOWS
  const resolvedWindow = availableWindows.includes(selectedWindow)
    ? selectedWindow
    : availableWindows.includes(defaultWindow)
      ? defaultWindow
      : availableWindows[0]!
  const supportsSplit = traffic?.supports_split !== false
  const availableSeries = supportsSplit ? SERIES_KEYS : (["total"] as SeriesKey[])
  const activeSeries = availableSeries.filter((series) => seriesVisibility[series])
  const resolvedActiveSeries = activeSeries.length ? activeSeries : availableSeries

  const points = useMemo(() => {
    if (!traffic) return []
    const all = chartPoints(traffic)
    if (all.length === 0) return []
    const lastTs = traffic.points.at(-1)?.ts ?? 0
    const cutoff = lastTs - resolvedWindow
    return all.filter((_, index) => (traffic.points[index]?.ts ?? 0) >= cutoff)
  }, [resolvedWindow, traffic])

  const currentDown = traffic?.current_down_rate_text ?? "0 B/s"
  const currentUp = traffic?.current_up_rate_text ?? "0 B/s"
  const peak = points.length ? formatRate(Math.max(...points.map((point) => point.total))) : "0 B/s"
  const avg = points.length ? formatRate(points.reduce((sum, point) => sum + point.total, 0) / points.length) : "0 B/s"
  const hasTraffic = points.some((point) => point.total > 0 || point.down > 0 || point.up > 0)
  const latestSample = points.at(-1)?.ts ?? "Belum ada sampel"
  const [plotDomainBottom, plotDomainTop] = useMemo(
    () => buildChartDomain(points, mobile, resolvedActiveSeries),
    [mobile, points, resolvedActiveSeries],
  )
  const curveType: "linear" | "monotone" = mobile ? "linear" : "monotone"
  const showLoadingState = loading && !traffic
  const showErrorState = Boolean(error) && !traffic
  const showIdleState = !showLoadingState && !showErrorState && !hasTraffic
  const emptyTitle = traffic?.active ? "Koneksi aktif, belum ada transfer" : "Belum ada traffic realtime"
  const emptyDescription = traffic?.active
    ? "Akun sedang terhubung, tetapi belum ada download atau upload pada window yang dipilih."
    : "Grafik akan terisi otomatis saat akun mulai download atau upload data."
  const palette: ChartPalette =
    resolvedTheme === "dark"
      ? {
          total: "#fff1d6",
          totalSoft: "#f6c98a",
          totalGlow: "rgba(255, 241, 214, 0.22)",
          down: "#f2b24f",
          downSoft: "#b96c24",
          up: "#d66b22",
          upSoft: "#8f4317",
          grid: "rgba(255,226,194,0.10)",
          tick: "rgba(255,223,190,0.74)",
          cursor: "rgba(255,226,194,0.36)",
          dotFill: "#20140e",
        }
      : {
          total: "#5b3116",
          totalSoft: "#b26428",
          totalGlow: "rgba(91, 49, 22, 0.18)",
          down: "#d98f36",
          downSoft: "#a75d20",
          up: "#9f4e1a",
          upSoft: "#6d3210",
          grid: "rgba(151,94,49,0.14)",
          tick: "rgba(95,55,26,0.72)",
          cursor: "rgba(151,94,49,0.28)",
          dotFill: "#ffffff",
        }
  const chartShellStyle =
    resolvedTheme === "dark"
      ? {
          borderColor: "rgba(124,74,34,0.34)",
          background: "linear-gradient(180deg, rgba(51,34,23,0.98), rgba(23,15,11,0.96))",
          boxShadow: "inset 0 1px 0 rgba(255,232,204,0.05), 0 26px 58px rgba(9,6,4,0.3)",
        }
      : {
          borderColor: "rgba(180,91,31,0.16)",
          background: "linear-gradient(180deg, rgba(255,250,244,0.98), rgba(246,235,220,0.96))",
          boxShadow: "inset 0 1px 0 rgba(255,255,255,0.92), 0 22px 48px rgba(151,94,49,0.14)",
        }
  const chartGlowStyle =
    resolvedTheme === "dark"
      ? {
          background:
            "radial-gradient(circle at top left, rgba(242,178,79,0.14), transparent 28%), radial-gradient(circle at top right, rgba(214,107,34,0.16), transparent 24%), linear-gradient(180deg, rgba(255,255,255,0.02), transparent 32%)",
        }
      : {
          background:
            "radial-gradient(circle at top left, rgba(217,143,54,0.12), transparent 28%), radial-gradient(circle at top right, rgba(159,78,26,0.12), transparent 24%), linear-gradient(180deg, rgba(255,255,255,0.28), transparent 32%)",
        }

  const toggleSeries = (series: SeriesKey) => {
    if (!availableSeries.includes(series)) return

    setSeriesVisibility((current) => {
      const enabledCount = availableSeries.filter((item) => current[item]).length
      if (current[series] && enabledCount === 1) {
        return current
      }

      return {
        ...current,
        [series]: !current[series],
      }
    })
  }

  return (
    <Card className="h-full overflow-hidden">
      <CardHeader className="gap-3 pb-4">
        <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
          <div className="space-y-1">
            <CardTitle>Traffic Realtime</CardTitle>
            <p className="text-xs text-muted-foreground sm:text-sm">
              {traffic?.active ? "Traffic realtime terdeteksi untuk akun ini." : "Belum ada traffic realtime untuk akun ini."}
            </p>
          </div>
          <Badge variant={traffic?.active ? "success" : "warning"} className="w-fit rounded-full px-3 py-1.5 text-[11px] sm:text-xs">
            <Activity className="mr-1 size-3.5" />
            {traffic?.active ? "Sedang aktif" : "Tidak ada traffic saat ini"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div className="grid grid-cols-3 gap-2 sm:flex sm:flex-wrap">
            {availableWindows.map((seconds) => {
              const active = resolvedWindow === seconds
              return (
                <Button
                  key={seconds}
                  variant={active ? "default" : "secondary"}
                  size="sm"
                  className={`h-9 rounded-full px-3 text-xs transition-all sm:px-4 sm:text-sm ${
                    active
                      ? "shadow-[0_12px_28px_rgba(214,107,34,0.22)]"
                      : "border border-border/70 bg-background/80 text-foreground hover:bg-background"
                  }`}
                  onClick={() => setSelectedWindow(seconds)}
                >
                  {compactWindowLabel(seconds)}
                </Button>
              )
            })}
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">
          <Stat
            label="Download"
            value={currentDown}
            caption="Saat ini"
            icon={<ArrowDownToLine className="size-4" />}
            dark={resolvedTheme === "dark"}
          />
          <Stat
            label="Upload"
            value={currentUp}
            caption="Saat ini"
            icon={<ArrowUpFromLine className="size-4" />}
            dark={resolvedTheme === "dark"}
          />
          <Stat
            label="Peak"
            value={peak}
            caption="Puncak window"
            icon={<TrendingUp className="size-4" />}
            dark={resolvedTheme === "dark"}
          />
          <Stat
            label="Avg"
            value={avg}
            caption="Rata-rata window"
            icon={<Gauge className="size-4" />}
            dark={resolvedTheme === "dark"}
          />
        </div>
        <div className="relative overflow-hidden rounded-[1.45rem] border sm:rounded-[1.9rem]" style={chartShellStyle}>
          <div className="pointer-events-none absolute inset-0" style={chartGlowStyle} />
          {showLoadingState ? (
            <div className="relative flex h-40 flex-col items-center justify-center px-4 text-center sm:h-80">
              <RefreshCw className="size-5 animate-spin text-primary sm:size-6" />
              <p className="mt-3 text-sm font-bold text-slate-900 dark:text-slate-50 sm:text-base">Memuat traffic realtime</p>
              <p className="mt-1 max-w-xs text-[11px] leading-5 text-slate-500 dark:text-slate-400 sm:text-sm">
                Data traffic sedang diambil dari Xray API.
              </p>
            </div>
          ) : showErrorState ? (
            <div className="relative flex h-40 flex-col items-center justify-center px-4 text-center sm:h-80">
              <div className="flex size-10 items-center justify-center rounded-full bg-rose-500/12 text-rose-300 sm:size-12">
                <AlertTriangle className="size-4 sm:size-5" />
              </div>
              <p className="mt-3 text-sm font-bold text-slate-900 dark:text-slate-50 sm:text-base">Traffic realtime belum tersedia</p>
              <p className="mt-1 max-w-xs text-[11px] leading-5 text-slate-500 dark:text-slate-400 sm:text-sm">
                {error ?? "Permintaan traffic gagal. Coba tunggu refresh berikutnya."}
              </p>
            </div>
          ) : hasTraffic ? (
            <div className="relative">
              <div
                className={`relative z-10 flex flex-col gap-3 border-b px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-5 sm:py-4 ${
                  resolvedTheme === "dark"
                    ? "border-white/6 bg-white/[0.02]"
                    : "border-[rgba(151,94,49,0.10)] bg-white/35"
                }`}
              >
                <div className="flex flex-wrap items-center gap-2 sm:gap-3">
                  <SeriesToggleChip
                    label="Total"
                    tone="total"
                    palette={palette}
                    dark={resolvedTheme === "dark"}
                    mobile={mobile}
                    active={resolvedActiveSeries.includes("total")}
                    onClick={() => toggleSeries("total")}
                  />
                  {supportsSplit ? (
                    <>
                      <SeriesToggleChip
                        label="Download"
                        tone="down"
                        palette={palette}
                        dark={resolvedTheme === "dark"}
                        mobile={mobile}
                        active={resolvedActiveSeries.includes("down")}
                        onClick={() => toggleSeries("down")}
                      />
                      <SeriesToggleChip
                        label="Upload"
                        tone="up"
                        palette={palette}
                        dark={resolvedTheme === "dark"}
                        mobile={mobile}
                        active={resolvedActiveSeries.includes("up")}
                        onClick={() => toggleSeries("up")}
                      />
                    </>
                  ) : null}
                </div>
              </div>
              <div className="h-52 px-2 pb-2 pt-2 sm:h-[25rem] sm:px-4 sm:pb-4 sm:pt-3">
                <ResponsiveContainer width="100%" height="100%" minWidth={280} minHeight={mobile ? 188 : 336} debounce={80}>
                  <ComposedChart
                    data={points}
                    margin={{
                      top: mobile ? 10 : 14,
                      right: mobile ? 6 : 12,
                      left: mobile ? 0 : 6,
                      bottom: mobile ? 10 : 16,
                    }}
                  >
                    <defs>
                      <linearGradient id={`traffic-total-fill-${chartId}`} x1="0" x2="0" y1="0" y2="1">
                        <stop offset="0%" stopColor={palette.totalSoft} stopOpacity={mobile ? 0.34 : 0.28} />
                        <stop offset="52%" stopColor={palette.total} stopOpacity={mobile ? 0.16 : 0.10} />
                        <stop offset="100%" stopColor={palette.total} stopOpacity={0.02} />
                      </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="4 6" stroke={palette.grid} strokeOpacity={0.92} vertical={false} />
                    <XAxis
                      dataKey="ts"
                      tickLine={false}
                      axisLine={false}
                      minTickGap={mobile ? 40 : 26}
                      height={mobile ? 30 : 38}
                      tickMargin={mobile ? 10 : 14}
                      tick={{ fontSize: mobile ? 10 : 12, fill: palette.tick }}
                    />
                    <YAxis
                      domain={[plotDomainBottom, plotDomainTop]}
                      allowDataOverflow={mobile}
                      tickFormatter={(value) => formatScaleTick(Number(value))}
                      tickLine={false}
                      axisLine={false}
                      width={mobile ? 42 : 62}
                      tickMargin={mobile ? 6 : 10}
                      padding={{ top: mobile ? 8 : 12, bottom: mobile ? 8 : 12 }}
                      tick={{ fontSize: mobile ? 10 : 12, fill: palette.tick }}
                      tickCount={mobile ? 3 : 5}
                    />
                    <Tooltip
                      cursor={{ stroke: palette.cursor, strokeDasharray: "4 6", strokeOpacity: 0.85 }}
                      content={<TrafficTooltip palette={palette} mobile={mobile} activeSeries={resolvedActiveSeries} />}
                    />
                    {mobile ? (
                      <>
                        {resolvedActiveSeries.includes("total") ? (
                          <>
                            <Area
                              type="monotone"
                              dataKey="total"
                              stroke={palette.total}
                              fill={`url(#traffic-total-fill-${chartId})`}
                              strokeWidth={3.2}
                              strokeOpacity={0.98}
                              fillOpacity={1}
                              dot={false}
                              activeDot={false}
                              isAnimationActive={false}
                            />
                            <Line
                              type="monotone"
                              dataKey="total"
                              stroke={palette.total}
                              strokeWidth={3.6}
                              strokeLinecap="round"
                              strokeLinejoin="round"
                              dot={(props) => (
                                <TerminalTrafficDot
                                  {...props}
                                  pointsLength={points.length}
                                  stroke={palette.totalSoft}
                                  fill={palette.dotFill}
                                />
                              )}
                              activeDot={false}
                              isAnimationActive={false}
                            />
                          </>
                        ) : null}
                        {resolvedActiveSeries.includes("down") ? (
                          <Line
                            type="monotone"
                            dataKey="down"
                            stroke={palette.down}
                            strokeWidth={2.2}
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            dot={false}
                            activeDot={false}
                            isAnimationActive={false}
                          />
                        ) : null}
                        {resolvedActiveSeries.includes("up") ? (
                          <Line
                            type="monotone"
                            dataKey="up"
                            stroke={palette.up}
                            strokeWidth={2}
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            dot={false}
                            activeDot={false}
                            isAnimationActive={false}
                          />
                        ) : null}
                      </>
                    ) : (
                      <>
                        {resolvedActiveSeries.includes("total") ? (
                          <>
                            <Area
                              type={curveType}
                              dataKey="total"
                              stroke={palette.total}
                              fill={`url(#traffic-total-fill-${chartId})`}
                              strokeWidth={3.2}
                              dot={false}
                              activeDot={{ r: 5, fill: palette.dotFill, stroke: palette.total, strokeWidth: 2 }}
                            />
                            <Line
                              type={curveType}
                              dataKey="total"
                              stroke={palette.totalGlow}
                              strokeWidth={8}
                              strokeOpacity={0.22}
                              dot={false}
                              activeDot={false}
                            />
                          </>
                        ) : null}
                        {resolvedActiveSeries.includes("down") ? (
                          <Line
                            type={curveType}
                            dataKey="down"
                            stroke={palette.down}
                            strokeWidth={2.2}
                            dot={false}
                            activeDot={false}
                          />
                        ) : null}
                        {resolvedActiveSeries.includes("up") ? (
                          <Line
                            type={curveType}
                            dataKey="up"
                            stroke={palette.up}
                            strokeWidth={2.0}
                            dot={false}
                            activeDot={false}
                          />
                        ) : null}
                      </>
                    )}
                  </ComposedChart>
                </ResponsiveContainer>
              </div>
              <div
                className={`relative z-10 flex flex-wrap items-center justify-between gap-2 border-t px-4 py-3 text-[10px] sm:px-5 sm:text-xs ${
                  resolvedTheme === "dark"
                    ? "border-white/6 text-[#d6c1af]"
                    : "border-[rgba(151,94,49,0.10)] text-[#7a5a42]"
                }`}
              >
                <span>{compactWindowLabel(resolvedWindow)} terakhir</span>
                <span>Update {latestSample}</span>
              </div>
            </div>
          ) : showIdleState ? (
            <div className="relative flex h-40 flex-col items-center justify-center px-4 text-center sm:h-80">
              <div className="flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary sm:size-12">
                <Activity className="size-4 sm:size-5" />
              </div>
              <p className="mt-3 text-sm font-bold text-slate-900 dark:text-slate-50 sm:text-base">{emptyTitle}</p>
              <p className="mt-1 max-w-xs text-[11px] leading-5 text-slate-500 dark:text-slate-400 sm:text-sm">{emptyDescription}</p>
            </div>
          ) : null}
        </div>
      </CardContent>
    </Card>
  )
}

function SeriesToggleChip({
  label,
  tone,
  palette,
  dark,
  mobile,
  active,
  onClick,
}: {
  label: string
  tone: "down" | "up" | "total"
  palette: ChartPalette
  dark: boolean
  mobile: boolean
  active: boolean
  onClick: () => void
}) {
  const color = tone === "down" ? palette.down : tone === "up" ? palette.up : palette.total

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`inline-flex items-center rounded-full border font-bold uppercase tracking-[0.08em] transition-all ${
        mobile ? "gap-1.5 px-2.5 py-1.5 text-[10px]" : "gap-2 px-3 py-1.5 text-[10px]"
      } ${
        active
          ? dark
            ? "border-white/10 bg-white/10 text-[#fff3e1] shadow-[0_12px_24px_rgba(0,0,0,0.18)]"
            : "border-[rgba(151,94,49,0.16)] bg-white text-[#5f381f] shadow-[0_10px_20px_rgba(151,94,49,0.08)]"
          : dark
            ? "border-white/6 bg-white/[0.03] text-[#cdb79f] opacity-80"
            : "border-[rgba(151,94,49,0.10)] bg-white/58 text-[#8b6a53] opacity-85"
      }`}
    >
      <span
        className={mobile ? "size-2 rounded-full" : "size-2.5 rounded-full"}
        style={{
          backgroundColor: color,
          boxShadow: `0 0 0 4px ${dark ? "rgba(255,255,255,0.04)" : "rgba(255,255,255,0.5)"}`,
          opacity: active ? 1 : 0.68,
        }}
      />
      {label}
    </button>
  )
}

function TrafficTooltip({
  active,
  payload,
  label,
  palette,
  mobile,
  activeSeries,
}: {
  active?: boolean
  payload?: Array<{ dataKey?: string; value?: number; payload?: ChartPoint }>
  label?: string
  palette: ChartPalette
  mobile: boolean
  activeSeries: SeriesKey[]
}) {
  if (!active || !payload?.length) return null

  const point = payload[0]?.payload
  const down = point?.down ?? 0
  const up = point?.up ?? 0
  const total = point?.total ?? Number(down) + Number(up)

  return (
    <div
      className={`rounded-[1rem] border border-[rgba(151,94,49,0.18)] bg-[rgba(255,251,245,0.96)] text-slate-900 shadow-[0_18px_40px_rgba(151,94,49,0.18)] backdrop-blur dark:border-[rgba(246,201,138,0.18)] dark:bg-[rgba(32,20,14,0.96)] dark:text-[#fff6ec] dark:shadow-[0_22px_45px_rgba(0,0,0,0.34)] ${
        mobile ? "min-w-[160px] p-2.5" : "min-w-[190px] p-3"
      }`}
    >
      <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-[#8d5a35] dark:text-[#d9b08b]">{label}</p>
      <div className={`space-y-2 ${mobile ? "mt-2.5 text-[13px]" : "mt-3 text-sm"}`}>
        {activeSeries.includes("total") ? <TooltipRow label="Total" value={formatRate(Number(total))} color={palette.total} /> : null}
        {activeSeries.includes("down") ? <TooltipRow label="Download" value={formatRate(Number(down))} color={palette.down} /> : null}
        {activeSeries.includes("up") ? <TooltipRow label="Upload" value={formatRate(Number(up))} color={palette.up} /> : null}
      </div>
    </div>
  )
}

function TooltipRow({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="inline-flex items-center gap-2 text-[#6f4526] dark:text-[#edd9c5]">
        <span className="size-2 rounded-full" style={{ backgroundColor: color }} />
        {label}
      </span>
      <span className="font-semibold text-[#2b180d] dark:text-[#fff7ee]">{value}</span>
    </div>
  )
}

function Stat({
  label,
  value,
  caption,
  icon,
  dark,
}: {
  label: string
  value: string
  caption?: string
  icon?: React.ReactNode
  dark: boolean
}) {
  return (
    <div
      className="min-w-0 rounded-[1.25rem] border p-3.5 sm:rounded-3xl sm:p-4"
      style={
        dark
          ? {
              borderColor: "rgba(124,74,34,0.38)",
              background: "linear-gradient(180deg, rgba(56,38,27,0.96), rgba(28,19,14,0.94))",
              boxShadow: "inset 0 1px 0 rgba(255,232,204,0.05), 0 18px 34px rgba(0,0,0,0.28)",
            }
          : {
              borderColor: "hsl(var(--border) / 0.8)",
              background: "linear-gradient(180deg, rgba(255,255,255,0.94), rgba(250,245,239,0.9))",
              boxShadow: "inset 0 1px 0 rgba(255,255,255,0.7), 0 18px 34px rgba(24,14,7,0.05)",
            }
      }
    >
      <p className={`flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] ${dark ? "text-[#d7b18d]" : "text-muted-foreground"}`}>
        {icon}
        {label}
      </p>
      <p className={`mt-2 break-all text-[1.55rem] font-black tracking-tight sm:text-2xl ${dark ? "text-[#fff3e2]" : "text-foreground"}`}>{value}</p>
      {caption ? (
        <p className={`mt-1 text-[11px] font-medium ${dark ? "text-[#c8b29d]" : "text-[#7d644e]"}`}>{caption}</p>
      ) : null}
    </div>
  )
}
