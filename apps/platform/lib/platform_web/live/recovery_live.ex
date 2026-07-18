defmodule PlatformWeb.RecoveryLive do
  @moduledoc """
  Recovery surface for archived / deletion-scheduled containers — orgs and
  projects (task 019f4eaa stage 6). The one place a Fabrikam admin can bring a
  retired org or project back.

  One structured table (task 019f4eaa review), a row per retired container
  with `status` + `archived on` + `auto-deletes` columns. Scheduled rows sort
  to the top (soonest permanent-delete first — the rows that need attention);
  archived rows follow, by name. Cascade-hidden children are intentionally
  absent: they come back with their org, so the read queries
  (`Tenancy.list_archived_tenants/0`, `Tasks.list_archived_projects/0`) only
  surface independently-archived rows.

  Fabrikam-only gate is inherited from the `:admin` live_session's
  `PlatformWeb.LiveAuth.ensure_admin` hook; every restore also re-authorizes
  underneath in `Platform.Tenancy.Lifecycle`.

  ## Restore is the only action

  Every row ends with a single visually-primary **Restore** that returns the
  container to active, whatever state it is in — `cancel_*_deletion` for a
  scheduled row (undo the delete), `unarchive_*` for an archived one. Both
  clear the lifecycle flags via the stage-3 lifecycle and un-hide the org's
  cascade children.

  The two states this table shows are terminal until someone acts:
  a **scheduled** row counts down to a permanent delete; an **archived** row
  stays archived in perpetuity with no deadline (its `auto-deletes` cell is an
  em-dash). There is deliberately no intermediate "stop the countdown but stay
  archived" action — it duplicated Restore without giving the admin anything
  Restore does not (task 019f4eaa review).
  """
  use PlatformWeb, :live_view

  alias Platform.{Tasks, Tenancy}
  alias Platform.Tenancy.Lifecycle
  alias PlatformWeb.LifecycleActions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Recovery")
     |> load_entries()}
  end

  @impl true
  def handle_event("restore", %{"type" => type, "id" => id, "action" => action}, socket) do
    actor = socket.assigns[:current_user_record]

    result =
      case action do
        "cancel" -> LifecycleActions.cancel_deletion(actor, type, id)
        _ -> LifecycleActions.unarchive(actor, type, id)
      end

    case result do
      {:ok, _resource} ->
        {:noreply,
         socket
         |> load_entries()
         |> put_flash(:info, "Restored — it's active again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LifecycleActions.error_message(reason))}
    end
  end

  # Load every independently-archived container. Called on mount and after
  # every restore so the list stays live without a page reload.
  defp load_entries(socket) do
    entries =
      Enum.map(Tenancy.list_archived_tenants(), &org_entry/1) ++
        Enum.map(Tasks.list_archived_projects(), &project_entry/1)

    {scheduled, archived} = Enum.split_with(entries, & &1.scheduled?)

    # One table, scheduled rows first (soonest permanent-delete first) so the
    # rows that need attention sit at the top; archived (no deadline) below,
    # by name. The `status` column tells the two apart.
    ordered =
      Enum.sort_by(scheduled, & &1.deletion_scheduled_at, DateTime) ++
        Enum.sort_by(archived, & &1.name)

    socket
    |> assign(:retention_days, Lifecycle.retention_days())
    |> assign(:entries, ordered)
  end

  defp org_entry(org) do
    %{
      type: "org",
      id: org.id,
      name: org.name,
      kind_label: "Org",
      scope_slug: org.slug,
      scheduled?: not is_nil(org.deletion_scheduled_at),
      archived_at: org.archived_at,
      deletion_scheduled_at: org.deletion_scheduled_at,
      # What this org's Restore will bring back with it (Marlowe's ask,
      # 2026-07-16). Cascade children are deliberately not rows of their own —
      # they return WITH the org, so a separate Restore for them would imply
      # you could surface a project under a still-hidden org. But the row must
      # still SAY what's inside rather than make you restore blind.
      hidden: Lifecycle.cascade_hidden(org.id)
    }
  end

  defp project_entry(project) do
    %{
      type: "project",
      id: project.id,
      name: project.name,
      kind_label: "Project",
      scope_slug: project.org && project.org.slug,
      scheduled?: not is_nil(project.deletion_scheduled_at),
      archived_at: project.archived_at,
      deletion_scheduled_at: project.deletion_scheduled_at,
      # A project has no cascade of its own — it stands alone.
      hidden: %{projects: [], channels: []}
    }
  end

  @doc """
  Flat list of what an entry's Restore brings back with it, for the row's
  secondary line. Empty for projects and for an org whose children were all
  archived independently — in both cases Restore affects only the row itself.
  """
  def hidden_labels(%{hidden: %{projects: projects, channels: channels}}),
    do: projects ++ Enum.map(channels, &("#" <> &1))

  def hidden_labels(_), do: []

  @doc "Permanent-delete date for a scheduled row: `deletion_scheduled_at + retention_days`."
  def permanent_delete_at(nil, _retention_days), do: nil

  def permanent_delete_at(%DateTime{} = scheduled_at, retention_days),
    do: DateTime.add(scheduled_at, retention_days, :day)

  @doc "Compact date label (e.g. `Jul 15, 2026`); em-dash for nil."
  def format_date(nil), do: "—"
  def format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")

  # Tint the permanent-delete date as the window closes (mirrors runway tone).
  defp deadline_class("error"), do: "text-error font-medium"
  defp deadline_class("warning"), do: "text-warning"
  defp deadline_class(_neutral), do: "text-base-content"

  @doc """
  Retention runway for a scheduled row: `{tone, label}` where tone
  graduates neutral → warning → error as the window closes. Pure
  presentation — the deadline is `deletion_scheduled_at + retention_days`.
  """
  def runway(deletion_scheduled_at, retention_days, now \\ DateTime.utc_now()) do
    deadline = DateTime.add(deletion_scheduled_at, retention_days, :day)
    days_left = max(0, ceil(DateTime.diff(deadline, now, :second) / 86_400))

    tone =
      cond do
        days_left <= 2 -> "error"
        days_left <= 7 -> "warning"
        true -> "neutral"
      end

    {tone, runway_label(days_left)}
  end

  defp runway_label(0), do: "Deletes today"
  defp runway_label(1), do: "Deletes tomorrow"
  defp runway_label(n), do: "Deletes in #{n} days"

  # Heroicon per container kind — a quiet leading affordance in the Name cell.
  defp kind_icon("org"), do: "hero-building-office-2"
  defp kind_icon(_project), do: "hero-folder"
end
