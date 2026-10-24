// TasksMyListRows — task 01a166be. Lives on `#tasks-my-list`.
//
// A join renders only part of this list (see PlatformWeb.Tasks.FilterHooks):
// no rows at `lg` and wider, where the list is `display: none`
// (`data-rows="none"`), and a screenful on a phone (`data-rows="some"`).
// Ask the server for every row once they can be seen: when the
// `#tasks-my-list-more` sentinel nears the scroll viewport, or when the
// window narrows below `lg`. Asked once per LiveView; `data-rows="all"`
// needs nothing.
const LG = "(min-width: 64rem)"

const TasksMyListRows = {
  mounted() {
    this.mql = window.matchMedia(LG)
    this.onChange = () => this.sync()
    this.mql.addEventListener("change", this.onChange)
    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.mql?.removeEventListener("change", this.onChange)
    this.observer?.disconnect()
  },
  sync() {
    const rows = this.el.dataset.rows
    if (rows === "all" || this.requested || this.mql.matches) return
    if (rows === "none") return this.request()
    const sentinel = this.el.querySelector("#tasks-my-list-more")
    if (!sentinel || this.observed === sentinel) return
    this.observer?.disconnect()
    this.observed = sentinel
    this.observer = new IntersectionObserver(
      (entries) => entries.some((e) => e.isIntersecting) && this.request(),
      {root: sentinel.parentElement, rootMargin: "0px 0px 600px 0px"},
    )
    this.observer.observe(sentinel)
  },
  request() {
    this.requested = true
    this.observer?.disconnect()
    this.pushEvent("tasks_my_list_rows", {})
  },
}

export default TasksMyListRows
