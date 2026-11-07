defmodule Platform.Secretary.Overrides do
  @moduledoc """
  The person's standing feedback, applied deterministically to every
  evaluation after the model or the fallback has spoken (task 01a1b721
  stage 3 item 4):

    * `hide_kind` -> the row is `quiet`: no brief line, never needs-you-now;
    * `this_matters` -> at least `waiting`, and ranked above every FYI of the
      same answer.

  Rows are evaluation attr maps (string keys) carrying a `"kind_key"`
  (`Platform.Secretary.Feedback.kind_key/2`); the key is dropped on return.
  """

  alias Platform.Secretary.Store

  @lifted ~w(fyi quiet not_in_space suggested)

  @doc "Applies `user_id`'s overrides to `rows`."
  @spec apply(Ecto.UUID.t(), [map()]) :: [map()]
  def apply(user_id, rows) when is_list(rows) do
    overrides = Store.kind_overrides(user_id, Enum.map(rows, & &1["kind_key"]))

    fyi_floor =
      rows
      |> Enum.filter(&(&1["tag"] == "fyi" and is_integer(&1["rank"])))
      |> Enum.map(& &1["rank"])
      |> Enum.min(fn -> nil end)

    Enum.map(rows, fn row ->
      row
      |> override(Map.get(overrides, row["kind_key"]), fyi_floor)
      |> Map.delete("kind_key")
    end)
  end

  defp override(row, "hide_kind", _floor) do
    Map.merge(row, %{
      "tag" => "quiet",
      "needs_you_now" => false,
      "brief_rank" => nil,
      "brief_line" => nil,
      "brief_action_label" => nil,
      "brief_tag" => nil
    })
  end

  defp override(%{"tag" => tag} = row, "this_matters", floor) when tag in @lifted do
    rank =
      case {row["rank"], floor} do
        {r, f} when is_integer(r) and is_integer(f) -> min(r, f - 1)
        {r, _} -> r
      end

    Map.merge(row, %{"tag" => "waiting", "rank" => rank})
  end

  defp override(row, _none, _floor), do: row
end
