defmodule Platform.Meetings.SynthesisFinding do
  @moduledoc """
  One cross-meeting alignment finding produced by meeting brief synthesis
  (task `01a16974-e3db-7000-97e9-8ec9611189bc`). Stored and read through
  `Platform.Meetings.SynthesisFindings`.

  ## Why a shared row

  A finding can appear in the briefing of every meeting in `meeting_ids`
  (for a cross-meeting conflict: the meeting that produced it and the
  meeting it conflicts with). Briefing receipts live per
  `Platform.Meetings.MeetingBriefing` row, so a receipt written in meeting
  A's briefing would be invisible in meeting B's. The finding's `receipt`
  therefore lives HERE, once, and every briefing item that references the
  finding (kind `"finding"`, ref `"finding:<id>"`) reads it from this row.

    * `kind` — `conflicts_with | duplicates | contradicts | depends_on`.
    * `confidence` — `Platform.Memory.Insight.confidences/0`.
    * `citations` — `[%{"source_kind", "ref", "title", "url", "requires"}]`.
      `"requires"` (optional) lists further `"kind:id"` refs a reader must
      also be able to read (a filed task seen through its meeting's
      briefing); `Platform.Meetings.MeetingBriefings` re-checks the ref and
      every required ref for the viewer at render and at click.
    * `recipient_user_ids` — who the finding is for.
    * `receipt` — nil until resolved, then the briefing receipt shape
      `%{"verb", "at", "by", "ref", "kind"}`. Written once.
    * `dedupe_key` — unique per `org_id`, `dedupe_key/2` of kind + the sorted
      cited refs, so mirrored runs collapse into one row.
    * `run_id` / `snapshot_hash` — audit: which synthesis run wrote it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(conflicts_with duplicates contradicts depends_on)

  @type t :: %__MODULE__{}

  schema "meeting_synthesis_findings" do
    field(:org_id, :binary_id)
    belongs_to(:origin_meeting, Platform.Meetings.Meeting)
    field(:meeting_ids, {:array, :binary_id}, default: [])
    field(:kind, :string)
    field(:confidence, :string)
    field(:body, :string)
    field(:citations, {:array, :map}, default: [])
    field(:recipient_user_ids, {:array, :binary_id}, default: [])
    field(:receipt, :map)
    field(:dedupe_key, :string)
    field(:run_id, :binary_id)
    field(:snapshot_hash, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The finding kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The dedupe key for a finding of `kind` citing `refs`: the first 32 hex of
  sha256 over the kind and the sorted, de-duplicated refs. Order-independent,
  so the same conflict found from either side yields the same key.
  """
  @spec dedupe_key(String.t(), [String.t()]) :: String.t()
  def dedupe_key(kind, refs) when is_binary(kind) and is_list(refs) do
    payload = Enum.join([kind | refs |> Enum.uniq() |> Enum.sort()], "\n")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  @doc """
  Insert changeset. Requires at least one citation with a binary `"ref"`;
  `meeting_ids` always includes `origin_meeting_id`; `dedupe_key` is derived
  from kind + cited refs. `receipt` is not castable here — it is written
  only by `receipt_changeset/2`.
  """
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :org_id,
      :origin_meeting_id,
      :meeting_ids,
      :kind,
      :confidence,
      :body,
      :citations,
      :recipient_user_ids,
      :run_id,
      :snapshot_hash
    ])
    |> update_change(:citations, fn citations -> Enum.map(citations, &stringify/1) end)
    |> validate_required([:org_id, :origin_meeting_id, :kind, :confidence, :body])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:confidence, Platform.Memory.Insight.confidences())
    |> validate_citations()
    |> put_origin_in_meeting_ids()
    |> put_dedupe_key()
    |> foreign_key_constraint(:origin_meeting_id)
    |> foreign_key_constraint(:org_id)
    |> unique_constraint([:org_id, :dedupe_key],
      name: :meeting_synthesis_findings_org_id_dedupe_key_index
    )
  end

  @doc "The one write of `receipt`."
  def receipt_changeset(finding, receipt) when is_map(receipt) do
    change(finding, receipt: receipt)
  end

  @doc "The cited refs, in citation order."
  @spec refs(t() | [map()]) :: [String.t()]
  def refs(%__MODULE__{citations: citations}), do: refs(citations)
  def refs(citations) when is_list(citations), do: Enum.map(citations, &(&1["ref"] || &1[:ref]))

  defp stringify(%{} = citation) do
    Map.new(citation, fn {k, v} -> {to_string(k), v} end)
    |> Map.take(~w(source_kind ref title url requires))
  end

  defp stringify(other), do: other

  defp validate_citations(changeset) do
    citations = get_field(changeset, :citations) || []

    cond do
      citations == [] ->
        add_error(changeset, :citations, "must cite at least one source")

      Enum.all?(citations, &(is_map(&1) and is_binary(&1["ref"]) and &1["ref"] != "")) ->
        changeset

      true ->
        add_error(changeset, :citations, "every citation needs a ref")
    end
  end

  defp put_origin_in_meeting_ids(changeset) do
    case get_field(changeset, :origin_meeting_id) do
      nil ->
        changeset

      origin ->
        ids = get_field(changeset, :meeting_ids) || []
        put_change(changeset, :meeting_ids, Enum.uniq([origin | ids]))
    end
  end

  defp put_dedupe_key(%Ecto.Changeset{valid?: true} = changeset) do
    put_change(
      changeset,
      :dedupe_key,
      dedupe_key(get_field(changeset, :kind), refs(get_field(changeset, :citations)))
    )
  end

  defp put_dedupe_key(changeset), do: changeset
end
