defmodule Platform.Experiments.Guardrails do
  @moduledoc """
  The limits an AGENT works inside when it runs experiments. Task 01a0d415
  stage 2, the experimentation-layer ADR-0052.

  ## Which row applies: `for_org/1`

  The org's own `experiment_guardrails` row; else THE install-wide row
  (`org_id IS NULL` — stage 1's NULLS NOT DISTINCT index makes it unique, so
  `Repo.one` cannot see two); else the BUILT-IN DEFAULT:

    * `require_human_approval: false` — launch approval is opt-in per org
      (Rowan, 2026-09-24). Under the default an agent's `experiment_start`
      goes straight to `running`, still inside every other rule below.
    * `max_live: 3`
    * `allowed_surfaces:` every registered surface except a mail SEND path
      (see `default_allowed_surfaces/0`). The column default on a stored row
      is `[]`; the built-in default is not, because with no row at all an
      empty list would refuse every surface and "default launches within
      guardrails" would mean nothing launches.
    * `allow_auto_promote: false`

  A stored row is authoritative as written: its `allowed_surfaces` NARROWS
  the default and is never merged with it, so a row with `[]` allows no
  surface to an agent. That is the safer reading of an explicit row — an
  admin who wrote a list meant that list.

  ## `check/3` — refusals are structs, not prose

  `check(:create | :start | :promote, experiment, actor)` returns `:ok` or
  `{:error, %Refusal{code, limit, current, surface}}` (mirrors
  `Platform.Experiments.Promotion.Refusal`). The rules for an AGENT actor:

    * `:surface_not_allowed` — the surface is not in `allowed_surfaces`.
    * `:max_live_reached` — `current` counts `running` experiments whose
      `org_id` IS NOT DISTINCT FROM the experiment's, written as `IS NULL`
      or `=` so the `(org_id, status)` index can serve it (Postgres cannot
      index the `IS NOT DISTINCT FROM` operator); `limit` is
      `for_org(org_id).max_live`.
    * `:surface_busy` — another `running` experiment on the same
      `(surface_key, surface_target)` whose tenancy OVERLAPS on the columns:
      a null org or project is wider and overlaps everything beneath it.
    * promote: `:auto_promote_disabled` unless `allow_auto_promote`, and
      `:surface_not_promotable` for ANY `mail.*` surface whatever the row
      says — automatic promotion of mail is not part of v1.

  A human (`%Platform.Accounts.User{}`) bypasses nothing except the approval
  itself and the agent-only rules: `allowed_surfaces` and the auto-promote
  switches are limits on what an AGENT may do unattended. `max_live` and
  `surface_busy` hold for a human start too, because they protect the
  measurement, not the operator.

  Tenancy is read from the `org_id` / `project_id` COLUMNS only. There is no
  JSON path access anywhere in this module, and a test pins that.

  ## The start race

  `with_start_lock/2` takes `pg_advisory_xact_lock` on the org (a fixed key
  for a null org) and then on the `(surface_key, surface_target)` pair,
  always in that order, inside the caller's transaction. The org lock makes
  two concurrent starts in one org unable to both pass `max_live`; the
  surface lock does the same for `surface_busy` across orgs (an install-wide
  and an org-only start on one target take different org locks). A fixed
  order means two starts can wait on each other but never deadlock.
  """

  import Ecto.Query

  alias Platform.Access
  alias Platform.Accounts.User
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Guardrail
  alias Platform.Experiments.Surfaces
  alias Platform.Repo

  defmodule Refusal do
    @moduledoc """
    A guardrail refusal in discrete fields. `message` is for a log line; no
    caller may parse it.
    """

    @type t :: %__MODULE__{
            code: :surface_not_allowed | :max_live_reached | :surface_busy | atom(),
            limit: non_neg_integer() | nil,
            current: non_neg_integer() | nil,
            surface: String.t() | nil,
            message: String.t() | nil
          }

    @enforce_keys [:code]
    defstruct [:code, :limit, :current, :surface, :message]
  end

  @built_in_max_live 3
  @install_lock_key "experiments.guardrails:install"

  @typedoc "Who is acting. An agent is `%Agent{}` or `:agent`; a human is `%User{}`."
  @type actor :: User.t() | Platform.Agents.Agent.t() | :agent

  @doc """
  The surfaces an agent may use when no guardrail row exists: every
  registered surface except a mail send path. The registry holds no send-path
  surface today, so this is every registered surface; the filter is the
  statement that one added later is not allowed by default.
  """
  @spec default_allowed_surfaces() :: [String.t()]
  def default_allowed_surfaces do
    Surfaces.list()
    |> Enum.map(& &1.key())
    |> Enum.reject(&send_path?/1)
  end

  @doc "Is `key` a mail send path? Such a key can never be allowed or stored."
  @spec send_path?(String.t()) :: boolean()
  def send_path?(key) when is_binary(key), do: String.starts_with?(key, "mail.send")
  def send_path?(_key), do: false

  @doc "Is `key` a `mail.*` surface? Those are never promoted by an agent in v1."
  @spec mail_surface?(String.t() | nil) :: boolean()
  def mail_surface?(key) when is_binary(key), do: String.starts_with?(key, "mail.")
  def mail_surface?(_key), do: false

  @doc """
  The guardrails that apply to `org_id` (nil = install-wide): the org's row,
  else the install-wide row, else the built-in default (an unsaved
  `%Guardrail{}` with a nil id). See the moduledoc.
  """
  @spec for_org(Ecto.UUID.t() | nil) :: Guardrail.t()
  def for_org(org_id) do
    org_row(org_id) || install_row() || built_in()
  end

  @doc "The built-in default guardrails (no row anywhere)."
  @spec built_in() :: Guardrail.t()
  def built_in do
    %Guardrail{
      org_id: nil,
      max_live: @built_in_max_live,
      allowed_surfaces: default_allowed_surfaces(),
      require_human_approval: false,
      allow_auto_promote: false
    }
  end

  @doc """
  The org's OWN stored row (nil = THE install-wide row), or nil when none has
  been saved. Unlike `for_org/1` this does not fall back: it answers "is
  there a row to edit", which the admin panel needs to say whether it is
  showing a stored row or an inherited one.
  """
  @spec stored_row(Ecto.UUID.t() | nil) :: Guardrail.t() | nil
  def stored_row(nil), do: install_row()
  def stored_row(org_id), do: org_row(org_id)

  @saved_fields [:max_live, :allowed_surfaces, :require_human_approval, :allow_auto_promote]

  @doc """
  A HUMAN admin writes the guardrail row for `org_id` (nil = THE install-wide
  row). Task 01a0d415 stage 6.

  An UPSERT on the stage-1 unique index (`NULLS NOT DISTINCT`, so the
  install-wide row conflicts with itself too): saving twice leaves one row.

  ## A field the caller did not send keeps its EFFECTIVE value

  Every field absent from `attrs` is filled from `for_org(org_id)` before the
  write — the value that applied a moment ago, whether it came from the
  org's row, the install-wide row or the built-in default. The column
  default for `allowed_surfaces` is `[]`, and a stored row is authoritative
  as written, so without this an admin who saved a row only to change
  `max_live` would silently refuse every surface to every agent in that org.
  The panel pre-fills the same values; this is the server-side half, so a
  caller that never rendered the panel cannot trip it either.

  ## Install-level (task 01a1386d-fb6e stage 2)

  A guardrail save is a human experiments write, so it re-checks
  `Platform.Access.authorize_install/1` and returns `{:error, :unauthorized}`
  for anyone else, writing nothing
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`).
  """
  @spec save(Ecto.UUID.t() | nil, map(), User.t()) ::
          {:ok, Guardrail.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def save(org_id, attrs, %User{} = user) when is_map(attrs) do
    with :ok <- Access.authorize_install(user), do: upsert(org_id, attrs, user)
  end

  defp upsert(org_id, attrs, %User{id: user_id}) do
    effective = for_org(org_id)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    base =
      Map.new(@saved_fields, fn field -> {to_string(field), Map.fetch!(effective, field)} end)

    params =
      base
      |> Map.merge(Map.take(attrs, Enum.map(@saved_fields, &to_string/1)))
      |> Map.put("org_id", org_id)
      |> Map.put("updated_by_user_id", user_id)

    %Guardrail{}
    |> Guardrail.changeset(params)
    |> Repo.insert(
      on_conflict: {:replace, @saved_fields ++ [:updated_by_user_id, :updated_at]},
      conflict_target: :org_id,
      returning: true
    )
  end

  defp org_row(nil), do: nil

  defp org_row(org_id) do
    if Platform.UUID.valid?(org_id),
      do: Repo.one(from(g in Guardrail, where: g.org_id == ^org_id))
  end

  defp install_row, do: Repo.one(from(g in Guardrail, where: is_nil(g.org_id)))

  @doc """
  How many experiments are `running` in exactly this org (nil = the
  install-wide experiments, not every org).
  """
  @spec live_count(Ecto.UUID.t() | nil) :: non_neg_integer()
  def live_count(org_id) do
    from(e in Experiment, where: e.status == "running")
    |> same_org(org_id)
    |> Repo.aggregate(:count)
  end

  # IS NOT DISTINCT FROM semantics, spelled as two indexable predicates.
  # Postgres cannot use a btree index for `IS NOT DISTINCT FROM` itself, so
  # the literal operator would make the `(org_id, status)` index decorative;
  # `IS NULL` and `=` are both served by it.
  defp same_org(query, nil), do: where(query, [e], is_nil(e.org_id))
  defp same_org(query, org_id), do: where(query, [e], e.org_id == ^org_id)

  @doc "Checks one action against the guardrails. See the moduledoc."
  @spec check(:create | :start | :promote, Experiment.t(), actor()) ::
          :ok | {:error, Refusal.t()}
  def check(action, %Experiment{} = experiment, actor) do
    rails = for_org(experiment.org_id)

    case action do
      :create -> check_surface(experiment, rails, actor)
      :start -> check_start(experiment, rails, actor)
      :promote -> check_promote(experiment, rails, actor)
    end
  end

  defp check_start(experiment, rails, actor) do
    with :ok <- check_surface(experiment, rails, actor),
         :ok <- check_max_live(experiment, rails) do
      check_surface_busy(experiment)
    end
  end

  defp check_surface(_experiment, _rails, %User{}), do: :ok

  defp check_surface(%Experiment{surface_key: key}, rails, _agent) do
    if is_binary(key) and not send_path?(key) and key in (rails.allowed_surfaces || []) do
      :ok
    else
      {:error,
       %Refusal{
         code: :surface_not_allowed,
         surface: key,
         message: "surface #{inspect(key)} is not in this org's allowed_surfaces"
       }}
    end
  end

  defp check_max_live(%Experiment{org_id: org_id}, rails) do
    current = live_count(org_id)

    if current < rails.max_live do
      :ok
    else
      {:error,
       %Refusal{
         code: :max_live_reached,
         limit: rails.max_live,
         current: current,
         message: "#{current} of #{rails.max_live} live experiments are running"
       }}
    end
  end

  defp check_surface_busy(%Experiment{} = e) do
    busy =
      from(o in Experiment,
        where:
          o.status == "running" and o.id != ^e.id and o.surface_key == ^e.surface_key and
            o.surface_target == ^e.surface_target
      )
      |> overlapping(:org_id, e.org_id)
      |> overlapping(:project_id, e.project_id)
      |> Repo.aggregate(:count)

    if busy == 0 do
      :ok
    else
      {:error,
       %Refusal{
         code: :surface_busy,
         current: busy,
         surface: e.surface_key,
         message:
           "#{busy} running experiment(s) on #{e.surface_key} #{inspect(e.surface_target)} " <>
             "overlap this one's org and project"
       }}
    end
  end

  # NULL is wider: a null column on either side overlaps everything.
  defp overlapping(query, _field, nil), do: query

  defp overlapping(query, field, value) do
    where(query, [o], is_nil(field(o, ^field)) or field(o, ^field) == ^value)
  end

  defp check_promote(_experiment, _rails, %User{}), do: :ok

  defp check_promote(%Experiment{surface_key: key}, rails, _agent) do
    cond do
      mail_surface?(key) ->
        {:error,
         %Refusal{
           code: :surface_not_promotable,
           surface: key,
           message: "#{key} is a mail surface; an agent never promotes it in v1"
         }}

      rails.allow_auto_promote != true ->
        {:error,
         %Refusal{
           code: :auto_promote_disabled,
           surface: key,
           message: "allow_auto_promote is off for this org"
         }}

      true ->
        :ok
    end
  end

  @doc """
  Runs `fun` inside ONE transaction holding the start locks for
  `experiment`. See the moduledoc. Returns what the transaction returns;
  `fun` may call `Repo.rollback/1`.
  """
  @spec with_start_lock(Experiment.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  def with_start_lock(%Experiment{} = experiment, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      lock!(org_lock_key(experiment.org_id))
      lock!("experiments.surface:#{experiment.surface_key}:#{experiment.surface_target}")
      fun.()
    end)
  end

  defp org_lock_key(nil), do: @install_lock_key
  defp org_lock_key(org_id), do: "experiments.guardrails:org:#{org_id}"

  defp lock!(key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end
end
