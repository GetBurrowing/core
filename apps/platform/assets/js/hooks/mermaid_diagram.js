// MermaidDiagram hook — renders Mermaid diagram source into an SVG
// Loads mermaid.js from CDN on first use, caches for subsequent renders.

let mermaidReady = null;

function ensureMermaid() {
  if (mermaidReady) return mermaidReady;

  mermaidReady = new Promise((resolve, reject) => {
    if (window.mermaid) {
      window.mermaid.initialize({ startOnLoad: false, theme: "neutral" });
      resolve(window.mermaid);
      return;
    }

    const script = document.createElement("script");
    script.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
    script.onload = () => {
      window.mermaid.initialize({ startOnLoad: false, theme: "neutral" });
      resolve(window.mermaid);
    };
    script.onerror = reject;
    document.head.appendChild(script);
  });

  return mermaidReady;
}

const MermaidDiagram = {
  mounted() {
    this._render();
  },

  updated() {
    this._render();
  },

  async _render() {
    const source = this.el.dataset.source;
    if (!source || !source.trim()) {
      this.el.querySelector(".mermaid-container").innerHTML =
        '<p class="text-xs text-base-content/40 italic">No diagram source</p>';
      return;
    }

    try {
      const mermaid = await ensureMermaid();
      const id = `mermaid-svg-${this.el.id}-${Date.now()}`;
      const { svg } = await mermaid.render(id, source.trim());
      this.el.querySelector(".mermaid-container").innerHTML = svg;
    } catch (err) {
      console.error("[MermaidDiagram] render failed:", err);
      this.el.querySelector(".mermaid-container").innerHTML =
        `<div class="text-xs">
          <p class="text-error mb-2">Diagram render failed</p>
          <pre class="whitespace-pre-wrap text-base-content/60 font-mono text-[11px] bg-base-200 rounded p-2">${source}</pre>
        </div>`;
    }
  },
};

export default MermaidDiagram;
