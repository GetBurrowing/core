defmodule Platform.Social.NextSlot do
  @moduledoc """
  The Queue's "Approve into next slot" time (Social authoring 5/11, task
  01a16c50), behind one function so the Queue never knows where slots come
  from.

  Posting slots are Social authoring 4/11's (task 01a16c4f-9041): this is
  `Platform.Social.next_free_slot/2` for the post's account, read in the
  profile's timezone. An account with no slots answers nil, which hides
  the button ("Approve into next slot is off until you add one").

  Pure apart from one read of the account's taken times.
  """

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Post, Profile}

  @doc """
  The next free slot for `post` on `profile` after `now`, or nil.
  Always in the future, always UTC, on a whole second (microsecond
  precision, for `scheduled_at`). nil when the post's account is not
  `profile`'s or has no slots.
  """
  @spec next_free(Profile.t(), Post.t(), DateTime.t()) :: DateTime.t() | nil
  def next_free(
        %Profile{id: profile_id},
        %Post{account_id: account_id},
        now \\ DateTime.utc_now()
      ) do
    case account_id && Repo.get(Account, account_id) do
      %Account{profile_id: ^profile_id} = account ->
        account |> Social.next_free_slot(DateTime.add(now, 1, :second)) |> normalize(now)

      _ ->
        nil
    end
  end

  defp normalize(%DateTime{} = at, now) do
    at = at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
    if DateTime.compare(at, now) == :gt, do: %{at | microsecond: {0, 6}}
  end

  defp normalize(_none, _now), do: nil
end
