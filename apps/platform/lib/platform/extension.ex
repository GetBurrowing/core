defmodule Platform.Extension do
  @moduledoc """
  The contract a build-time module implements so core can load it without
  naming it (ADR 0055, task 01a0ee08).

  A module ships one implementation of this behaviour and is listed in app
  env:

      config :platform, :extensions, [SomeModule.Extension]

  Core never sets that key; an unset key means no modules. Core reads it only
  through `Platform.Extensions`, per call.

  ## Required callbacks

  Each returns data, and an empty list (or `nil` for `migrations_path/0`) is
  a valid answer. A module whose own processes are not running must still
  answer every callback without raising: at boot the Endpoint can accept a
  runtime socket before a module's supervision tree is up, and at shutdown a
  runtime channel can terminate after it is gone
  (`0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).

  ## Optional callbacks with no reader yet

  `telemetry_handlers/0`, `responsibility_providers/0` and
  `prompt_templates/0` are declared so a module may implement them, but NO
  reader exists in core for any of them: no module has an entry to put in
  them yet. Implementing one has no effect until its first consumer builds
  the reader, with a fixture as its positive control. This is a deliberate
  deferral (ADR 0055, "Optional callbacks, deferred to their first
  consumer"), not an omission. `rail_items/0` is optional and
  DOES have a reader (`PlatformWeb.Components.IconRail`).

  `inbox_kinds/0` is optional and DOES have a reader
  (`Platform.Extensions.inbox_kinds/0`, read per call by `Platform.Inbox.Item`,
  `Platform.Inbox` and `PlatformWeb.Components.InboxItem`).

  ## routes/0 has a reader: runtime dispatch under /api/ext

  `routes/0` returns `[%{prefix: String.t(), plug: module(), opts: term()}]`,
  `prefix` being ONE lowercase path segment. Its reader is runtime dispatch
  through one generic core route, NOT router macros compiled in: in a
  with-modules build the module apps depend on `:platform`, so core's router
  compiles before any module and cannot call `routes/0` at compile time
  (ADR 0055's `Application.compile_env` sketch cannot work for that reason).
  `/api/ext/<prefix>/rest...` reaches the claiming extension's plug with
  `path_info` = `rest...` (`PlatformWeb.Plugs.ExtensionRoutes`, looked up per
  request through `Platform.Extensions.route_for/1`). `Platform.Extensions.validate/0`
  refuses two extensions claiming one prefix.

  **A routes/0 plug gets NO session and NO authentication from core.** The
  `:extension_api` pipeline only accepts JSON: no `fetch_session`, no CSRF,
  no current user, and params are not logged. The plug owns its auth (a
  webhook signature, a bearer token) and must halt on failure.
  """

  @typedoc """
  One MCP tool bundle a module contributes.

    * `:name` — the bundle name a runtime is granted in `allowed_bundles`;
    * `:definitions` — the tool definitions `tools/list` shows for it, in the
      `Platform.Federation.ToolSurface` rubric shape (may be `[]`);
    * `:tool_names` — every tool name the bundle OWNS, listed or not. A call
      to one of these names is dispatched to `:execute` even while
      `:definitions` is empty;
    * `:execute` — `(tool_name, args, context) -> result`, the same contract
      as `ToolSurface.execute/3`. The context also carries `:agent_home_org`,
      the calling agent's home org by core's rule (`:root` for an unpinned
      or root-pinned agent or no agent, `{:tenant, org_id}` otherwise), so a
      module scopes by the agent and never by a client-supplied org id;
    * `:deny_message` (optional) — `(tool_name) -> String.t() | nil`, the
      text a transport reports when it denies one of `:tool_names`; `nil`
      keeps core's own wording;
    * `:owns_tool?` (optional) — `(tool_name) -> boolean()`, a name space the
      module reserves beyond `:tool_names`, asked only after the exact-name
      lookup misses. It may not cover a core tool name
      (`Platform.Extensions.validate/0`).
  """
  @type tool_bundle :: %{
          required(:name) => String.t(),
          required(:definitions) => [map()],
          required(:tool_names) => [String.t()],
          required(:execute) => (String.t(), map(), map() -> term()),
          optional(:deny_message) => (String.t() -> String.t() | nil),
          optional(:owns_tool?) => (String.t() -> boolean())
        }

  @typedoc """
  What `handle_runtime_event/3` answers.

  `{:inert, text}` means the module owns the event but is switched off on
  this install; the channel logs `text` once per socket and drops the frame,
  the same as for an event no module owns.
  """
  @type runtime_event_result :: :ok | {:error, term()} | {:inert, String.t()}

  @doc "Canvas kind modules (each implements `Platform.Chat.Canvas.Kind`)."
  @callback canvas_kinds() :: [module()]

  @doc "MCP tool bundles this module contributes."
  @callback mcp_tool_bundles() :: [tool_bundle()]

  @doc "Runtime-channel event names this module owns."
  @callback runtime_channel_events() :: [String.t()]

  @doc "Handles one owned runtime-channel event from `runtime_id`. Must not raise."
  @callback handle_runtime_event(event :: String.t(), runtime_id :: String.t(), payload :: map()) ::
              runtime_event_result()

  @doc "A runtime's socket went away. Must return `:ok` and never raise."
  @callback runtime_disconnected(runtime_id :: String.t()) :: :ok

  @doc "LiveView lifecycle hooks, each `{module, function}` called as `(socket) -> socket`."
  @callback live_hooks() :: [{module(), atom()}]

  @doc "Experiment surface modules (each implements `Platform.Experiments.Surface`)."
  @callback experiment_surfaces() :: [module()]

  @doc "Experiment metrics, `%{slug => %{module:, label:, description:, direction:}}`."
  @callback experiment_metrics() :: %{String.t() => map()}

  @doc "Absolute path of this module's migrations, or `nil`."
  @callback migrations_path() :: String.t() | nil

  @doc """
  The module's front-end assets, read at BUILD time by a release host's
  `mix platform.extensions.assets`: `:js_hooks`, a JS file whose default
  export is a map of LiveView hooks; `:css`, a stylesheet the host imports;
  `:tailwind_sources`, paths Tailwind scans for classes. Any may be `nil`/`[]`.
  Optional; a module with no front end omits it.
  """
  @callback assets() :: %{
              optional(:js_hooks) => String.t() | nil,
              optional(:css) => String.t() | nil,
              optional(:tailwind_sources) => [String.t()]
            }

  @doc "Rail destinations in `IconRail.canonical_destinations/0`'s shape."
  @callback rail_items() :: [map()]

  @typedoc "One HTTP route a module contributes (see the moduledoc)."
  @type route :: %{
          required(:prefix) => String.t(),
          required(:plug) => module(),
          optional(:opts) => term()
        }

  @doc """
  HTTP routes, served at `/api/ext/<prefix>/...` with no session and no auth
  from core (see the moduledoc). Read by `Platform.Extensions.routes/0`.
  """
  @callback routes() :: [route()]

  @typedoc "One inbox kind a module contributes (see `c:inbox_kinds/0`)."
  @type inbox_kind :: %{
          required(:kind) => String.t(),
          required(:source_type) => String.t(),
          required(:label) => String.t(),
          required(:icon) => String.t(),
          required(:stays_listed_on_open) => boolean()
        }

  @doc """
  Inbox kinds this module emits rows of, each with the `source_type` its rows
  point at, the label and icon the inbox renders, and whether opening a row
  leaves it listed (an action kind) or acknowledges it. Optional. Read per
  call by `Platform.Extensions.inbox_kinds/0`, so `Platform.Inbox.Item`
  accepts the kind only while the module is registered. An extension kind
  never pushes, is never shown to an external user and never appears in
  Mobile's approvals: those lists stay core's own.
  """
  @callback inbox_kinds() :: [inbox_kind()]

  @doc "Deferred: no reader yet (see the moduledoc)."
  @callback telemetry_handlers() :: [term()]

  @doc "Deferred: no reader yet (see the moduledoc)."
  @callback responsibility_providers() :: [module()]

  @doc "Deferred: no reader yet (see the moduledoc)."
  @callback prompt_templates() :: [term()]

  @optional_callbacks rail_items: 0,
                      assets: 0,
                      routes: 0,
                      inbox_kinds: 0,
                      telemetry_handlers: 0,
                      responsibility_providers: 0,
                      prompt_templates: 0
end
