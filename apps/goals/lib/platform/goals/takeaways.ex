defmodule Platform.Goals.Takeaways do
  @moduledoc """
  Takeaway rules beyond the `Platform.Goals.Entry` changeset (task
  01a1dfc1-7625, Goals 5/8 stage 2), called from `Platform.Goals.add_entry/3`
  and `close_wake_up/4`.

    * `check_cap/3`: a goal holds at most `Limits.max_takeaways/0`
      takeaways; one more is `{:error, :takeaway_cap_reached}`.
    * `cite/3`: a do or ask outcome may name the takeaway it came from;
      `add_entry/3`'s same-goal check does the refusing.

  The count reads through `Platform.Goals.Visibility.visible_goals/1`.
  """

  import Ecto.Query

  alias Platform.Goals.{Entry, Limits, Visibility}
  alias Platform.Repo

  @doc "`:ok`, or `{:error, :takeaway_cap_reached}` for a takeaway past the cap."
  def check_cap(actor, goal, attrs) do
    if kind(attrs) == "takeaway" and count(actor, goal) >= Limits.max_takeaways(),
      do: {:error, :takeaway_cap_reached},
      else: :ok
  end

  @doc "Adds `takeaway_id` to a do or ask outcome's entry attrs when one is given."
  def cite(entry_attrs, outcome, takeaway_id)
      when outcome in ~w(do ask) and not is_nil(takeaway_id),
      do: Map.put(entry_attrs, :takeaway_id, takeaway_id)

  def cite(entry_attrs, _outcome, _takeaway_id), do: entry_attrs

  defp kind(attrs) when is_map(attrs), do: Map.get(attrs, :kind, Map.get(attrs, "kind"))
  defp kind(_attrs), do: nil

  defp count(actor, goal) do
    Repo.aggregate(
      from(e in Entry,
        join: g in subquery(Visibility.visible_goals(actor)),
        on: g.id == e.goal_id,
        where: e.goal_id == ^goal.id and e.kind == "takeaway"
      ),
      :count
    )
  end
end
