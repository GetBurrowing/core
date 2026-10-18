defmodule Platform.Memory.Insights.Hunks do
  @moduledoc """
  Applies a `page_edit` insight's `<old>/<new>` hunks to page content. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 2. Shared by
  `Platform.Memory.Insights.Tier` (which judges the result) and
  `Platform.Memory.Insights.Actions` (which writes it), so the two cannot
  disagree about what an edit produces.

  ## Exact match, or nothing

  Hunks apply in order, each to the output of the one before. A hunk
  applies only when its `old` text is non-blank and occurs EXACTLY ONCE in
  the content at that point. An `old` that is missing (the page moved on
  since the insight was written) or ambiguous (it occurs twice, so which
  occurrence was meant is unknowable) makes the whole edit `:stale`, and
  no hunk is applied.
  """

  @type hunk :: %{required(String.t()) => String.t()}

  @doc """
  `{:ok, new_content}` when every hunk applies exactly, else `:stale`. A
  malformed hunk list (not a list, or a hunk without string `old` and
  `new`) is `:stale` too.
  """
  @spec apply_all(String.t() | nil, term()) :: {:ok, String.t()} | :stale
  def apply_all(content, [_ | _] = hunks) when is_binary(content) do
    Enum.reduce_while(hunks, {:ok, content}, fn hunk, {:ok, acc} ->
      case apply_one(acc, hunk) do
        {:ok, next} -> {:cont, {:ok, next}}
        :stale -> {:halt, :stale}
      end
    end)
  end

  def apply_all(_content, _hunks), do: :stale

  defp apply_one(content, %{"old" => old, "new" => new}) when is_binary(old) and is_binary(new) do
    if String.trim(old) != "" and occurrences(content, old) == 1,
      do: {:ok, String.replace(content, old, new, global: false)},
      else: :stale
  end

  defp apply_one(_content, _hunk), do: :stale

  defp occurrences(content, needle), do: length(:binary.matches(content, needle))

  @doc """
  True when any hunk deletes text: a non-blank `old` replaced by a blank
  `new`. A malformed hunk counts as delete-shaped, so a caller defaulting
  to deny stays denied.
  """
  @spec delete_shaped?(term()) :: boolean()
  def delete_shaped?([_ | _] = hunks) do
    Enum.any?(hunks, fn
      %{"old" => old, "new" => new} when is_binary(old) and is_binary(new) ->
        String.trim(old) != "" and String.trim(new) == ""

      _ ->
        true
    end)
  end

  def delete_shaped?(_hunks), do: true
end
