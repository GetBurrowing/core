// Build stub for the mermaid-to-Excalidraw import path.
//
// `@excalidraw/excalidraw` carries a STATIC dependency chain on `mermaid`
// (~1.2 MB), `cytoscape` (437 KB) and `katex` (266 KB) purely to power its
// "import a mermaid diagram" feature. Suite does not surface that feature, so
// the excalidraw esbuild profile (config/config.exs) aliases all three
// packages to this module, which cuts the island bundle roughly in half.
//
// Nothing here is a silent fallback: if the mermaid-import path is ever
// exercised, every access throws with a message that names the alias and the
// file to edit. A crash is a bug report; a no-op would be a bug that files
// none.

const MESSAGE =
  "Excalidraw's mermaid-import path was exercised, but `mermaid`, `cytoscape` " +
  "and `katex` are aliased to js/stubs/excalidraw_mermaid_stub.js by the " +
  "`excalidraw` esbuild profile in config/config.exs to keep the island " +
  "bundle small. If Suite now needs mermaid-to-Excalidraw import, remove " +
  "those --alias: flags and re-measure the island bundle size.";

function refuse() {
  throw new Error(MESSAGE);
}

const stub = new Proxy(refuse, {
  get(_target, prop) {
    if (prop === "__isSuiteExcalidrawMermaidStub") return true;
    refuse();
  },
  apply: refuse,
  construct: refuse,
});

export default stub;
export { stub as mermaid, MESSAGE };
