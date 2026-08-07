# Third-party notices

This file is the **canonical location** for third-party licence notices covering
JavaScript that Suite ships to browsers. Add an entry here whenever you vendor a
dependency or add one whose licence requires attribution.

Suite itself is Apache-2.0 (see the repository root `LICENSE`). The prior
convention for vendored JS was an `@license` banner at the top of the vendored
file (`assets/vendor/topbar.js`); that convention still holds for single-file
vendored scripts. This file covers everything that arrives through
`assets/package.json` and gets bundled.

## Generated notices

The `excalidraw` esbuild profile (`config/config.exs`) is built with
`--legal-comments=linked`, so esbuild emits

    priv/static/assets/js/excalidraw_island.js.LEGAL.txt

next to the bundle. That file preserves the licence comments esbuild found in
the bundled sources (React, the fonts Excalidraw embeds, and the packages
underneath them) and is regenerated on every `mix assets.build`. It is the
machine-generated companion to this file, not a replacement for it.

Note the generated file records `@excalidraw/excalidraw/dist/prod/chunk-*.js`
as a source path but carries **no Excalidraw copyright line** — the published
npm package ships neither a `LICENSE` file nor an `@license` banner in its
`dist` output. The Excalidraw attribution below is therefore recorded here by
hand, taken from the upstream repository.

## Bundled dependencies

| Package | Version | Licence |
| --- | --- | --- |
| `@excalidraw/excalidraw` | 0.18.1 | MIT |
| `react` | 18.3.1 | MIT |
| `react-dom` | 18.3.1 | MIT |

Excalidraw also ships font files under `dist/prod/fonts`, copied into
`priv/static/assets/excalidraw/` at build time so Suite serves them from its own
origin rather than a CDN. Those fonts carry their own licences (OFL and MIT),
reproduced in the generated `.LEGAL.txt`.

### `@excalidraw/excalidraw`

    MIT License

    Copyright (c) 2020 Excalidraw

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

### `react` and `react-dom`

    MIT License

    Copyright (c) Meta Platforms, Inc. and affiliates.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

### `livekit-client`

Apache-2.0. Ships its own `LICENSE` in `node_modules/livekit-client`; no
attribution notice is reproduced here beyond this entry.
