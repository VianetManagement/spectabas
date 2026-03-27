import "../vendor/chart.umd.js"

const Chart = window.Chart

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
      this.chart.data.datasets[0].pointRadius = data.pageviews.length > 30 ? 0 : 3
      this.chart.data.datasets[1].data = data.visitors
      this.chart.data.datasets[1].pointRadius = data.visitors.length > 30 ? 0 : 3
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

// --- Bubble/Scatter Map ---
export const BubbleMap = {
  mounted() {
    this.chart = null
    this.handleEvent("map-data", (data) => this.setData(data))
  },
  setData(data) {
    if (!data || !data.points || data.points.length === 0) return

    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    const points = data.points.map((p) => ({
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

    // Background plugin: draws a map-like background
    const bgPlugin = {
      id: "mapBackground",
      beforeDraw: (chart) => {
        const { ctx, chartArea } = chart
        if (!chartArea) return
        const { left, top, right, bottom } = chartArea

        // Ocean background
        ctx.save()
        ctx.fillStyle = "#e8f0f8"
        ctx.fillRect(left, top, right - left, bottom - top)

        // Grid lines
        ctx.strokeStyle = "#d0dae6"
        ctx.lineWidth = 0.5
        const xScale = chart.scales.x
        const yScale = chart.scales.y

        // Longitude lines every 60 degrees
        for (let lon = -120; lon <= 120; lon += 60) {
          const x = xScale.getPixelForValue(lon)
          ctx.beginPath()
          ctx.moveTo(x, top)
          ctx.lineTo(x, bottom)
          ctx.stroke()
        }
        // Latitude lines every 30 degrees
        for (let lat = -60; lat <= 60; lat += 30) {
          const y = yScale.getPixelForValue(lat)
          ctx.beginPath()
          ctx.moveTo(left, y)
          ctx.lineTo(right, y)
          ctx.stroke()
        }
        // Equator
        ctx.strokeStyle = "#b0bec9"
        ctx.lineWidth = 1
        const eqY = yScale.getPixelForValue(0)
        ctx.beginPath()
        ctx.moveTo(left, eqY)
        ctx.lineTo(right, eqY)
        ctx.stroke()

        ctx.restore()
      },
    }

    this.chart = new Chart(canvas, {
      type: "bubble",
      plugins: [bgPlugin],
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
