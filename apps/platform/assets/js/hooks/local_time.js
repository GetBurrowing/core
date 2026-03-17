const isSameLocalDay = (left, right) =>
  left.getFullYear() === right.getFullYear() &&
  left.getMonth() === right.getMonth() &&
  left.getDate() === right.getDate()

const formatRecencyAware = (date) => {
  const now = new Date()

  if (isSameLocalDay(date, now)) {
    return new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(date)
  }

  const dateOptions = {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }

  if (date.getFullYear() !== now.getFullYear()) {
    dateOptions.year = "numeric"
  }

  return new Intl.DateTimeFormat(undefined, dateOptions).format(date)
}

const hydrate = (element) => {
  const raw = element.dataset.localTime || element.getAttribute("datetime")
  if (!raw) return

  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return

  element.textContent = formatRecencyAware(date)
  element.title = new Intl.DateTimeFormat(undefined, {
    dateStyle: "full",
    timeStyle: "short",
  }).format(date)
}

export default {
  mounted() {
    hydrate(this.el)
  },

  updated() {
    hydrate(this.el)
  },
}
