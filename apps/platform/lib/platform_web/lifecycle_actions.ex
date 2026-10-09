defmodule PlatformWeb.LifecycleActions do
  @moduledoc """
  Thin web-layer adapter over the container lifecycle (task 019f4eaa
  stage 6). Resolves a `{resource_type, id}` pair coming off a
  `phx-click` into the matching `Platform.Tenancy` / `Platform.Tasks`
  lifecycle call, so the three surfaces that drive archive / schedule /
  restore — the Tasks sidebar, the Chat sidebar, and the Recovery view —
  share ONE resolution + error-message path instead of duplicating it.

  This module only **calls** the stage-3 lifecycle functions; it owns no
  business logic of its own. Authorization, the root-org guard, the
  provenance cascade, and audit all live in
  `Platform.Tenancy.Lifecycle`. A non-admin `actor` still gets
  `{:error, :unauthorized}` from underneath even if a forged event
  reaches here, so this is defence-in-depth, not the only gate.

  `resource_type` is the wire string `"org"` or `"project"`. Org ids may
  arrive as either a slug (Tasks sidebar) or a UUID (Chat sidebar /
  Recovery), so `resolve_org/1` accepts both. A resource that no longer
  exists resolves to `{:error, :not_found}`.
  """

  alias Platform.{Tasks, Tenancy}

  @type actor :: map() | nil
  @type result :: {:ok, struct()} | {:error, atom() | Ecto.Changeset.t()}

  @doc "Instant, reversible archive. `id` is a slug or UUID for orgs, a UUID for projects."
  @spec archive(actor(), String.t(), String.t()) :: result()
  def archive(actor, type, id),
    do: dispatch(type, id, &Tenancy.archive_org(actor, &1), &Tasks.archive_project(actor, &1))

  @doc "Flag for permanent deletion after the retention window."
  @spec schedule_deletion(actor(), String.t(), String.t()) :: result()
  def schedule_deletion(actor, type, id),
    do:
      dispatch(
        type,
        id,
        &Tenancy.schedule_org_deletion(actor, &1),
        &Tasks.schedule_project_deletion(actor, &1)
      )

  @doc """
  Schedule an org for deletion, sparing the child ids in `keep_ids` (task
  019f7600 stage 5 — the "surface & choose" delete confirm). Projects have no
  children, so `keep_ids` is ignored on that branch and this is identical to
  `schedule_deletion/3`.
  """
  @spec schedule_deletion(actor(), String.t(), String.t(), [String.t()]) :: result()
  def schedule_deletion(actor, type, id, keep_ids) when is_list(keep_ids),
    do:
      dispatch(
        type,
        id,
        &Platform.Tenancy.Lifecycle.schedule_org_deletion(actor, &1, keep_ids),
        &Tasks.schedule_project_deletion(actor, &1)
      )

  @doc "Reverse an archive — brings a purely-archived container back to active."
  @spec unarchive(actor(), String.t(), String.t()) :: result()
  def unarchive(actor, type, id),
    do: dispatch(type, id, &Tenancy.unarchive_org(actor, &1), &Tasks.unarchive_project(actor, &1))

  @doc "Cancel a scheduled deletion — brings a deletion-scheduled container back to active."
  @spec cancel_deletion(actor(), String.t(), String.t()) :: result()
  def cancel_deletion(actor, type, id),
    do:
      dispatch(
        type,
        id,
        &Tenancy.cancel_org_deletion(actor, &1),
        &Tasks.cancel_project_deletion(actor, &1)
      )

  @doc """
  What the confirm dialog should say goes with this resource:
  `%{projects: [name], channels: [name]}`.

  Orgs cascade, so this lists the children that would actually be hidden.
  Projects stand alone — always an empty preview.

  Resolution matters here: the Tasks sidebar posts org SLUGS
  (`id={org_slug}`) while Chat and Recovery post UUIDs, and
  `Lifecycle.cascade_preview/1` takes a UUID. Routing through `resolve_org/1`
  is what keeps a slug from reaching the query.
  """
  @spec cascade_preview(String.t(), String.t()) :: %{
          projects: [String.t()],
          channels: [String.t()]
        }
  def cascade_preview("org", id) do
    case resolve_org(id) do
      nil -> %{projects: [], channels: []}
      org -> Platform.Tenancy.Lifecycle.cascade_preview(org.id)
    end
  end

  def cascade_preview(_type, _id), do: %{projects: [], channels: []}

  @doc """
  The full blast radius of deleting an org: every child project + channel that
  would be lost with it, in every lifecycle state, ready for the delete confirm's
  include/keep checklist (task 019f7600 stage 5). `[]` for projects (no children).

  Same slug-or-UUID resolution as `cascade_preview/2` — the Tasks sidebar posts
  org slugs, Chat/Recovery post UUIDs, and `Lifecycle.purge_preview/1` needs a
  UUID.
  """
  @spec purge_preview(String.t(), String.t()) :: [Platform.Tenancy.Lifecycle.purge_item()]
  def purge_preview("org", id) do
    case resolve_org(id) do
      nil -> []
      org -> Platform.Tenancy.Lifecycle.purge_preview(org.id)
    end
  end

  def purge_preview(_type, _id), do: []

  @doc """
  Flat labels for what this resource's cascade is CURRENTLY hiding — channels
  prefixed with `#`, ready to render. `[]` for projects (no cascade).

  Call AFTER an archive to say what it took: `cascade_preview/2` would return
  nothing at that point, because the children are no longer active. Same
  slug-or-UUID resolution as everything else here.
  """
  @spec cascade_hidden_labels(String.t(), String.t()) :: [String.t()]
  def cascade_hidden_labels("org", id) do
    case resolve_org(id) do
      nil ->
        []

      org ->
        %{projects: projects, channels: channels} =
          Platform.Tenancy.Lifecycle.cascade_hidden(org.id)

        projects ++ Enum.map(channels, &("#" <> &1))
    end
  end

  def cascade_hidden_labels(_type, _id), do: []

  # Resolve the resource, then hand it to the org- or project-specific fn.
  defp dispatch("org", id, org_fun, _project_fun) do
    case resolve_org(id) do
      nil -> {:error, :not_found}
      org -> org_fun.(org)
    end
  end

  defp dispatch("project", id, _org_fun, project_fun) do
    case Tasks.get_project(id) do
      nil -> {:error, :not_found}
      project -> project_fun.(project)
    end
  end

  defp dispatch(_type, _id, _org_fun, _project_fun), do: {:error, :not_found}

  # Orgs are addressed by slug from the Tasks sidebar and by UUID from the
  # Chat sidebar / Recovery view. Try the slug first (cheap unique index),
  # then fall back to a UUID lookup.
  defp resolve_org(id) when is_binary(id) do
    Tenancy.get_org_by_slug(id) || Tenancy.get_org(id)
  end

  defp resolve_org(_), do: nil

  @doc """
  Map a lifecycle error tuple to a plain-language flash message. Anything
  unexpected (a changeset, an unknown atom) collapses to a generic line so
  the UI never surfaces an internal reason.
  """
  @spec error_message(atom() | Ecto.Changeset.t()) :: String.t()
  def error_message(:unauthorized), do: "You don't have permission to do that."
  def error_message(:not_deletable), do: "The root org can't be archived or deleted."
  def error_message(:not_scheduled), do: "That item isn't scheduled for deletion."
  def error_message(:not_found), do: "That item no longer exists."
  def error_message(_other), do: "Something went wrong — please try again."
end
