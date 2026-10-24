import { loadExcalidraw } from "../lib/load_excalidraw.js"

/**
 * MeetingWhiteboard hook — the `/meetings` center-stage Whiteboard surface.
 *
 * Mounts an Excalidraw editor (MIT, self-hosted, fetched on demand through
 * `js/lib/load_excalidraw.js`) into a host div that the server renders ONCE
 * for the whole meeting stage and never takes away.
 *
 * ── Why the host is unconditional, not inside the stage-mode `cond` ───────
 * Every other stage-mode renderer can be destroyed and rebuilt because its
 * content has an external source of truth: the screen-share and video tiles
 * re-attach tracks from the LiveKit Room parked on `window.__livekit_room`.
 * An in-progress drawing has NO such source of truth — the strokes live only
 * inside the React root. So the host node is rendered outside the `cond`,
 * for every mode, and this hook toggles `hidden` on it. Switching to Gallery
 * hides the board; it does not unmount it.
 *
 * ── Why visibility is NOT driven by a server-rendered attribute ───────────
 * LiveView merges attributes onto a node even under `phx-update="ignore"`
 * (#664, meeting_video_tile.js: a stale `has_video="false"` was stamped back
 * onto the ignored slot on an unrelated re-render and destroyed the injected
 * <video>). A `data-active={@current_stage_mode == :whiteboard}` here would
 * be the same defect: any patch rendered from a stale-ish assign could hide
 * a live board. Instead the only input is the `meeting_stage_mode_changed`
 * push_event the server already emits on every `set_stage_mode`, and
 * client-side state (`this._active`) is the truth. `updated()` re-asserts
 * that truth and does nothing else — in particular it never touches the
 * React root (#665, meeting_client.js: an unconditional `updated()` re-dock
 * painted over live content).
 *
 * ── Persistence (stage 4) ─────────────────────────────────────────────────
 * v1 is SINGLE-EDITOR. There is no per-stroke broadcast, no merge, no CRDT
 * and no operational transform. The durability contract is:
 *
 *   save    — `onChange` debounced to `SAVE_DEBOUNCE_MS` of quiet, then
 *             `whiteboard_save` with the scene and the version this client
 *             believes the server holds (`this._version`).
 *   ack     — `whiteboard_saved` advances `this._version`. It is the ONLY
 *             thing that advances it; the client never guesses the counter.
 *   stale   — `whiteboard_stale` means someone else's save landed first.
 *             The local elements are NOT touched — losing strokes to a
 *             silent overwrite is the failure mode the counter exists for.
 *             A dismissible notice is drawn over the board instead.
 *   restore — on the first activation, once the island resolves,
 *             `whiteboard_load`; `updateScene` runs at most once and only
 *             when the stored scene has elements.
 *
 * All of this state lives in JS. The server never renders it onto the host
 * as a `data-*` attribute (#664: LiveView merges attributes onto ignored
 * nodes), it only speaks through `push_event`.
 */
const ACTIVE_MODE = "whiteboard"

// Quiet period before a save. Long enough that a continuous stroke is one
// save rather than dozens; short enough that a user who draws and then
// switches tabs has already been persisted.
const SAVE_DEBOUNCE_MS = 1500

// The subset of `appState` worth persisting. Excalidraw's full appState
// carries transient editor state (cursor, selection, collaborators) that is
// meaningless to another session and inflates every save.
const APP_STATE_KEYS = ["viewBackgroundColor", "gridSize", "zoom", "scrollX", "scrollY"]

// Export content types. Both are declared to the server at reservation time
// and re-sent as the POST's `content-type`; the upload controller rejects a
// mismatch against the reserved row with a 400.
const PNG_CONTENT_TYPE = "image/png"
const JSON_CONTENT_TYPE = "application/json"

// `source` field of the scene file. Identifies who wrote it; deliberately
// not a URL, so an exported board carries no host.
const SCENE_SOURCE = "suite-meeting-whiteboard"

