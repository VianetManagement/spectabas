import "../vendor/chart.umd.js"
import { worldMapPlugin } from "./world_map"

const Chart = window.Chart

Chart.defaults.font.family =
  'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif'
Chart.defaults.font.size = 11
Chart.defaults.plugins.legend.display = false

// --- Timeseries Line Chart ---
export const TimeseriesChart = {
  mounted() {
    this.chart = null

    // Initial data from data-chart attribute (race-free — in the DOM by
    // the time mounted() runs). Fixes the push_event timing race where the
    // server pushes before this hook registers handleEvent.
    const raw = this.el.dataset.chart
    if (raw) {
      try { this.setData(JSON.parse(raw)) } catch (e) { /* empty data is fine */ }
    }

    // Subsequent updates via push_event (metric switch, range change, refresh).
    this.handleEvent("timeseries-data", (data) => this.setData(data))
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    const metric = data.metric || "visitors"
    const isPageviews = metric === "pageviews"
    const values = isPageviews ? data.pageviews : data.visitors
    const label = isPageviews ? "Pageviews" : "Visitors"
    const borderColor = isPageviews ? "#6366f1" : "#10b981"
    const bgColor = isPageviews ? "rgba(99, 102, 241, 0.1)" : "rgba(16, 185, 129, 0.1)"

    if (this.chart) {
      this.chart.data.labels = data.labels
      this.chart.data.datasets = [{
        label: label,
        data: values,
        borderColor: borderColor,
        backgroundColor: bgColor,
        fill: true,
        tension: 0.3,
        pointRadius: values.length > 30 ? 0 : 3,
        pointHoverRadius: 5,
        borderWidth: 2,
      }]
      this.chart.resize()
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "line",
      data: {
        labels: data.labels,
        datasets: [
          {
            label: label,
            data: values,
            borderColor: borderColor,
            backgroundColor: bgColor,
            fill: true,
            tension: 0.3,
            pointRadius: values.length > 30 ? 0 : 3,
            pointHoverRadius: 5,
            borderWidth: 2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        interaction: { intersect: false, mode: "index" },
        scales: {
          x: {
            grid: { display: false },
            ticks: { maxTicksLimit: 8, color: "#9ca3af" },
          },
          y: {
            beginAtZero: true,
            grid: { color: "#f3f4f6" },
            ticks: { color: "#9ca3af", precision: 0 },
          },
        },
        plugins: {
          tooltip: {
            backgroundColor: "#1f2937",
            titleColor: "#f9fafb",
            bodyColor: "#d1d5db",
            padding: 10,
            cornerRadius: 8,
          },
          legend: { display: false },
        },
      },
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}

// --- Horizontal Bar Chart (Timezones) ---
export const BarChart = {
  mounted() {
    this.chart = null
    this.handleEvent("bar-data", (data) => this.setData(data))
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    if (this.chart) {
      this.chart.data.labels = data.labels
      this.chart.data.datasets[0].data = data.values
      this.chart.resize()
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "bar",
      data: {
        labels: data.labels,
        datasets: [
          {
            data: data.values,
            backgroundColor: "#6366f1",
            borderRadius: 4,
            barPercentage: 0.7,
          },
        ],
      },
      options: {
        indexAxis: "y",
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        scales: {
          x: {
            beginAtZero: true,
            grid: { color: "#f3f4f6" },
            ticks: { color: "#9ca3af", precision: 0 },
          },
          y: {
            grid: { display: false },
            ticks: { color: "#374151", font: { size: 12 } },
          },
        },
        plugins: {
          tooltip: {
            backgroundColor: "#1f2937",
            padding: 8,
            cornerRadius: 6,
          },
        },
      },
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}

// --- Ecommerce Revenue + Orders Chart ---
export const EcommerceChart = {
  mounted() {
    this.chart = null
    this.handleEvent("ecommerce-chart-data", (data) => this.setData(data))
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    if (this.chart) {
      this.chart.data.labels = data.labels
      this.chart.data.datasets[0].data = data.revenue
      this.chart.data.datasets[1].data = data.orders
      this.chart.resize()
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "bar",
      data: {
        labels: data.labels,
        datasets: [
          {
            label: "Revenue",
            data: data.revenue,
            backgroundColor: "rgba(16, 185, 129, 0.7)",
            borderColor: "#10b981",
            borderWidth: 1,
            borderRadius: 4,
            yAxisID: "y",
            order: 2,
          },
          {
            label: "Orders",
            data: data.orders,
            type: "line",
            borderColor: "#6366f1",
            backgroundColor: "rgba(99, 102, 241, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: data.orders.length > 30 ? 0 : 3,
            pointHoverRadius: 5,
            borderWidth: 2,
            yAxisID: "y1",
            order: 1,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        interaction: { intersect: false, mode: "index" },
        scales: {
          x: {
            grid: { display: false },
            ticks: { maxTicksLimit: 10, color: "#9ca3af" },
          },
          y: {
            beginAtZero: true,
            position: "left",
            grid: { color: "#f3f4f6" },
            ticks: { color: "#10b981", precision: 0 },
            title: { display: true, text: "Revenue", color: "#10b981", font: { size: 11 } },
          },
          y1: {
            beginAtZero: true,
            position: "right",
            grid: { display: false },
            ticks: { color: "#6366f1", precision: 0 },
            title: { display: true, text: "Orders", color: "#6366f1", font: { size: 11 } },
          },
        },
        plugins: {
          tooltip: {
            backgroundColor: "#1f2937",
            titleColor: "#f9fafb",
            bodyColor: "#d1d5db",
            padding: 10,
            cornerRadius: 8,
          },
          legend: {
            display: true,
            position: "top",
            align: "end",
            labels: {
              usePointStyle: true,
              boxWidth: 20,
              color: "#6b7280",
            },
          },
        },
      },
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}

// --- Bubble/Scatter Map ---
// Region presets for map zoom
const MAP_REGIONS = {
  world:   { x: { min: -180, max: 180 }, y: { min: -70, max: 85 } },
  north_america: { x: { min: -170, max: -50 }, y: { min: 10, max: 75 } },
  south_america: { x: { min: -90, max: -30 }, y: { min: -60, max: 15 } },
  europe:  { x: { min: -15, max: 45 }, y: { min: 35, max: 72 } },
  asia:    { x: { min: 40, max: 150 }, y: { min: 0, max: 65 } },
  africa:  { x: { min: -20, max: 55 }, y: { min: -40, max: 40 } },
  oceania: { x: { min: 100, max: 180 }, y: { min: -50, max: 5 } },
  us:      { x: { min: -130, max: -65 }, y: { min: 24, max: 50 } },
}

export const BubbleMap = {
  mounted() {
    this.chart = null
    this.handleEvent("map-data", (data) => this.setData(data))
    this.handleEvent("map-zoom", ({region}) => this.zoomTo(region))
  },
  zoomTo(region) {
    if (!this.chart) return
    const r = MAP_REGIONS[region] || MAP_REGIONS.world
    this.chart.options.scales.x.min = r.x.min
    this.chart.options.scales.x.max = r.x.max
    this.chart.options.scales.y.min = r.y.min
    this.chart.options.scales.y.max = r.y.max
    this.chart.update()
    // Style active button
    document.querySelectorAll(".map-zoom-btn").forEach(btn => {
      btn.className = "px-2 py-1 text-xs rounded-md bg-gray-100 text-gray-600 hover:bg-gray-200 map-zoom-btn"
    })
    const active = document.getElementById("map-btn-" + region)
    if (active) active.className = "px-2 py-1 text-xs rounded-md bg-indigo-600 text-white map-zoom-btn"
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    const points = (data && data.points || []).map((p) => ({
      x: p.lon,
      y: p.lat,
      r: Math.max(4, Math.sqrt(p.visitors) * 4),
      label: p.label,
      visitors: p.visitors,
    }))

    if (this.chart) {
      this.chart.data.datasets[0].data = points
      this.chart.resize()
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "bubble",
      plugins: [worldMapPlugin],
      data: {
        datasets: [
          {
            data: points,
            backgroundColor: "rgba(99, 102, 241, 0.5)",
            borderColor: "rgba(79, 70, 229, 0.7)",
            borderWidth: 1.5,
            hoverBackgroundColor: "rgba(99, 102, 241, 0.8)",
            hoverBorderWidth: 2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        scales: {
          x: {
            min: -180,
            max: 180,
            grid: { display: false },
            ticks: { display: false },
            border: { display: false },
          },
          y: {
            min: -70,
            max: 85,
            grid: { display: false },
            ticks: { display: false },
            border: { display: false },
          },
        },
        plugins: {
          worldMap: {
            fillColor: "#e2e8f0",
            strokeColor: "#cbd5e1",
            lineWidth: 0.5,
          },
          tooltip: {
            backgroundColor: "#1f2937",
            titleColor: "#f9fafb",
            bodyColor: "#d1d5db",
            padding: 10,
            cornerRadius: 8,
            callbacks: {
              title: () => "",
              label: (ctx) => {
                const p = ctx.raw
                return `${p.label}: ${p.visitors} visitors`
              },
            },
          },
        },
      },
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}

// --- Core Web Vitals Timeseries (dual-axis: ms left, CLS right) ---
export const VitalsChart = {
  mounted() {
    this.chart = null

    const raw = this.el.dataset.chart
    if (raw) {
      try { this.setData(JSON.parse(raw)) } catch (e) { /* ok */ }
    }

    this.handleEvent("vitals-data", (data) => this.setData(data))
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas || !data || !data.labels) return

    const datasets = [
      {
        label: "LCP (ms)",
        data: data.lcp,
        borderColor: "#6366f1",
        backgroundColor: "rgba(99, 102, 241, 0.1)",
        fill: false,
        tension: 0.3,
        pointRadius: data.labels.length > 20 ? 0 : 3,
        pointHoverRadius: 5,
        borderWidth: 2,
        yAxisID: "y",
      },
      {
        label: "FID (ms)",
        data: data.fid,
        borderColor: "#f59e0b",
        backgroundColor: "rgba(245, 158, 11, 0.1)",
        fill: false,
        tension: 0.3,
        pointRadius: data.labels.length > 20 ? 0 : 3,
        pointHoverRadius: 5,
        borderWidth: 2,
        yAxisID: "y",
      },
      {
        label: "CLS",
        data: data.cls,
        borderColor: "#10b981",
        backgroundColor: "rgba(16, 185, 129, 0.1)",
        fill: false,
        tension: 0.3,
        pointRadius: data.labels.length > 20 ? 0 : 3,
        pointHoverRadius: 5,
        borderWidth: 2,
        borderDash: [5, 3],
        yAxisID: "y1",
      },
    ]

    if (this.chart) {
      this.chart.data.labels = data.labels
      this.chart.data.datasets = datasets
      this.chart.resize()
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "line",
      data: { labels: data.labels, datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 300 },
        interaction: { intersect: false, mode: "index" },
        scales: {
          x: {
            grid: { display: false },
            ticks: { maxTicksLimit: 8, color: "#9ca3af" },
          },
          y: {
            type: "linear",
            position: "left",
            beginAtZero: true,
            title: { display: true, text: "ms", color: "#9ca3af", font: { size: 11 } },
            grid: { color: "#f3f4f6" },
            ticks: { color: "#9ca3af", precision: 0 },
          },
          y1: {
            type: "linear",
            position: "right",
            beginAtZero: true,
            title: { display: true, text: "CLS", color: "#10b981", font: { size: 11 } },
            grid: { drawOnChartArea: false },
            ticks: { color: "#10b981" },
          },
        },
        plugins: {
          tooltip: {
            backgroundColor: "#1f2937",
            titleColor: "#f9fafb",
            bodyColor: "#d1d5db",
            padding: 10,
            cornerRadius: 8,
            callbacks: {
              label: function(ctx) {
                const v = ctx.parsed.y
                if (ctx.dataset.yAxisID === "y1") return `${ctx.dataset.label}: ${v}`
                return `${ctx.dataset.label}: ${Math.round(v)}ms`
              }
            },
          },
          legend: {
            display: true,
            position: "top",
            labels: { usePointStyle: true, pointStyle: "line", padding: 16, font: { size: 11 } },
          },
        },
      },
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}
