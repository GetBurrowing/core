/**
 * CodeBlock hook — adds language label, copy button, and collapse/expand
 * for code blocks with 20+ lines.
 */
const COLLAPSE_THRESHOLD = 20;

const CodeBlock = {
  mounted() {
    this._enhance();
  },

  updated() {
    this._enhance();
  },

  _enhance() {
    const wrapper = this.el;
    // Avoid double-processing
    if (wrapper.dataset.enhanced) return;
    wrapper.dataset.enhanced = "true";

    const pre = wrapper.querySelector("pre");
    const code = wrapper.querySelector("pre > code");
    if (!pre || !code) return;

    const language = wrapper.dataset.language || "";
    const rawCode = code.textContent || "";
    const lineCount = rawCode.split("\n").length;

    // Build header with language label and copy button
    const header = document.createElement("div");
    header.className = "code-block-header";

    const langLabel = document.createElement("span");
    langLabel.textContent = language || "code";
    header.appendChild(langLabel);

    const copyBtn = document.createElement("button");
    copyBtn.className = "copy-btn";
    copyBtn.textContent = "Copy";
    copyBtn.addEventListener("click", () => {
      navigator.clipboard.writeText(rawCode).then(() => {
        copyBtn.textContent = "Copied!";
        setTimeout(() => { copyBtn.textContent = "Copy"; }, 2000);
      }).catch(() => {
        // Fallback for older browsers
        const ta = document.createElement("textarea");
        ta.value = rawCode;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
        copyBtn.textContent = "Copied!";
        setTimeout(() => { copyBtn.textContent = "Copy"; }, 2000);
      });
    });
    header.appendChild(copyBtn);

    wrapper.insertBefore(header, pre);

    // Collapse long code blocks
    if (lineCount > COLLAPSE_THRESHOLD) {
      wrapper.classList.add("code-block-collapsed");

      const expandBtn = document.createElement("button");
      expandBtn.className = "code-block-expand";
      expandBtn.textContent = `Show all (${lineCount} lines)`;
      expandBtn.addEventListener("click", () => {
        const isCollapsed = wrapper.classList.toggle("code-block-collapsed");
        expandBtn.textContent = isCollapsed
          ? `Show all (${lineCount} lines)`
          : "Collapse";
      });

      wrapper.appendChild(expandBtn);
    }
  }
};

export default CodeBlock;
