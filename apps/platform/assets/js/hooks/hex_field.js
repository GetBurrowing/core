/**
 * HexField: shows the server's normalised hex in an admin colour field once
 * the admin leaves it (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 5).
 *
 * The server echoes a valid entry back normalised ('#F55' -> '#ff5555') in
 * both `value` and `data-normalized`. LiveView never patches the value of a
 * FOCUSED input, but it does merge its other attributes, so while the admin
 * types `data-normalized` keeps up and `value` does not. On blur (and on any
 * later patch that lands while the field is not focused) this hook copies
 * `data-normalized` into the field.
 *
 * It only does so when the server's value is a normalisation of what is in
 * the field right now. A blur that beats the server's reply to the last
 * keystroke would otherwise paste the PREVIOUS entry over the new one; that
 * reply patches the field itself once it lands, because by then the field is
 * not focused. An invalid entry has no hex equivalent, so it stays as typed
 * next to its error.
 */

// The same rule as Platform.Branding.Contrast.normalize_hex/1, used only to
// decide whether the server's value belongs to the text in the field.
export function hexEquivalent(text) {
  if (typeof text !== "string") return null
  const digits = text.trim().replace(/^#/, "").toLowerCase()
  if (/^[0-9a-f]{6}$/.test(digits)) return `#${digits}`
  if (/^[0-9a-f]{3}$/.test(digits)) {
    return `#${digits[0]}${digits[0]}${digits[1]}${digits[1]}${digits[2]}${digits[2]}`
  }
  return null
}

// The text the field should show, or null to leave it alone.
export function settledValue(current, normalized) {
  if (!normalized || current === normalized) return null
  return hexEquivalent(current) === normalized ? normalized : null
}

const HexField = {
  mounted() {
    this.onBlur = () => this.settle()
    this.el.addEventListener("blur", this.onBlur)
  },

  updated() {
    if (document.activeElement !== this.el) this.settle()
  },

  destroyed() {
    this.el.removeEventListener("blur", this.onBlur)
  },

  settle() {
    const next = settledValue(this.el.value, this.el.dataset.normalized)
    if (next !== null) this.el.value = next
  },
}

export default HexField
