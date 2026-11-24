defmodule Platform.Social.LegacyClipApproval do
  @moduledoc """
  TEST SUPPORT ONLY. Builds the rows the removed one-click `approve_clip/5`
  used to write: approved clip posts whose `publish_after` is the decision
  time plus `Platform.Social.ClipPublish.window_ms/0`, with the clip marked
  approved. Production no longer creates these (choosing a clip makes drafts,
  `Platform.Social.ClipDecisions.draft_clip/5`); releases before the B3 clip
  integration did, so `ClipPublish`, the undo of such an approval, retry and
  the library still have to handle them. Tests of those paths use this to put
  a legacy row in the database; it is not a production code path and must
  never be called from `lib/`.

  It is the real pieces in sequence, in one transaction: `draft_clip/5`
  (same authorization and refusals), then the approval columns
  (`Post.approval_changeset/2`) and the pre-B3 `publish_after`, then its
  server timer. It deliberately skips `Social.approve_post/4`: that now runs
  the publishing-completeness gate (a time, a connected account), which the
  retired one-click path never did, and these rows stand for ones written
  before it.
  """

  alias Platform.Repo
  alias Platform.Social.{ClipDecisions, ClipPublish, Post, PostEvents}

  @spec approve_clip(Ecto.UUID.t(), term(), term(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def approve_clip(org_id, clip_id, user_id, attrs, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    publish_after = DateTime.add(now, ClipPublish.window_ms(), :millisecond)
    server = Keyword.get(opts, :publish_server, ClipPublish)

    # TEST SUPPORT: the tests using this stand for rows written before the
    # token existed, so the helper reads the committed copy itself. A caller
    # that passes its own "copy_rev" (even nil) keeps it; production wrappers
    # never do this.
    attrs =
      Map.put_new_lazy(attrs, "copy_rev", fn ->
        Platform.Social.ClipReviewFeed.copy_rev(Repo.get!(Platform.Social.Clip, clip_id))
      end)

    Repo.transaction(fn ->
      with {:ok, %{clip: clip, posts: posts}} <-
             ClipDecisions.draft_clip(org_id, clip_id, user_id, attrs, opts),
           {:ok, posts} <- approve_all(org_id, posts, user_id, publish_after) do
        %{clip: clip, posts: posts}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{posts: posts}} = ok ->
        ClipPublish.schedule(Enum.map(posts, & &1.id), publish_after, server)
        ok

      error ->
        error
    end
  end

  defp approve_all(_org_id, posts, user_id, publish_after) do
    Enum.reduce_while(posts, {:ok, []}, fn post, {:ok, acc} ->
      approved =
        post
        |> Post.approval_changeset(user_id)
        |> Ecto.Changeset.change(publish_after: publish_after)
        |> Repo.update!()

      PostEvents.record!(approved, "approved", {:human, user_id})
      {:cont, {:ok, [approved | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
