// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

import { TimeseriesChart, BarChart, BubbleMap, EcommerceChart } from "./charts"

// WebAuthn passkey registration hook
const PasskeyRegister = {
  mounted() {
    const options = JSON.parse(this.el.dataset.options)

    // Decode base64url fields for WebAuthn API
    options.challenge = bufferDecode(options.challenge)
    options.user.id = bufferDecode(options.user.id)
    if (options.excludeCredentials) {
      options.excludeCredentials = options.excludeCredentials.map((c) => ({
        ...c,
        id: bufferDecode(c.id),
      }))
    }

    navigator.credentials
      .create({ publicKey: options })
      .then((credential) => {
        const name = prompt("Name this security key:", "My Passkey") || "Security Key"
        this.pushEvent("passkey_registered", {
          attestation_object: bufferEncode(credential.response.attestationObject),
          client_data_json: bufferEncode(credential.response.clientDataJSON),
          name: name,
        })
      })
      .catch((err) => {
        console.error("Passkey registration failed:", err)
      })
  },
}

function bufferDecode(base64url) {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/")
  const pad = base64.length % 4 === 0 ? "" : "=".repeat(4 - (base64.length % 4))
  const binary = atob(base64 + pad)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes.buffer
}

function bufferEncode(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const AutoDismiss = {
  mounted() {
    setTimeout(() => {
      this.el.style.opacity = "0"
      setTimeout(() => this.el.remove(), 500)
    }, 5000)
  }
}

const PieChart = {
  mounted() {
    this.handleEvent("pie-data", ({labels, values}) => {
      const canvas = this.el.querySelector("canvas")
      if (!canvas) return
      if (this._chart) this._chart.destroy()
      const colors = [
        "#6366f1", "#ec4899", "#f59e0b", "#10b981", "#8b5cf6",
        "#ef4444", "#3b82f6", "#14b8a6", "#f97316", "#6b7280"
      ]
      this._chart = new Chart(canvas, {
        type: "doughnut",
        data: {
          labels: labels,
          datasets: [{
            data: values,
            backgroundColor: colors.slice(0, values.length),
            borderWidth: 2,
            borderColor: "#fff"
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { position: "bottom", labels: { boxWidth: 12, padding: 12, font: { size: 11 } } }
          },
          cutout: "55%"
        }
      })
    })
  },
  destroyed() {
    if (this._chart) this._chart.destroy()
  }
}

const Sparkline = {
  mounted() {
    this.handleEvent("sparkline-data", ({labels, values, id}) => {
      if (this.el.id !== id) return
      const canvas = this.el.querySelector("canvas")
      if (!canvas) return
      if (this._chart) this._chart.destroy()
      this._chart = new Chart(canvas, {
        type: "line",
        data: {
          labels: labels,
          datasets: [{
            data: values,
            borderColor: "#6366f1",
            borderWidth: 2,
            fill: true,
            backgroundColor: "rgba(99, 102, 241, 0.1)",
            pointRadius: 0,
            tension: 0.3
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false }, tooltip: { enabled: true } },
          scales: {
            x: { display: false },
            y: { display: false, beginAtZero: true }
          }
        }
      })
    })
  },
  destroyed() {
    if (this._chart) this._chart.destroy()
  }
}

// Generic multi-instance chart hook used by the Search Keywords page.
// Server pushes {id, labels, datasets, invert_y} — hook filters by id so
// several charts can coexist on one page. Supports line, bar, and combo
// charts (bar + line overlay with dual y-axes).
//
// Dataset shape:
//   {label, data, type: "line"|"bar", color, fill?, y_axis: "y"|"y1"}
const SearchChart = {
  mounted() {
    this.handleEvent("search-chart-data", (payload) => {
      if (this.el.id !== payload.id) return
      const canvas = this.el.querySelector("canvas")
      if (!canvas) return
      if (this._chart) this._chart.destroy()

      const datasets = (payload.datasets || []).map(d => ({
        label: d.label,
        type: d.type || "line",
        data: d.data || [],
        borderColor: d.color || "#6366f1",
        backgroundColor: d.type === "bar"
          ? (d.color || "#6366f1") + "66"
          : (d.fill ? (d.color || "#6366f1") + "22" : "transparent"),
        fill: d.fill || false,
        tension: 0.3,
        borderWidth: 2,
        pointRadius: (d.data || []).length > 30 ? 0 : 3,
        pointHoverRadius: 5,
        yAxisID: d.y_axis || "y",
        order: d.type === "bar" ? 2 : 1
      }))

      const hasSecondAxis = datasets.some(d => d.yAxisID === "y1")
      const scales = {
        x: { grid: { display: false } },
        y: { beginAtZero: true, position: "left" }
      }
      if (hasSecondAxis) {
        scales.y1 = { beginAtZero: true, position: "right", grid: { drawOnChartArea: false } }
      }
      if (payload.invert_y) {
        scales.y.reverse = true
        scales.y.min = 1
      }

      this._chart = new Chart(canvas, {
        type: datasets.some(d => d.type === "bar") ? "bar" : "line",
        data: { labels: payload.labels || [], datasets: datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: "index", intersect: false },
          plugins: {
            legend: { display: datasets.length > 1, position: "top", align: "end" },
            tooltip: { enabled: true }
          },
          scales: scales
        }
      })
    })
  },
  destroyed() {
    if (this._chart) this._chart.destroy()
  }
}

const IdleTimeout = {
  mounted() {
    const timeoutMs = parseInt(this.el.dataset.timeout || "1800000") // 30 min default
    const warnMs = timeoutMs - 120000 // warn 2 min before
    const disabled = this.el.dataset.disabled === "true"

    if (disabled) return

    this._lastActivity = Date.now()
    this._warned = false

    // Track user activity (debounced)
    const onActivity = () => {
      this._lastActivity = Date.now()
      if (this._warned) {
        this._warned = false
        this._dismissWarning()
      }
    }

    ;["mousemove", "keydown", "click", "touchstart", "scroll"].forEach(evt => {
      document.addEventListener(evt, onActivity, { passive: true })
    })
    this._onActivity = onActivity

    // Check every 30 seconds
    this._interval = setInterval(() => {
      const idle = Date.now() - this._lastActivity
      if (idle >= timeoutMs) {
        this.pushEvent("idle_timeout", {})
      } else if (idle >= warnMs && !this._warned) {
        this._warned = true
        this._showWarning()
      }
    }, 30000)
  },

  _showWarning() {
    if (document.getElementById("idle-warning")) return
    const div = document.createElement("div")
    div.id = "idle-warning"
    div.className = "fixed bottom-4 right-4 z-50 bg-amber-50 border border-amber-300 rounded-lg shadow-lg p-4 max-w-sm"
    div.innerHTML = `
      <p class="text-sm font-medium text-amber-800">Session expiring soon</p>
      <p class="text-xs text-amber-600 mt-1">You'll be signed out in 2 minutes due to inactivity. Move your mouse to stay signed in.</p>
    `
    document.body.appendChild(div)
  },

  _dismissWarning() {
    const el = document.getElementById("idle-warning")
    if (el) el.remove()
  },

  destroyed() {
    if (this._interval) clearInterval(this._interval)
    ;["mousemove", "keydown", "click", "touchstart", "scroll"].forEach(evt => {
      document.removeEventListener(evt, this._onActivity)
    })
    this._dismissWarning()
  }
}

const LocalTime = {
  mounted() {
    this._format()
  },
  updated() {
    this._format()
  },
  _format() {
    const utc = this.el.dataset.utc
    if (!utc) return
    try {
      const d = new Date(utc)
      this.el.textContent = d.toLocaleString(undefined, {
        year: "numeric", month: "short", day: "numeric",
        hour: "numeric", minute: "2-digit", timeZoneName: "short"
      })
    } catch(_) {}
  }
}

const Hooks = {
  TimeseriesChart,
  BarChart,
  BubbleMap,
  EcommerceChart,
  PasskeyRegister,
  AutoDismiss,
  Sparkline,
  SearchChart,
  PieChart,
  IdleTimeout,
  LocalTime,
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Scroll to element by ID (used by docs page)
window.addEventListener("phx:scroll-to", (e) => {
  const el = document.getElementById(e.detail.id)
  if (el) el.scrollIntoView({ behavior: "smooth", block: "start" })
})

// Clipboard copy for tracking snippet
window.addEventListener("spectabas:clipcopy", (e) => {
  const text = e.target.dataset.text
  if (text) {
    navigator.clipboard.writeText(text).then(() => {
      e.target.innerText = "Copied!"
      setTimeout(() => { e.target.innerText = "Copy" }, 2000)
    })
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

