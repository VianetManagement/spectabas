import {
  Chart,
  LineController,
  BarController,
  BubbleController,
  LineElement,
  BarElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend,
} from "chart.js"

Chart.register(
  LineController,
  BarController,
  BubbleController,
  LineElement,
  BarElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend
)

Chart.defaults.font.family =
  'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif'
Chart.defaults.font.size = 11
Chart.defaults.plugins.legend.display = false

// --- Timeseries Line Chart ---
export const TimeseriesChart = {
  mounted() {
    this.chart = null
    this.handleEvent("timeseries-data", (data) => this.setData(data))
  },
  setData(data) {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    if (this.chart) {
      this.chart.data.labels = data.labels
      this.chart.data.datasets[0].data = data.pageviews
      this.chart.data.datasets[1].data = data.visitors
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "line",
      data: {
        labels: data.labels,
        datasets: [
          {
            label: "Pageviews",
            data: data.pageviews,
            borderColor: "#6366f1",
            backgroundColor: "rgba(99, 102, 241, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: data.pageviews.length > 30 ? 0 : 3,
            pointHoverRadius: 5,
            borderWidth: 2,
          },
          {
            label: "Visitors",
            data: data.visitors,
            borderColor: "#10b981",
            backgroundColor: "rgba(16, 185, 129, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: data.visitors.length > 30 ? 0 : 3,
            pointHoverRadius: 5,
            borderWidth: 2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
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
          legend: {
            display: true,
            position: "top",
            align: "end",
            labels: {
              usePointStyle: true,
              pointStyle: "line",
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

// --- Bubble/Scatter Map ---
export const BubbleMap = {
  mounted() {
    this.chart = null
    this.handleEvent("map-data", (data) => this.setData(data))
  },
  setData(data) {
    if (!data || !data.points) return

    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    const points = data.points.map((p) => ({
      x: p.lon,
      y: p.lat,
      r: Math.max(3, Math.sqrt(p.visitors) * 3),
      label: p.label,
      visitors: p.visitors,
    }))

    if (this.chart) {
      this.chart.data.datasets[0].data = points
      this.chart.update()
      return
    }

    this.chart = new Chart(canvas, {
      type: "bubble",
      data: {
        datasets: [
          {
            data: points,
            backgroundColor: "rgba(99, 102, 241, 0.4)",
            borderColor: "rgba(79, 70, 229, 0.6)",
            borderWidth: 1,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: {
            min: -180,
            max: 180,
            grid: { color: "#e5e7eb" },
            ticks: { display: false },
          },
          y: {
            min: -70,
            max: 85,
            grid: { color: "#e5e7eb" },
            ticks: { display: false },
          },
        },
        plugins: {
          tooltip: {
            backgroundColor: "#1f2937",
            padding: 10,
            cornerRadius: 8,
            callbacks: {
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
