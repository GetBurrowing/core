defmodule Platform.Habits.Actions do
  @moduledoc """
  The registry of learnable action keys (`0061-learned-defaults.md` § 2).

  Every `habit_signals` and `habit_patterns` row names one of these keys; the
  changesets refuse any other. Each entry carries the highest trust-ladder
  rung the action may reach and a reversibility rule for a target.

    * `chat.message_attention` is the one consumer today. It may reach `:act`,
      but only for a reversible target: a HUMAN principal, whose attention row
      and Inbox row an undo can delete. An agent target is not reversible,
      because routing attention wakes the agent and a wake cannot be recalled,
      so agent targets cap at `:prefill`.
    * The reserved keys are capture-only (max rung `:none`): signals are
      recorded so a later consumer starts with history, but nothing ranks,
      pre-fills or acts on them until that consumer registers a real rung.
  """

  @type rung :: :none | :rank | :prefill | :act
  @type target :: %{required(:target_type) => String.t(), optional(atom()) => term()}

  @registry %{
    "chat.message_attention" => %{max_rung: :act, reversible_target_types: ["user"]},
    "chat.mention" => %{max_rung: :none, reversible_target_types: []},
    "chat.dm_target" => %{max_rung: :none, reversible_target_types: []},
    "chat.channel_route" => %{max_rung: :none, reversible_target_types: []},
    "tasks.assign_agent" => %{max_rung: :none, reversible_target_types: []}
  }

  @rung_order [:none, :rank, :prefill, :act]

  @doc "Every registered action key, sorted."
  @spec keys() :: [String.t()]
  def keys, do: @registry |> Map.keys() |> Enum.sort()

  @doc "The keys a consumer acts on (max rung above `:none`), sorted."
  @spec consumer_keys() :: [String.t()]
  def consumer_keys,
    do: for({key, %{max_rung: rung}} <- @registry, rung != :none, do: key) |> Enum.sort()

  @doc "Is `key` a registered action?"
  @spec registered?(term()) :: boolean()
  def registered?(key) when is_binary(key), do: Map.has_key?(@registry, key)
  def registered?(_key), do: false

  @doc "The highest rung `key` may reach, or nil for an unregistered key."
  @spec max_rung(String.t()) :: rung() | nil
  def max_rung(key) do
    case Map.get(@registry, key) do
      %{max_rung: rung} -> rung
      nil -> nil
    end
  end

  @doc """
  Can an automatic action of `key` on `target` be undone? False for every
  unregistered key and every capture-only key.
  """
  @spec reversible?(String.t(), target() | map()) :: boolean()
  def reversible?(key, target) do
    with %{reversible_target_types: types} <- Map.get(@registry, key),
         type when is_binary(type) <- target_type(target) do
      type in types
    else
      _ -> false
    end
  end

  @doc """
  The highest rung `key` may reach for `target`: the registered max rung,
  capped at `:prefill` when the target is not reversible.
  """
  @spec max_rung_for(String.t(), map()) :: rung() | nil
  def max_rung_for(key, target) do
    case max_rung(key) do
      nil -> nil
      :act -> if reversible?(key, target), do: :act, else: :prefill
      rung -> rung
    end
  end

  @doc "Is rung `a` at or above rung `b`?"
  @spec rung_at_least?(rung(), rung()) :: boolean()
  def rung_at_least?(a, b),
    do: Enum.find_index(@rung_order, &(&1 == a)) >= Enum.find_index(@rung_order, &(&1 == b))

  defp target_type(%{target_type: type}), do: type
  defp target_type(%{"target_type" => type}), do: type
  defp target_type(_), do: nil
end
