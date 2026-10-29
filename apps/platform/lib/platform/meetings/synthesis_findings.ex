defmodule Platform.Meetings.SynthesisFindings do
  @moduledoc """
  The shared store for meeting brief synthesis findings (task
  `01a16974-e3db-7000-97e9-8ec9611189bc`, stage 1).

  A finding is written once per `(org_id, dedupe_key)` by `upsert/1` and
  referenced from each briefing it appears in by an item of kind
  `"finding"` with ref `"finding:<id>"` (`ref/1`, `item/1`). The item's
  resolution is the finding's `receipt`, read and written by
  `Platform.Meetings.MeetingBriefings.view/2` and `act/5`.
  """

  import Ecto.Query

  alias Platform.Meetings.SynthesisFinding
  alias Platform.Repo

  @doc "The briefing item ref for `finding`."
  @spec ref(SynthesisFinding.t() | binary()) :: String.t()
  def ref(%SynthesisFinding{id: id}), do: ref(id)
  def ref(id) when is_binary(id), do: "finding:" <> id

  @doc """
  The `{key, item}` pair a briefing stores for `finding`: kind
  `"finding"`, ref `ref/1`, keyed by `MeetingBriefings.node_key/1`.
  """
  @spec item(SynthesisFinding.t()) :: {String.t(), map()}
  def item(%SynthesisFinding{} = finding) do
    ref = ref(finding)

    {Platform.Meetings.MeetingBriefings.node_key(ref),
     %{"kind" => "finding", "ref" => ref, "title" => finding.body || "", "filed_status" => nil}}
  end

  @doc """
  Insert a finding, or merge into the existing one with the same
  `(org_id, dedupe_key)`.

  On a dedupe hit the existing row keeps its id, body, citations and
  receipt; `meeting_ids` and `recipient_user_ids` are unioned. The row is
  locked `FOR UPDATE` for the merge, so two concurrent mirrored runs
  serialise onto one row.

  Returns `{:ok, finding, :created | :merged}` or `{:error, changeset}`.
  """
  @spec upsert(map()) ::
          {:ok, SynthesisFinding.t(), :created | :merged} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    changeset = SynthesisFinding.changeset(%SynthesisFinding{}, attrs)

    if changeset.valid? do
      Repo.transaction(fn -> do_upsert(changeset) end)
      |> case do
        {:ok, {finding, status}} -> {:ok, finding, status}
        {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      end
    else
      {:error, changeset}
    end
  end

  defp do_upsert(changeset) do
    org_id = Ecto.Changeset.get_field(changeset, :org_id)
    dedupe_key = Ecto.Changeset.get_field(changeset, :dedupe_key)

    # The id is generated client-side, so an ON CONFLICT DO NOTHING insert
    # returns a struct carrying an id even when no row was written. The
    # re-read under lock is the arbiter: same id means this call created it.
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:org_id, :dedupe_key]) do
      {:ok, attempted} ->
        existing =
          Repo.one!(
            from(f in SynthesisFinding,
              where: f.org_id == ^org_id and f.dedupe_key == ^dedupe_key,
              lock: "FOR UPDATE"
            )
          )

        if existing.id == attempted.id do
          {existing, :created}
        else
          {merge!(existing, changeset), :merged}
        end

      {:error, cs} ->
        Repo.rollback(cs)
    end
  end

  defp merge!(existing, changeset) do
    meeting_ids = union(existing.meeting_ids, Ecto.Changeset.get_field(changeset, :meeting_ids))

    recipients =
      union(existing.recipient_user_ids, Ecto.Changeset.get_field(changeset, :recipient_user_ids))

    existing
    |> Ecto.Changeset.change(meeting_ids: meeting_ids, recipient_user_ids: recipients)
    |> Repo.update!()
  end

  defp union(a, b), do: Enum.uniq((a || []) ++ (b || []))

  @doc "The finding with `id`, or nil (malformed ids answer nil)."
  @spec get(term()) :: SynthesisFinding.t() | nil
  def get(id) when is_binary(id) do
    if Platform.UUID.valid?(id), do: Repo.get(SynthesisFinding, id)
  end

  def get(_id), do: nil

  @doc "The findings among `ids`, as `%{id => finding}`. Malformed ids are dropped."
  @spec get_many([binary()]) :: %{binary() => SynthesisFinding.t()}
  def get_many(ids) when is_list(ids) do
    case Enum.filter(ids, &(is_binary(&1) and Platform.UUID.valid?(&1))) do
      [] ->
        %{}

      valid ->
        from(f in SynthesisFinding, where: f.id in ^valid)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  Every finding whose `meeting_ids` contains `meeting_id`, oldest first.
  Uses array containment (`@>`) so the GIN index on `meeting_ids` serves it.
  """
  @spec list_for_meeting(binary()) :: [SynthesisFinding.t()]
  def list_for_meeting(meeting_id) when is_binary(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      from(f in SynthesisFinding,
        where:
          fragment("? @> ?", f.meeting_ids, type(^[meeting_id], {:array, :binary_id})),
        order_by: [asc: f.inserted_at, asc: f.id]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc false
  # Lock the finding row inside the caller's transaction (MeetingBriefings.act/5).
  @spec lock(binary()) :: SynthesisFinding.t() | nil
  def lock(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      Repo.one(from(f in SynthesisFinding, where: f.id == ^id, lock: "FOR UPDATE"))
    end
  end

  def lock(_id), do: nil
end
