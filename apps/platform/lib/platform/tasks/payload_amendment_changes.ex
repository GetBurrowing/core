defmodule Platform.Tasks.PayloadAmendmentChanges do
  @moduledoc """
  What each entry of an e2e_behavior validation's `payload_amendments`
  changed (task 01a0e266 stage 3). Pure: no Repo, no process state.

  Shared by the two readers that describe an amendment, so they cannot
  disagree about which fields moved:

    * `Platform.Tasks.PayloadAmendmentNotice.compose_message/4`, the
      execution-space notice (stage 2), which lists `changed_fields/2` of
      the entry just appended against the new payload;
    * the task page's amended-case marker in
      `PlatformWeb.Tasks.TaskDetailComponent` (stage 3), which renders
      `history/1` and `amended_fields/1`.

  An entry's `prior_payload` is the text it REPLACED. The text that replaced
  it is the next entry's `prior_payload`, or the validation's current
  `evaluation_payload` for the last entry. That is exactly the pair the
  notice compares at the moment it is posted, so entry i's fields here equal
  the fields notice i named.
  """

  @payload_fields [{"setup", :setup}, {"actions", :actions}, {"expected", :expected}]
  @system_amender "system (no agent)"

  @typedoc "One history row: the 1-based amendment number, the raw entry, and its changed fields."
  @type change :: %{number: pos_integer(), entry: map(), changed: [String.t()]}

  @doc """
  Which of `setup`, `actions`, `expected` differ between two payloads, in
  that order. Missing keys compare as nil; atom and string keys are both
  read.
  """
  @spec changed_fields(map() | nil, map() | nil) :: [String.t()]
  def changed_fields(prior, current) do
    for {key, atom} <- @payload_fields,
        field(prior, key, atom) != field(current, key, atom),
        do: key
  end

  @doc """
  Every amendment of `validation`, oldest first, each with the fields it
  changed. `[]` for a validation that was never amended.
  """
  @spec history(%{payload_amendments: [map()] | nil, evaluation_payload: map() | nil}) ::
          [change()]
  def history(%{payload_amendments: entries, evaluation_payload: current})
      when is_list(entries) and entries != [] do
    replacements = Enum.map(tl(entries), & &1["prior_payload"]) ++ [current]

    entries
    |> Enum.zip(replacements)
    |> Enum.with_index(1)
    |> Enum.map(fn {{entry, replaced_by}, n} ->
      %{number: n, entry: entry, changed: changed_fields(entry["prior_payload"], replaced_by)}
    end)
  end

  def history(_validation), do: []

  @doc """
  The union over ALL amendments of the fields each changed, in
  setup/actions/expected order.
  """
  @spec amended_fields(map()) :: [String.t()]
  def amended_fields(validation) do
    changed = validation |> history() |> Enum.flat_map(& &1.changed) |> MapSet.new()
    for {key, _atom} <- @payload_fields, MapSet.member?(changed, key), do: key
  end

  @doc """
  The amender label a reader sees for one entry: `system (no agent)` for an
  actor_type `system` entry (the operator path), else its `amended_by`.
  """
  @spec amended_by_label(map()) :: String.t()
  def amended_by_label(%{"actor_type" => "system"}), do: @system_amender
  def amended_by_label(%{"amended_by" => by}) when is_binary(by) and by != "", do: by
  def amended_by_label(_entry), do: @system_amender

  @doc "The label rendered for the operator path."
  @spec system_amender() :: String.t()
  def system_amender, do: @system_amender

  defp field(%{} = payload, key, atom), do: Map.get(payload, key, Map.get(payload, atom))
  defp field(_payload, _key, _atom), do: nil
end
