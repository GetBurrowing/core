defmodule Platform.GameStream.Extension do
  @moduledoc """
  Play's `Platform.Extension` implementation (ADR 0055, task 01a0ee08
  stages 2 and 3). Everything core used to name about Play is answered here,
  so core names no Play module. Since stage 3 it lives in `apps/game_stream`,
  its own Mix project, and is registered by config only in a with-Play build.

  ## `GAME_STREAM_ENABLED` is read here, not in core

  The flag keeps exactly main's meaning, now inside the module (read at boot
  by `Platform.GameStream.RuntimeConfig`), until the installs are repointed
  (`0055-extension-contract-and-build-time-modules.md § 9. Install safety at merge`):

    * the `game_stream` canvas kind is registered only while it is set;
    * the `play` bundle is ALWAYS a known, grantable bundle, its definitions
      are `[]` while the flag is unset, and a call to a `play_session_*`
      name still reaches `Platform.GameStream.Tools`, which answers the
      structured `game_stream_disabled` refusal; a transport's denial text
      for those names is that refusal's text;
    * the three play frames are owned whatever the flag says; while it is
      unset they are logged once per socket and dropped (`{:inert, text}`);
    * the LiveView hooks, the experiment surfaces and the metrics are
      registered whatever the flag says, as on main.

  ## The module's processes may be absent

  `handle_runtime_event/3` and `runtime_disconnected/1` check that the
  session Registry exists before touching it. `Platform.GameStream.Application`
  starts it, after the Endpoint, and stops it before the Endpoint
  (`0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`),
  so a frame at boot is answered `{:error, :not_running}` and a disconnect
  at shutdown is `:ok`.
  """

  @behaviour Platform.Extension

  alias Platform.Federation.PlayTools
  alias Platform.GameStream

  @events ~w(play_session_status play_signal play_slot_activity)

  @inert_text "game_stream is disabled (GAME_STREAM_ENABLED is unset); further play frames " <>
                "on this channel are dropped silently"

  @impl true
  def canvas_kinds do
    if GameStream.enabled?(), do: [Platform.Chat.Canvas.Kinds.GameStream], else: []
  end

  @impl true
  def mcp_tool_bundles do
    [
      %{
        name: "play",
        # `[]` while GAME_STREAM_ENABLED is unset, so the catalogue is exactly main's.
        definitions: PlayTools.definitions(),
        tool_names: PlayTools.names(),
        execute: &GameStream.Tools.execute/3,
        deny_message: &deny_message/1,
        # Every `play_session_*` name is Play's, listed or not, as on main:
        # an unknown one gets Play's own `unknown_tool` refusal (or, with the
        # flag unset, `game_stream_disabled`), not core's unknown-tool error.
        owns_tool?: &play_session_name?/1
      }
    ]
  end

  defp play_session_name?(name), do: String.starts_with?(name, "play_session_")

  # A `play` tool while the flag is unset is absent from the catalogue, so a
  # denial would read as a name-lookup miss: true but useless. The flag, not
  # the spelling, is why it was refused.
  defp deny_message(name) do
    if name in PlayTools.names() and not GameStream.enabled?(),
      do: PlayTools.disabled_error().error,
      else: nil
  end

  @impl true
  def runtime_channel_events, do: @events

  @impl true
  def handle_runtime_event(event, runtime_id, payload) when event in @events do
    cond do
      not GameStream.enabled?() -> {:inert, @inert_text}
      not registry_running?() -> {:error, :not_running}
      true -> dispatch(event, runtime_id, payload)
    end
  end

  defp dispatch("play_session_status", runtime_id, payload),
    do: GameStream.handle_host_status(runtime_id, payload)

  defp dispatch("play_signal", runtime_id, payload),
    do: GameStream.relay_to_viewer(runtime_id, payload)

  defp dispatch("play_slot_activity", runtime_id, payload),
    do: GameStream.handle_slot_activity(runtime_id, payload)

  @impl true
  def runtime_disconnected(runtime_id) do
    # A play host that goes away fails its session. A no-op (and never
    # raises) while GAME_STREAM_ENABLED is unset or the Registry is gone.
    if registry_running?(), do: GameStream.host_disconnected(runtime_id)
    :ok
  end

  defp registry_running?,
    do: is_pid(Process.whereis(Platform.GameStream.Supervisor.registry()))

  @impl true
  def live_hooks, do: [{PlatformWeb.GameStreamHooks, :attach}]

  @impl true
  def experiment_surfaces do
    [
      # Task 01a0db5f: the play host's NVENC settings. Registered whether or
      # not GAME_STREAM_ENABLED is set: a surface is a declaration, and its
      # only read point (`GameStream.start_session/2`) is itself gated.
      Platform.Experiments.Surfaces.GameStreamEncoder,
      # Task 01a0dbd6: multiplayer play sessions: open as watch or join, and
      # the player and spectator caps. Same gating note as the encoder.
      Platform.Experiments.Surfaces.GameStreamRoster
    ]
  end

  @impl true
  def experiment_metrics do
    %{
      # Task 01a0db5f: the `game_stream.encoder_preset` surface's metric.
      "game_stream_input_to_photon" => %{
        module: Platform.Experiments.Metrics.GameStreamInputToPhoton,
        label: "Game stream input-to-photon",
        description:
          "Mean per-session median input-to-photon round trip (ms), over a variant's " <>
            "ended play sessions that reported stats.",
        direction: :lower_is_better
      },
      # Task 01a0dbd6: the `game_stream.roster` surface's metric.
      "game_stream_input_to_photon_worst_slot_p95" => %{
        module: Platform.Experiments.Metrics.GameStreamInputToPhotonP95,
        label: "Game stream worst-slot p95 input-to-photon",
        description:
          "Mean per-session worst-player-slot p95 input-to-photon round trip (ms), over a " <>
            "variant's ended play sessions that reported stats.",
        direction: :lower_is_better
      }
    }
  end

  # Play's two migrations, moved from apps/platform with identical filenames,
  # versions and module names (so a database that ran them there sees them
  # as up). Resolved through the code server, so it is this app's priv in a
  # Mix build and in a release alike.
  @impl true
  def migrations_path, do: Application.app_dir(:game_stream, "priv/repo/migrations")

  # The `GameStream` hook, Play's fullscreen styles, and the sources Tailwind
  # scans for the kind's classes. Absolute paths into this project's tree; a
  # release host's `mix platform.extensions.assets` turns them into its
  # generated esbuild entry and wrapper stylesheet.
  @assets_root Path.expand("../../../assets", __DIR__)
  @lib_root Path.expand("../..", __DIR__)

  @impl true
  def assets do
    %{
      js_hooks: Path.join(@assets_root, "js/extension.js"),
      css: Path.join(@assets_root, "css/game_stream.css"),
      tailwind_sources: [@lib_root]
    }
  end

  # Play has no rail destination
  # (`0055-extension-contract-and-build-time-modules.md § 5. Rail items: which are core and which are module`).
  @impl true
  def rail_items, do: []
end
