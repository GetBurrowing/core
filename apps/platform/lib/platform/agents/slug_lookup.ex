defmodule Platform.Agents.SlugLookup do
  @moduledoc """
  Fail-closed resolution of an `Platform.Agents.Agent` by slug.

  ## Why this exists (task 01a0e77c)

  A slug is NOT globally unique. The only constraint is
  `agents_unique_slug`, a unique index on `(workspace_id, slug)`, so two
  workspaces can each hold an agent with the same slug. A bare
  `Repo.get_by(Agent, slug: s)` then raises `Ecto.MultipleResultsError` on
  whichever request path hits it.

  Worse, until the index was recreated `NULLS NOT DISTINCT`, it constrained
  nothing at all for the NULL-workspace rows that are 100% of production
  (22 of 22 on the prod install, measured 2026-09-28): Postgres treats two
  NULLs as distinct, so duplicate NULL-workspace slugs were insertable. That
  is why scoping every lookup to `workspace_id` alone would not help: in
  production it is always NULL and disambiguates nothing.

  ## Contract

  `resolve/2` fetches at most two rows, so "more than one" is a fact about
  the data rather than a count racing the read (the same shape as
  `Platform.Vault`'s private `resolve_one_by_slug/2`):

    * no row -> `{:error, :not_found}`
    * exactly one -> `{:ok, agent}`
    * two or more -> `{:error, :ambiguous_slug}`, plus ONE `Logger.warning`
      naming the slug, the scope used and the ids and workspace_ids of the
      two rows fetched. It never picks one: preferring either row would
      silently route work to the wrong agent.

  The UUID branch (looking an agent up by id when the value is a UUID) stays
  at each call site; this module only ever matches on slug.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Repo

  @doc """
  Resolve exactly one agent by `slug`.

  ## Options

    * `:workspace_id` - when the key is ABSENT the lookup is unscoped
      (slug alone). When present and `nil` it matches `workspace_id IS NULL`
      (never `= NULL`, which matches nothing). When a binary, it matches
      that workspace.

  A non-binary or empty slug is `{:error, :not_found}`.
  """
  @spec resolve(term(), keyword()) :: {:ok, %Agent{}} | {:error, :not_found | :ambiguous_slug}
  def resolve(slug, opts \\ [])

  def resolve(slug, opts) when is_binary(slug) and slug != "" do
    scope = Keyword.fetch(opts, :workspace_id)

    query =
      from(a in Agent, where: a.slug == ^slug, order_by: [asc: a.id], limit: 2)
      |> scope_query(scope)

    case Repo.all(query) do
      [] ->
        {:error, :not_found}

      [agent] ->
        {:ok, agent}

      [_, _] = rows ->
        log_ambiguous(slug, scope, rows)
        {:error, :ambiguous_slug}
    end
  end

  def resolve(_slug, _opts), do: {:error, :not_found}

  defp scope_query(query, :error), do: query
  defp scope_query(query, {:ok, nil}), do: where(query, [a], is_nil(a.workspace_id))
  defp scope_query(query, {:ok, wid}), do: where(query, [a], a.workspace_id == ^wid)

  defp log_ambiguous(slug, scope, rows) do
    rows_desc =
      Enum.map_join(rows, ", ", fn a -> "id=#{a.id} workspace_id=#{inspect(a.workspace_id)}" end)

    Logger.warning(
      "Platform.Agents.SlugLookup: slug #{inspect(slug)} is ambiguous " <>
        "(scope: #{describe_scope(scope)}); refusing to pick one of: #{rows_desc}"
    )
  end

  defp describe_scope(:error), do: "unscoped"
  defp describe_scope({:ok, nil}), do: "workspace_id IS NULL"
  defp describe_scope({:ok, wid}), do: "workspace_id=#{wid}"
end
