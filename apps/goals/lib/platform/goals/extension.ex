defmodule Platform.Goals.Extension do
  @moduledoc """
  Goals' `Platform.Extension` implementation (ADR 0055, task 01a1dfc0),
  registered by config only in a with-Goals build
  (`apps/goals/config/config.exs` for the module's own runs,
  `apps/burrow_release/config/config.exs` for the with-modules image).

  Goals 1/8 contributes the module's migrations path and, only while
  `GOALS_ENABLED` is set, the `goals.use` permission. Every other registry is
  empty on purpose; later members add the rail item, the live pages and the
  tool bundle.

  No migration grants `goals.use` to the built-in roles: on an install that
  leaves the flag unset the permission is unregistered, and
  `Platform.Access.Role` refuses a role naming an unregistered permission,
  so such a grant would break role editing there.
  """

  @behaviour Platform.Extension

  @impl true
  def canvas_kinds, do: []

  @impl true
  def mcp_tool_bundles, do: []

  @impl true
  def permissions do
    if Platform.Goals.enabled?(),
      do: [%{module: "goals", permissions: ["goals.use"]}],
      else: []
  end

  @impl true
  def runtime_channel_events, do: []

  # Owns no event, so core never routes one here; answered anyway, without
  # raising, as the behaviour requires.
  @impl true
  def handle_runtime_event(_event, _runtime_id, _payload), do: {:error, :unknown_event}

  @impl true
  def runtime_disconnected(_runtime_id), do: :ok

  @impl true
  def live_hooks, do: []

  @impl true
  def experiment_surfaces, do: []

  @impl true
  def experiment_metrics, do: %{}

  # UNCONDITIONAL: `Platform.Release.migrate/0` runs with the application
  # loaded but not started, before `:goals, :enabled` is set, so the path
  # must not depend on the flag.
  @impl true
  def migrations_path, do: Application.app_dir(:goals, "priv/repo/migrations")

  @impl true
  def rail_items, do: []

  @impl true
  def live_pages, do: []
end
