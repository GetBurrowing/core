defmodule Platform.Meetings.IntentCorrections do
  @moduledoc """
  Context for `meeting_intent_corrections` — writing the durable
  few-shot corpus and reading it back as classifier exemplars
  (task 019f70b8 stage 6).

  ## Two writers

    * **Human** — the stage-7 X / pencil controls on the intents-collapse
      bar, which pass an `actor_participant_id`.
    * **System** — `Platform.Meetings.IntentCorrections.TelemetryHandler`,
      off the two correction hooks the queue emits at its transition
      sites (a rejected ack, and a `:no_ack_spawn_failed` timeout).
      These carry no actor.

  Nothing on the dispatch/ack/timeout happy path writes here: a meeting
  where the classifier was right every time leaves ZERO durable rows
  (AC17). That is an invariant, not a performance note — this table is a
  record of being wrong, and rows appearing without a correction would
  poison the corpus with examples of correct behaviour labelled as
  errors.

  ## `org_id` is derived, not passed

  `create_correction/1` resolves the org from the meeting
  (`meetings.project_id -> projects.org_id`) whenever the caller does
  not supply one, so no caller can write a row that is invisible to the
  org-scoped exemplar query by forgetting a field. Derivation is
  non-fatal: an unresolvable meeting still gets its row, with a nil
  `org_id`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project

  # Default exemplar window. Big enough to carry an org's vocabulary,
  # small enough that the classifier prompt stays a classifier prompt
  # rather than a transcript of everything anyone ever fixed.
  @default_exemplar_limit 10

  @doc "Default number of exemplars `recent_exemplars/2` returns."
  @spec default_exemplar_limit() :: pos_integer()
  def default_exemplar_limit, do: @default_exemplar_limit

  @doc """
  Insert a correction row.

  When `attrs` carries no `:org_id`, it is derived from `:meeting_id`.
  Returns `{:ok, correction}` or `{:error, changeset}`.
  """
  @spec create_correction(map()) :: {:ok, IntentCorrection.t()} | {:error, Ecto.Changeset.t()}
  def create_correction(attrs) when is_map(attrs) do
    %IntentCorrection{}
    |> IntentCorrection.changeset(put_derived_org_id(attrs))
    |> Repo.insert()
  end

  @doc """
  The most-recent `limit` corrections for `org_id`, newest first.

  Backed by the `(org_id, inserted_at)` index — this is the classifier's
  per-chunk read, so it must stay a single indexed scan. Returns `[]`
  for a nil org rather than falling back to a cross-org read: exemplars
  from another tenant's meetings are exactly what must not leak into a
  classification.
  """
  @spec recent_exemplars(binary() | nil, pos_integer()) :: [IntentCorrection.t()]
  def recent_exemplars(org_id, limit \\ @default_exemplar_limit)

  def recent_exemplars(nil, _limit), do: []

  def recent_exemplars(org_id, limit)
      when is_binary(org_id) and is_integer(limit) and limit > 0 do
    IntentCorrection
    |> where([c], c.org_id == ^org_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Exemplars for whatever org owns `meeting_id`.

  The classifier holds a meeting id and nothing else, so the org join
  lives here rather than at the call site. Returns `[]` — never raises —
  when the meeting, its project, or the DB itself is unavailable: a
  missing exemplar set must degrade the prompt, never drop a
  classification.
  """
  @spec exemplars_for_meeting(binary() | nil, pos_integer()) :: [IntentCorrection.t()]
  def exemplars_for_meeting(meeting_id, limit \\ @default_exemplar_limit)

  def exemplars_for_meeting(nil, _limit), do: []

  def exemplars_for_meeting(meeting_id, limit) when is_binary(meeting_id) do
    meeting_id
    |> org_id_for_meeting()
    |> recent_exemplars(limit)
  rescue
    error ->
      Logger.warning(
        "[IntentCorrections] exemplar lookup failed meeting_id=#{meeting_id} " <>
          "error=#{Exception.message(error)}"
      )

      []
  end

  @doc """
  Resolve `meeting_id` to its owning org via
  `meetings.project_id -> projects.org_id`.

  One query with one join. This is the lookup the denormalized
  `meeting_intent_corrections.org_id` column exists to keep OFF the
  corpus read — it runs once per chunk against `meetings`, not once per
  exemplar against the corpus.
  """
  @spec org_id_for_meeting(binary() | nil) :: binary() | nil
  def org_id_for_meeting(nil), do: nil

  def org_id_for_meeting(meeting_id) when is_binary(meeting_id) do
    Meeting
    |> where([m], m.id == ^meeting_id)
    |> join(:inner, [m], p in Project, on: p.id == m.project_id)
    |> select([_m, p], p.org_id)
    |> Repo.one()
  rescue
    # A malformed uuid reaches Ecto as a cast error, and the classifier
    # is free to hand us any meeting id a transcript payload carried.
    _ -> nil
  end

  @doc """
  Corrections recorded for one meeting, newest first.

  Backed by the `(meeting_id, inserted_at)` index. This is the
  per-meeting history the producer surface reads, distinct from the
  org-scoped exemplar query the classifier reads.
  """
  @spec list_for_meeting(binary(), pos_integer() | :all) :: [IntentCorrection.t()]
  def list_for_meeting(meeting_id, limit \\ :all)

  def list_for_meeting(meeting_id, :all) when is_binary(meeting_id) do
    meeting_id
    |> meeting_scope()
    |> Repo.all()
  end

  def list_for_meeting(meeting_id, limit)
      when is_binary(meeting_id) and is_integer(limit) and limit > 0 do
    meeting_id
    |> meeting_scope()
    |> limit(^limit)
    |> Repo.all()
  end

  defp meeting_scope(meeting_id) do
    IntentCorrection
    |> where([c], c.meeting_id == ^meeting_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
  end

  # Caller-supplied org wins (the stage-7 UI already holds one); an
  # absent key is derived. A caller that explicitly passes `nil` also
  # gets the derivation — passing nil is how "I don't know" arrives, not
  # an instruction to leave the column empty.
  defp put_derived_org_id(attrs) do
    case fetch_org_id(attrs) do
      {:ok, org_id} when is_binary(org_id) ->
        attrs

      _ ->
        put_attr(attrs, :org_id, org_id_for_meeting(fetch_meeting_id(attrs)))
    end
  end

  defp fetch_org_id(attrs) do
    case Map.fetch(attrs, :org_id) do
      :error -> Map.fetch(attrs, "org_id")
      found -> found
    end
  end

  defp fetch_meeting_id(attrs) do
    value = Map.get(attrs, :meeting_id) || Map.get(attrs, "meeting_id")
    if is_binary(value), do: value, else: nil
  end

  # `attrs` may be atom- or string-keyed (the telemetry handler builds
  # atom keys; a LiveView form arrives string-keyed). Match the shape
  # already present rather than mixing key types in one map, which
  # `cast/3` rejects.
  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, "meeting_id") do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
