defmodule Platform.Social.NextSlot do
  @moduledoc """
  The Queue's "Approve into next slot" time (Social authoring 5/11, task
  01a16c50), behind one function so the Queue never knows where slots come
  from.

  Posting slots are Social authoring 4/11's (`Platform.Social.Slots`, task
  01a16c4f-9041). While that module is not compiled in, `next_free/2` falls
  back to the next free top of the hour: at least 15 minutes
  from now, and not already taken by another approved or scheduled post on
  the same account. When `Platform.Social.Slots.next_free/2` exists it is
  called instead and its answer is final (nil hides the button).

  Pure apart from one read of the account's taken times.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social.{Post, Profile}

  @slots Platform.Social.Slots
  @lead_s 15 * 60
  @horizon_hours 24 * 14

  @doc """
  The next free slot for `post` on `profile` after `now`, or nil.
  Always in the future, always UTC, on a whole second (microsecond
  precision, for `scheduled_at`).
  """
  @spec next_free(Profile.t(), Post.t(), DateTime.t()) :: DateTime.t() | nil
  def next_free(%Profile{} = profile, %Post{} = post, now \\ DateTime.utc_now()) do
    if slots_available?() do
      @slots |> apply(:next_free, [profile, post]) |> normalize(now)
    else
      fallback(post, now)
    end
  end

  @doc "Whether 4/11's slot model is compiled in (else the top-of-hour fallback)."
  @spec slots_available?() :: boolean()
  def slots_available?,
    do: Code.ensure_loaded?(@slots) and function_exported?(@slots, :next_free, 2)

  defp normalize({:ok, at}, now), do: normalize(at, now)

  defp normalize(%DateTime{} = at, now) do
    at = at |> DateTime.shift_zone!("Etc/UTC") |> whole_second()
    if DateTime.compare(at, now) == :gt, do: at
  end

  defp normalize(_none, _now), do: nil

  # The first top of the hour at least @lead_s away that no other approved
  # or scheduled post on the account already holds.
  defp fallback(%Post{} = post, now) do
    taken = taken(post)
    first = top_of_next_hour(DateTime.add(now, @lead_s, :second))

    Enum.find_value(0..@horizon_hours, fn h ->
      at = DateTime.add(first, h * 3600, :second)
      if not MapSet.member?(taken, DateTime.to_unix(at)), do: whole_second(at)
    end)
  end

  defp whole_second(%DateTime{} = at), do: %{DateTime.truncate(at, :second) | microsecond: {0, 6}}

  defp taken(%Post{account_id: account_id, id: id}) do
    from(p in Post,
      where:
        p.account_id == ^account_id and p.id != ^id and p.status in ["approved", "scheduled"] and
          not is_nil(p.scheduled_at),
      select: p.scheduled_at
    )
    |> Repo.all()
    |> MapSet.new(fn at -> at |> DateTime.truncate(:second) |> DateTime.to_unix() end)
  end

  defp top_of_next_hour(%DateTime{} = at) do
    at = DateTime.truncate(at, :second)
    floor = %{at | minute: 0, second: 0}
    if DateTime.compare(floor, at) == :lt, do: DateTime.add(floor, 3600, :second), else: floor
  end
end
