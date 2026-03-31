import { LAST_CHAT_PATH_KEY } from "./chat_state";

const LastChatLink = {
  mounted() {
    this.syncHref();
  },

  updated() {
    this.syncHref();
  },

  syncHref() {
    const stored = localStorage.getItem(LAST_CHAT_PATH_KEY);
    const fallback = this.el.dataset.defaultChatPath || "/chat";
    const next = stored && stored.startsWith("/chat/") ? stored : fallback;
    this.el.setAttribute("href", next);
  },
};

export default LastChatLink;
