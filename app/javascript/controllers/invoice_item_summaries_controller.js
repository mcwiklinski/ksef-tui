import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cell"]

  static values = {
    concurrency: { type: Number, default: 4 },
    failureText: { type: String, default: "Unavailable" },
    maxAttempts: { type: Number, default: 3 },
    placeholder: { type: String, default: "Waiting for summary..." },
    retryDelay: { type: Number, default: 800 }
  }

  connect() {
    this.connected = true
    this.requestCounter = 0
    this.loadMissingSummaries()
  }

  disconnect() {
    this.connected = false
  }

  async loadMissingSummaries() {
    const pendingCells = this.cellTargets.filter((cell) => cell.dataset.summaryStatus === "missing" && cell.dataset.summaryUrl)
    if (!pendingCells.length) return

    const queue = [...pendingCells]
    const workerCount = Math.min(this.concurrencyValue, queue.length)
    const workers = Array.from({ length: workerCount }, () => this.processQueue(queue))

    await Promise.all(workers)
  }

  async processQueue(queue) {
    while (this.connected) {
      const cell = queue.shift()
      if (!cell) return

      await this.fetchSummary(cell)
    }
  }

  async fetchSummary(cell) {
    const requestId = this.beginRequest(cell)
    this.renderWaiting(cell)

    for (let attempt = 1; attempt <= this.maxAttemptsValue; attempt += 1) {
      try {
        const response = await fetch(cell.dataset.summaryUrl, {
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })

        if (!response.ok) {
          throw new Error(`Request failed with status ${response.status}`)
        }

        const payload = await response.json()
        if (!this.connected || !this.isLatestRequest(cell, requestId)) return

        this.renderReady(cell, payload.summary)
        return
      } catch (error) {
        if (!this.connected || !this.isLatestRequest(cell, requestId)) return
        if (attempt >= this.maxAttemptsValue) break

        this.renderWaiting(cell)
        await this.wait(this.retryDelayValue * attempt)
      }
    }

    if (!this.isLatestRequest(cell, requestId)) return
    this.renderFailure(cell)
  }

  async regenerate(event) {
    event.preventDefault()

    const button = event.currentTarget
    if (button.disabled) return

    const cell = button.closest("td")?.querySelector('[data-invoice-item-summaries-target="cell"]')
    const url = button.dataset.regenerateUrl
    if (!cell || !url) return

    const requestId = this.beginRequest(cell)
    this.setButtonBusy(button, true)
    this.renderWaiting(cell)

    try {
      const response = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
          "X-Requested-With": "XMLHttpRequest"
        }
      })

      if (!response.ok) {
        throw new Error(`Request failed with status ${response.status}`)
      }

      const payload = await response.json()
      if (!this.connected || !this.isLatestRequest(cell, requestId)) return

      this.renderReady(cell, payload.summary)
    } catch (error) {
      if (!this.connected || !this.isLatestRequest(cell, requestId)) return

      this.renderFailure(cell)
    } finally {
      if (!this.connected) return

      this.setButtonBusy(button, false)
    }
  }

  renderWaiting(cell) {
    cell.innerHTML = this.waitingMarkup()
    cell.dataset.summaryStatus = "loading"
    cell.setAttribute("aria-busy", "true")
    cell.classList.add("text-gray-500")
    cell.classList.remove("text-gray-700")
  }

  renderReady(cell, summary) {
    cell.textContent = summary || this.failureTextValue
    cell.dataset.summaryStatus = "ready"
    cell.removeAttribute("aria-busy")
    cell.classList.remove("text-gray-500")
    cell.classList.add("text-gray-700")
  }

  renderFailure(cell) {
    cell.textContent = this.failureTextValue
    cell.dataset.summaryStatus = "failed"
    cell.removeAttribute("aria-busy")
    cell.classList.remove("text-gray-500", "text-gray-700")
    cell.classList.add("text-gray-400")
  }

  waitingMarkup() {
    return `
      <span class="inline-flex items-center gap-2 text-gray-500">
        <svg class="h-3.5 w-3.5 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <circle class="opacity-25" cx="12" cy="12" r="9" stroke="currentColor" stroke-width="3"></circle>
          <path class="opacity-90" d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" stroke-width="3" stroke-linecap="round"></path>
        </svg>
        <span>${this.placeholderValue}</span>
      </span>
    `
  }

  beginRequest(cell) {
    this.requestCounter += 1
    const requestId = String(this.requestCounter)
    cell.dataset.requestId = requestId
    return requestId
  }

  isLatestRequest(cell, requestId) {
    return cell.dataset.requestId === String(requestId)
  }

  setButtonBusy(button, busy) {
    button.disabled = busy
    button.classList.toggle("opacity-50", busy)
    button.classList.toggle("cursor-wait", busy)
    button.classList.toggle("hover:text-indigo-700", !busy)
    button.setAttribute("aria-busy", String(busy))
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  wait(duration) {
    return new Promise((resolve) => {
      window.setTimeout(resolve, duration)
    })
  }
}