const MeetingWhiteboard = {
  mounted() {
    // Client-side truth. Never read back off the DOM or off a server attr.
    this._active = false
    this._root = null
    this._loading = false
    this._scene = null

    // ── Persistence state (stage 4). All client-side, all private. ──────
    // The version this client believes the server holds. Advanced ONLY by
    // a `whiteboard_saved` / `whiteboard_loaded` push_event — never by the
    // client's own arithmetic, or a client could dictate the counter.
    this._version = 0
    this._elements = []
    this._appState = null
    this._files = null
    this._saveTimer = null
    // Restore runs once per hook lifetime and gates the save path: a save
    // scheduled before the stored scene has been applied would persist an
    // empty board over a real one.
    this._loadRequested = false
    this._restored = false
    this._pendingLoad = null
    this._api = null
    this._applyingRemote = false
    this._stale = false
    this._staleNotice = null

    this.handleEvent("meeting_stage_mode_changed", ({ mode }) =>
      this._setMode(mode),
    )
    this.handleEvent("whiteboard_loaded", (payload) => this._onLoaded(payload))
    this.handleEvent("whiteboard_saved", ({ scene_version }) => {
      this._version = scene_version
    })
    this.handleEvent("whiteboard_stale", () => this._onStale())

    // ── Export to canvas (stage 5) ─────────────────────────────────────
    // Three-legged, because only the browser holds the pixels and only the
    // server may mint an upload URL: `whiteboard_export_begin` (server says
    // "you're authorised, render it") → `whiteboard_export` (we say how many
    // bytes) → `whiteboard_export_reserved` (server hands back two presigned
    // URLs) → we POST both → `whiteboard_export_uploaded`.
    this._islandApi = null
    this._exporting = false
    this._pendingExport = null

    this.handleEvent("whiteboard_export_begin", () => this._beginExport())
    this.handleEvent("whiteboard_export_reserved", (payload) =>
      this._uploadExport(payload),
    )

    this._applyVisibility()
  },

  // Re-assert visibility only. Deliberately no root work of any kind: the
  // root is created exactly once per hook lifetime, in `_ensureIsland`.
  updated() {
    this._applyVisibility()
  },

  destroyed() {
    if (this._saveTimer) {
      clearTimeout(this._saveTimer)
      this._saveTimer = null
    }
    if (this._root) {
      try {
        this._root.unmount()
      } catch (_e) {
        // A root whose container is already gone throws on unmount; the
        // page is going away either way.
      }
      this._root = null
    }
    this._scene = null
    this._staleNotice = null
    this._api = null
    this._islandApi = null
    this._pendingExport = null
  },

  // ── Private ────────────────────────────────────────────────────────────

  _setMode(mode) {
    this._active = mode === ACTIVE_MODE
    this._applyVisibility()

    // Lazy by design: a meeting where nobody opens the whiteboard must never
    // fetch the ~4.9 MB island.
    if (this._active) this._ensureIsland()
  },

  _applyVisibility() {
    if (this._active) {
      this.el.classList.remove("hidden")
    } else {
      this.el.classList.add("hidden")
    }
  },

  // Test seam: vitest overrides `hook._loadIsland` so the island is never
  // actually fetched. Application code always takes the imported loader.
  // Named `_loadIsland`, not `_loadExcalidraw`, so the build guard in
  // test/no_excalidraw_in_app_bundle_test.mjs has one less identifier to
  // exempt from its "no 'excalidraw' in app.js" byte check.
  _loader() {
    return (this._loadIsland || loadExcalidraw)()
  },

  _ensureIsland() {
    // Guards BOTH re-entry while in flight and any call after the root
    // exists, so three mode flips still produce exactly one fetch and
    // exactly one `createRoot`.
    if (this._root || this._loading) return null
    this._loading = true
    this._renderSpinner()

    return this._loader()
      .then((api) => {
        this._loading = false
        if (this._root) return
        this._islandApi = api
        this._clearHost()
        this._root = api.createRoot(this.el)
        this._root.render(
          api.React.createElement(api.Excalidraw, {
            langCode: "en",
            theme: this._theme(),
            // v1 is SINGLE-EDITOR. Excalidraw only renders its live-collab
            // button when a collaboration handler is supplied; we supply
            // none, and trim the file-backed canvas actions that imply a
            // desktop workspace we do not have.
            UIOptions: {
              canvasActions: {
                loadScene: true,
                saveToActiveFile: false,
                export: false,
                toggleTheme: false,
              },
            },
            // Computed key, read off the island's frozen API. Writing the
            // prop name as a literal here would put "excalidraw" into
            // js/app.js and trip the build guard — correctly, so the token
            // lives in the island instead of in the guard's exemptions.
            [api.editorApiProp]: (editor) => {
              this._api = editor
              this._applyPendingLoad()
            },
            onChange: (elements, appState, files) => {
              this._scene = { elements, appState, files }
              this._onChange(elements, appState, files)
            },
          }),
        )
        // Restore is requested only after the root exists, so the reply has
        // somewhere to land.
        this._requestLoad()
      })
      .catch((err) => {
        this._loading = false
        this._renderError(err)
      })
  },

  // ── Save path ──────────────────────────────────────────────────────────

  _onChange(elements, appState, files) {
    // Keep the in-memory copy current no matter what — a re-render, a mode
    // flip or a stale reply must never cost us elements we have seen.
    this._elements = elements || []
    this._appState = this._appStateSubset(appState)
    this._files = files || null

    // Do not schedule a save for the scene WE just applied, and not before
    // the stored scene has been restored: either would persist a board the
    // user did not draw over one they did.
    if (this._applyingRemote || !this._restored) return

    this._scheduleSave()
  },

  _scheduleSave() {
    if (this._saveTimer) clearTimeout(this._saveTimer)
    this._saveTimer = setTimeout(() => {
      this._saveTimer = null
      this._flushSave()
    }, SAVE_DEBOUNCE_MS)
  },

  _flushSave() {
    this.pushEvent("whiteboard_save", {
      scene: {
        elements: this._elements,
        appState_subset: this._appState || {},
        files: this._files || {},
      },
      expected_version: this._version,
    })
  },

  _appStateSubset(appState) {
    if (!appState) return {}
    const out = {}
    for (const key of APP_STATE_KEYS) {
      if (appState[key] !== undefined) out[key] = appState[key]
    }
    return out
  },

  // ── Restore path ───────────────────────────────────────────────────────

  _requestLoad() {
    if (this._loadRequested) return
    this._loadRequested = true
    this.pushEvent("whiteboard_load", {})
  },

  _onLoaded({ scene, scene_version }) {
    this._version = scene_version || 0
    this._pendingLoad = scene || {}
    this._applyPendingLoad()
  },

  // The reply and the Excalidraw API ref race — whichever arrives second
  // runs the apply. `updateScene` therefore happens at most once, and only
  // for a scene that actually has elements: an empty board is the ordinary
  // starting state and needs no call at all, but it still opens the save
  // gate — otherwise a brand-new board could never be persisted.
  _applyPendingLoad() {
    if (this._restored || !this._api || this._pendingLoad === null) return

    const scene = this._pendingLoad
    const elements = scene.elements || []
    const appState = scene.appState_subset || scene.appState || null
    this._pendingLoad = null
    this._restored = true

    if (elements.length === 0) return

    this._applyingRemote = true
    this._elements = elements
    try {
      this._api.updateScene({
        elements,
        appState: appState || undefined,
      })
    } finally {
      // Released on the next tick so the `onChange` this call provokes is
      // still seen as ours and does not immediately re-save what we loaded.
      setTimeout(() => {
        this._applyingRemote = false
      }, 0)
    }
  },

  // ── Stale path ─────────────────────────────────────────────────────────
  //
  // The server refused the write because someone else's save landed first.
  // We do NOT reload, re-apply or reconcile: the local elements stay exactly
  // where they are and the user is told. That is the whole point of the
  // compare-and-set — the second saver is informed, never clobbered.
  _onStale() {
    this._stale = true
    this._showStaleNotice()
  },

  _showStaleNotice() {
    this._showNotice(
      "stale",
      "This board was changed elsewhere. Reload to see the latest, or keep drawing and save a copy.",
    )
  },

  // ONE notice slot (`this._staleNotice`), deliberately — stage 4 landed the
  // rule that two overlays stacked at the same offset is a defect, so a
  // second notice is refused while one is up rather than drawn on top.
  _showNotice(kind, message) {
    if (typeof document === "undefined" || !this.el.appendChild) return
    if (this._staleNotice) return

    const notice = document.createElement("div")
    notice.setAttribute("data-whiteboard-notice", kind)
    notice.className =
      "absolute inset-x-0 top-20 z-20 mx-3 flex items-start justify-between gap-3 rounded-lg bg-warning/95 px-4 py-3 text-sm text-warning-content shadow-lg"
    // The stale notice carries a RELOAD control, not just prose telling the
    // user to reload. The message string has always contained the word
    // "Reload" — that is not an affordance, and a user told the board moved
    // with no way to act on it is barely better off than one not told at all.
    // Mirrors the server-rendered sibling notice in `meeting_live.html.heex`:
    // same label, same `data-action="whiteboard-reload"` hook, same classes.
    // Only the stale notice gets it — reloading does not fix a failed export.
    const reload =
      kind === "stale"
        ? '<button type="button" data-action="whiteboard-reload" class="btn btn-ghost btn-xs min-h-8">Reload</button>'
        : ""

    notice.innerHTML =
      "<span>" +
      message +
      "</span>" +
      '<span class="flex shrink-0 items-center gap-1">' +
      reload +
      '<button type="button" data-whiteboard-notice-dismiss class="btn btn-ghost btn-xs min-h-8">Dismiss</button>' +
      "</span>"

    notice
      .querySelector("[data-whiteboard-notice-dismiss]")
      .addEventListener("click", () => this._dismissStaleNotice())

    const reloadEl = notice.querySelector('[data-action="whiteboard-reload"]')
    if (reloadEl) reloadEl.addEventListener("click", () => this._reloadPage())

    this._staleNotice = notice
    this.el.appendChild(notice)
  },

  // A real full page load, deliberately — it re-runs the hook's restore and
  // brings back the server's scene. Never automatic: only the user's click
  // gets here, because an automatic reload would erase their local strokes,
  // which is exactly what the compare-and-set exists to prevent.
  _reloadPage() {
    if (typeof window === "undefined" || !window.location) return
    window.location.reload()
  },

  _dismissStaleNotice() {
    if (!this._staleNotice) return
    if (this._staleNotice.remove) this._staleNotice.remove()
    this._staleNotice = null
  },

  // ── Export path (stage 5) ──────────────────────────────────────────────
  //
  // TWO artefacts, always both:
  //
  //   1. a rendered PNG — what a reader sees in the Burrow canvas;
  //   2. the authoritative `.excalidraw` scene JSON — what makes the board
  //      reopenable. Shipping only the PNG turns every whiteboard into a
  //      picture of a whiteboard the moment the meeting ends.
  //
  // Neither byte stream can be produced server-side: the pixels only exist
  // in this React root. So the server authorises and presigns, and the
  // browser POSTs. The upload URLs are HMAC-signed by the server; we never
  // construct one, and we never tell the server what the attachment URL is
  // (it already knows — it reserved the rows).

  _beginExport() {
    if (this._exporting) return null
    const api = this._islandApi
    // No island means no board was ever opened, so there is nothing to
    // export. Not an error state — just nothing to do.
    if (!api || !api.exportToBlob) return null

    this._exporting = true
    const elements = this._elements || []
    const appState = this._appState || {}
    const files = this._files || {}

    return Promise.resolve(
      api.exportToBlob({
        elements,
        appState,
        files,
        mimeType: PNG_CONTENT_TYPE,
      }),
    )
      .then((png) => {
        const json = this._sceneFileBlob(api, elements, appState, files)
        this._pendingExport = { png, json }
        this.pushEvent("whiteboard_export", {
          png_byte_size: png.size,
          json_byte_size: json.size,
        })
      })
      .catch((err) => {
        // Surfaced, not swallowed: the user is told and the export is not
        // half-completed. No canvas node is written on this path.
        this._exporting = false
        this._pendingExport = null
        this._reportExportFailure(err)
      })
  },

  _sceneFileBlob(api, elements, appState, files) {
    const scene = {
      type: api.sceneFileType,
      version: api.sceneFileVersion,
      source: SCENE_SOURCE,
      elements,
      appState,
      files,
    }
    return new Blob([JSON.stringify(scene)], { type: JSON_CONTENT_TYPE })
  },

  _uploadExport(reserved) {
    const pending = this._pendingExport
    this._pendingExport = null

    if (!pending || !reserved || !reserved.png || !reserved.json) {
      this._exporting = false
      return null
    }

    // Sequential and both-or-nothing. If the PNG upload fails we do NOT
    // push `whiteboard_export_uploaded`, so no canvas node is written: a
    // card whose image 404s is worse than no card.
    return this._putBlob(reserved.png.upload_url, pending.png, PNG_CONTENT_TYPE)
      .then(() =>
        this._putBlob(reserved.json.upload_url, pending.json, JSON_CONTENT_TYPE),
      )
      .then(() => {
        this._exporting = false
        this.pushEvent("whiteboard_export_uploaded", {
          png_attachment_id: reserved.png.id,
          json_attachment_id: reserved.json.id,
        })
      })
      .catch((err) => {
        this._exporting = false
        this._reportExportFailure(err)
      })
  },

  _putBlob(url, blob, contentType) {
    const send = this._fetch || (typeof fetch === "function" ? fetch : null)
    if (!send) {
      return Promise.reject(
        new Error("no fetch available to upload the whiteboard export"),
      )
    }

    return send(url, {
      method: "POST",
      // The controller checks this against the reserved row and 400s on a
      // mismatch, so the two artefacts must declare their real types.
      headers: { "content-type": contentType },
      body: blob,
    }).then((res) => {
      if (!res || !res.ok) {
        throw new Error(
          `whiteboard export upload failed (status ${res && res.status})`,
        )
      }
      return res
    })
  },

  _reportExportFailure(err) {
    if (typeof console !== "undefined" && console.error) console.error(err)
    this._showNotice(
      "export-failed",
      "The whiteboard could not be sent to the canvas. Try again.",
    )
  },

  _theme() {
    const attr =
      typeof document !== "undefined" && document.documentElement
        ? document.documentElement.getAttribute("data-theme")
        : null
    return attr === "dark" ? "dark" : "light"
  },

  _clearHost() {
    this.el.innerHTML = ""
  },

  // Transient states are written as markup rather than built with
  // `document.createElement` so the hook stays exercisable in a DOM-less
  // test env (the repo's other meeting hook tests run under vitest's default
  // `node` environment against a hand-built fake `el`).
  _renderSpinner() {
    this.el.innerHTML =
      '<div data-whiteboard-state="loading" class="flex h-full w-full items-center justify-center text-subtle">' +
      '<span class="loading loading-spinner loading-lg"></span>' +
      "</div>"
  },

  _renderError(err) {
    if (typeof console !== "undefined" && console.error) console.error(err)
    this.el.innerHTML =
      '<div data-whiteboard-state="error" class="flex h-full w-full items-center justify-center text-sm text-error">' +
      "The whiteboard failed to load. Reload to try again." +
      "</div>"
  },
}

export default MeetingWhiteboard
