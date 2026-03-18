// ScrollToBottom hook — scrolls a container to its bottom on mount and on
// each DOM update (i.e. when new messages arrive via phx-update="stream").
// Also applies Slack-style message grouping: consecutive messages from the
// same sender hide the avatar and sender name row.
// Also injects date separators between messages from different calendar days.

const DATE_SEP_CLASS = "js-date-separator";

function formatDateLabel(dateStr) {
  // dateStr is "YYYY-MM-DD" in UTC
  const today = new Date();
  const todayStr = `${today.getUTCFullYear()}-${String(today.getUTCMonth() + 1).padStart(2, "0")}-${String(today.getUTCDate()).padStart(2, "0")}`;
  const yesterday = new Date(today);
  yesterday.setUTCDate(today.getUTCDate() - 1);
  const yesterdayStr = `${yesterday.getUTCFullYear()}-${String(yesterday.getUTCMonth() + 1).padStart(2, "0")}-${String(yesterday.getUTCDate()).padStart(2, "0")}`;

  if (dateStr === todayStr) return "Today";
  if (dateStr === yesterdayStr) return "Yesterday";

  // Parse and format as "Mon, Mar 16"
  const [year, month, day] = dateStr.split("-").map(Number);
  const d = new Date(Date.UTC(year, month - 1, day));
  return d.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

function buildSeparator(label) {
  const div = document.createElement("div");
  div.className = `${DATE_SEP_CLASS} flex items-center gap-3 my-4`;
  div.innerHTML = `
    <div class="flex-1 border-t border-base-300"></div>
    <span class="text-[11px] uppercase tracking-widest text-base-content/40 font-semibold px-2">${label}</span>
    <div class="flex-1 border-t border-base-300"></div>
  `;
  return div;
}

const ScrollToBottom = {
  mounted() {
    // MutationObserver fires when stream inserts new message rows
    this._observer = new MutationObserver(() => {
      this._safeUpdate();
    });
    this._safeUpdate();
    this._observer.observe(this.el, { childList: true, subtree: false });
  },
  _safeUpdate() {
    // Disconnect observer to prevent infinite loop from our own DOM changes
    if (this._observer) this._observer.disconnect();
    this.applyGrouping();
    this.applyDateSeparators();
    this.scrollToBottom();
    // Reconnect after our changes are done
    if (this._observer) {
      this._observer.observe(this.el, { childList: true, subtree: false });
    }
  },
  updated() {
    this._safeUpdate();
  },
  destroyed() {
    if (this._observer) this._observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  // Walk visible message rows; if the participant matches the previous row,
  // collapse the avatar + header for a compact grouped look.
  applyGrouping() {
    const rows = Array.from(this.el.querySelectorAll("[data-participant-id]"));
    let prevParticipantId = null;

    rows.forEach((row) => {
      const pid = row.dataset.participantId;
      const avatar = row.querySelector(".message-avatar");
      const header = row.querySelector(".message-header");

      if (pid && pid === prevParticipantId) {
        // Grouped — hide avatar and header, reduce top padding
        if (avatar) avatar.style.visibility = "hidden";
        if (header) header.style.display = "none";
        row.style.paddingTop = "1px";
      } else {
        // First in group — show avatar and header normally
        if (avatar) avatar.style.visibility = "";
        if (header) header.style.display = "";
        row.style.paddingTop = "";
      }

      prevParticipantId = pid || null;
    });
  },
  // Insert date separator divs between messages from different calendar days.
  // Uses the data-date attribute (YYYY-MM-DD) on each message row.
  applyDateSeparators() {
    // Remove previously inserted separators first
    this.el.querySelectorAll(`.${DATE_SEP_CLASS}`).forEach((el) => el.remove());

    const rows = Array.from(this.el.querySelectorAll("[data-date]"));
    let prevDate = null;

    rows.forEach((row) => {
      const dateStr = row.dataset.date;
      if (!dateStr) return;

      if (prevDate !== null && dateStr !== prevDate) {
        const sep = buildSeparator(formatDateLabel(dateStr));
        row.parentNode.insertBefore(sep, row);
      } else if (prevDate === null) {
        // Always show date for the very first message
        const sep = buildSeparator(formatDateLabel(dateStr));
        row.parentNode.insertBefore(sep, row);
      }

      prevDate = dateStr;
    });
  },
};

export default ScrollToBottom;
