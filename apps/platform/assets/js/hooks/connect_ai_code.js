/**
 * ConnectAiCode: the Claude code field on /setup/connect-ai (task 01a1b365
 * stage 3). Both things it does stay in the browser, so the code never makes
 * a round trip for them:
 *
 *   - the Show / Hide toggle switches the field between masked and plain;
 *   - the server's `connect-ai-clear-code` event (pushed on every submit)
 *     empties the field and masks it again.
 *
 * When the owner comes back to the tab from Claude's page, an empty, enabled
 * field takes focus so the paste lands in it.
 */

// Flip `input` between masked and plain, and say so on `toggle`.
export function toggleMask(input, toggle) {
  if (!input) return
  const showing = input.type === "password"
  input.type = showing ? "text" : "password"
  if (toggle) {
    toggle.textContent = showing ? "Hide" : "Show"
    toggle.setAttribute("aria-pressed", showing ? "true" : "false")
  }
}

// Empty `input` and mask it again.
export function clearCode(input, toggle) {
  if (!input) return
  input.value = ""
  input.type = "password"
  if (toggle) {
    toggle.textContent = "Show"
    toggle.setAttribute("aria-pressed", "false")
  }
}

// True when an empty, enabled field should take focus.
export function shouldFocus(input, visibilityState) {
  return Boolean(input) && !input.disabled && input.value === "" && visibilityState === "visible"
}

const ConnectAiCode = {
  mounted() {
    this.input = () => this.el.querySelector("input[name=code]")
    this.toggle = () => this.el.querySelector("[data-code-toggle]")

    this.onClick = (e) => {
      if (!e.target.closest("[data-code-toggle]")) return
      e.preventDefault()
      toggleMask(this.input(), this.toggle())
    }
    this.el.addEventListener("click", this.onClick)

    this.onFocus = () => {
      const input = this.input()
      if (shouldFocus(input, document.visibilityState)) input.focus()
    }
    window.addEventListener("focus", this.onFocus)

    this.handleEvent("connect-ai-clear-code", () => clearCode(this.input(), this.toggle()))
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("focus", this.onFocus)
  },
}

export default ConnectAiCode
