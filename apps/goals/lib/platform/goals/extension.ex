defmodule Platform.Goals.Extension do
  @moduledoc """
  Goals' `Platform.Extension` implementation (ADR 0055, task 01a1dfc0),
  registered by config only in a with-Goals build
  (`apps/goals/config/config.exs` for the module's own runs,
  `apps/burrow_release/config/config.exs` for the with-modules image).

  Goals 1/8 contributes the module's migrations path and, only while
  `GOALS_ENABLED` is set, the `goals.use` permission. Goals 3/8 (task
  01a1dfc1-05b0) adds, also only while it is set, the `goals` MCP tool
  bundle (`Platform.Goals.ToolDefinitions`), gated by `goals.use`: grantable
  per runtime, never a default grant. Goals 4/8 (task 01a1dfc1) adds, under
  the same flag, the Goals rail item (a `:working` row, so core places it in
  the desktop More group and the phone More sheet) and the `/m/goals` page
  (`PlatformWeb.GoalsLive`), plus `assets/0` so a with-modules build's
  Tailwind scans the Goals templates. Goals 7/8 (task 01a1dfc1-dffb) answers
  core's optional `claims_space_goal?/1` through `Platform.Goals.SpaceClaim`,
  false whenever the flag is off. Every other registry is empty on purpose.

  No migration grants `goals.use` to the built-in roles: on an install that
  leaves the flag unset the permission is unregistered, and
  `Platform.Access.Role` refuses a role naming an unregistered permission,
  so such a grant would break role editing there.
  """

  @behaviour Platform.Extension

  @impl true
  def briefing_sections do
    if Platform.Goals.enabled?() do
      [
        %{
          key: "goals",
          prepare: &Platform.Goals.Brief.Section.prepare/2,
          summary: &Platform.Goals.Brief.Section.summary/2,
          component: PlatformWeb.GoalsBriefComponent
        }
      ]
    else
      []
    end
  end

  @impl true
  def canvas_kinds,
    do:
      if(Platform.Goals.enabled?(),
        do: [Platform.Goals.CanvasKinds.FlashCards, Platform.Goals.CanvasKinds.GoalSpaceCard],
        else: []
      )

  # Every `goal_*` name is Goals', listed or not, so an invented one gets
  # Goals' unknown_tool answer, not core's.
  @impl true
  def mcp_tool_bundles do
    if Platform.Goals.enabled?() do
      [
        %{
          name: "goals",
          definitions: Platform.Goals.ToolDefinitions.definitions(),
          tool_names: Platform.Goals.ToolDefinitions.names(),
          execute: &Platform.Goals.Tools.execute/3,
          owns_tool?: &String.starts_with?(&1, "goal_")
        }
      ]
    else
      []
    end
  end

  @impl true
  def permissions do
    if Platform.Goals.enabled?(),
      do: [
        %{
          module: "goals",
          permissions: ["goals.use"],
          rail: [%{key: :goals, permission: "goals.use"}],
          bundles: %{"goals" => "goals.use"}
        }
      ],
      else: []
  end

  @doc "Goals drives the goal of a space an active goal is opened to (Goals 7/8)."
  @impl true
  def claims_space_goal?(space_id), do: Platform.Goals.SpaceClaim.claimed?(space_id)

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

  # Build time only (a release host's `mix platform.extensions.assets`):
  # the templates for Tailwind to scan. Unconditional, like the migrations
  # path: the release is built without `GOALS_ENABLED`. No JS, no stylesheet.
  @lib_root Path.expand("../..", __DIR__)

  @impl true
  def assets, do: %{tailwind_sources: [@lib_root]}

  # Goals 4/8: the Goals destination. `hero-flag` is the canvas row's icon.
  @impl true
  def rail_items do
    if Platform.Goals.enabled?(),
      do: [
        %{
          key: :goals,
          label: "Goals",
          path: "/m/goals",
          hero_icon: "hero-flag",
          cluster: :working,
          root_only?: false
        }
      ],
      else: []
  end

  # Goals 4/8: the Goals screen, nested by core's generic `/m/<prefix>`
  # page. Core hands it only the user id and the URL's query;
  # `PlatformWeb.GoalsLive` re-reads the user and reads through the context.
  @impl true
  def live_pages do
    if Platform.Goals.enabled?(),
      do: [
        %{
          prefix: "goals",
          live_view: PlatformWeb.GoalsLive,
          title: "Goals",
          module: :goals,
          permission: "goals.use"
        }
      ],
      else: []
  end
end
