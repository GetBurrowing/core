const LAST_CHAT_PATH_KEY = "suite:last-chat-path";

const ChatState = {
  mounted() {
    this.persistCurrentPath();
  },

  updated() {
    this.persistCurrentPath();
  },

  persistCurrentPath() {
    const path = window.location.pathname || "";
    if (path.startsWith("/chat/") && path.length > "/chat/".length) {
      localStorage.setItem(LAST_CHAT_PATH_KEY, path);
    }
  },
};

export { LAST_CHAT_PATH_KEY };
export default ChatState;
