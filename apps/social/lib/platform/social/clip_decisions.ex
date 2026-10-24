defmodule Platform.Social.ClipDecisions do
  @moduledoc """
  A human's one-step decision on a rendered clip (Clip Studio 2/9, task
  01a16662): approve publishes it to the chosen accounts, reject sends a note
  back to the agent, and undo takes either back inside the window.

  ## One approval publishes

  `approve_clip/5` IS the approval. In one transaction it marks the clip
  approved (`Platform.Social.Clip.review_changeset/3`), applies the human's
  title/caption edits (`Clip.human_edit_changeset/2`), writes one post per
  selected account (per-platform status is never rolled up), and approves
  each with `Platform.Social.approve_post/4` as the SAME human. The posts
  share the clip's ONE idea (Social authoring 2/11:
  `Platform.Social.Ideas.find_or_create_for_clip!/3`), and each gets a
  `created` and an `approved` change log entry naming that human. There is no
  approval card and no `needs_approval` step. Each post's `publish_after` is
  the decision time plus `Platform.Social.ClipPublish.window_ms/0`, and
  `ClipPublish` publishes it once the window closes. The window is
  server-side; there is no client timer.

  ## Humans only

  Every entry takes a user id and checks it with
  `Platform.Social.approver_check/3` on the clip's profile before anything
  else: an agent id is `:not_a_human`, a user off the approver list
  `:not_an_approver`. `approve_post/4` then applies the per-account rule
  (an owned account needs its owner, `:not_the_owner`), and any refusal
  rolls the whole decision back. No agent tool reaches this module.

  ## Clock

  Each function takes `opts` with an injectable `:now` (default the real
  clock), so the window is testable without sleeping.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    Account,
    Clip,
    ClipMedia,
    ClipPublish,
    Ideas,
    Links,
    Post,
    PostEvents,
    Profile,
    Publishing
  }

  @max_note 2_000

  @type refusal ::
          :not_found
          | :not_pending
          | :not_decided
          | :no_platforms
          | :account_not_in_profile
          | :account_draft_only
          | :note_required
          | :note_too_long
          | :not_reviewer
          | :window_closed
          | :not_a_clip_post
          | :not_failed
          | Social.approver_refusal()

  # ── Approve ──────────────────────────────────────────────────────────

  @doc """
  Approves a rendered, pending clip as `user_id` and queues it to publish
  on `attrs["account_ids"]` after the undo window. `attrs` may carry the
  human's `"title"` and `"caption"` edits.

  Refusals, in order, each writing nothing: `:not_found` (missing or another
  org's clip), `:not_pending` (not rendered, or not review pending), the
  `approver_check/3` refusal, `:no_platforms` (no account ids),
  `:account_not_in_profile` (an id that is not a live account of the
  clip's profile, another org's included), `:account_draft_only`. A
  refusal from `approve_post/4` (e.g. `:not_the_owner`) or a changeset
  error rolls everything back.

  Returns `{:ok, %{clip: clip, posts: posts}}`.
  """
  @spec approve_clip(Ecto.UUID.t(), term(), term(), map(), keyword()) ::
          {:ok, %{clip: Clip.t(), posts: [Post.t()]}} | {:error, refusal() | Changeset.t()}
  def approve_clip(org_id, clip_id, user_id, attrs, opts \\ []) do
    now = now(opts)
    attrs = if is_map(attrs), do: attrs, else: %{}

    with {:ok, clip} <- fetch_clip(org_id, clip_id),
         :ok <- pending(clip),
         {:ok, profile} <- profile(org_id, clip),
         :ok <- Social.approver_check(org_id, profile, user_id),
         {:ok, accounts} <- accounts(profile, attrs["account_ids"]) do
      publish_after = DateTime.add(now, ClipPublish.window_ms(), :millisecond)

      Repo.transaction(fn ->
        with {:ok, clip} <- lock_clip(clip),
             :ok <- pending(clip),
             {:ok, clip} <- review(clip, user_id, attrs, now),
             {:ok, posts} <- write_posts(org_id, profile, clip, accounts, user_id, publish_after) do
          %{clip: clip, posts: posts}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, %{clip: clip, posts: posts} = result} ->
          ClipPublish.schedule(Enum.map(posts, & &1.id), publish_after, publish_server(opts))
          Social.broadcast_clip(clip)
          {:ok, result}

        error ->
          error
      end
    end
  end

  defp review(clip, user_id, attrs, now) do
    clip
    |> Clip.human_edit_changeset(Map.take(attrs, ["title", "caption"]))
    |> Clip.review_changeset({:approve, user_id}, now)
    |> Repo.update()
  end

  defp write_posts(org_id, profile, clip, accounts, user_id, publish_after) do
    idea = Ideas.find_or_create_for_clip!(clip, profile, user_id)

    Enum.reduce_while(accounts, {:ok, []}, fn account, {:ok, acc} ->
      with {:ok, post} <- insert_post(profile, clip, idea, account, publish_after),
           _created = PostEvents.record!(post, "created", {:human, user_id}),
           {:ok, post} <- Social.approve_post(org_id, post, user_id, lock: true) do
        PostEvents.record!(post, "approved", {:human, user_id})
        {:cont, {:ok, [post | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, posts} -> {:ok, Enum.reverse(posts)}
      error -> error
    end
  end

  # A draft that is approved in the same transaction: never `needs_approval`,
  # so no approval card is written. `clip_id`, `idea_id` and `publish_after`
  # are set on the struct, never cast.
  defp insert_post(profile, clip, idea, account, publish_after) do
    link = Links.effective_link(nil, profile.home_url, clip.source_url, clip.start_s)

    %Post{
      account_id: account.id,
      clip_id: clip.id,
      idea_id: idea.id,
      publish_after: publish_after
    }
    |> Post.changeset(%{
      status: "draft",
      body: Links.append_to_body(clip.caption, link),
      link_url: link,
      media_file_ids: List.wrap(clip.render_file_id),
      generated_by_agent_id: clip.submitted_by_agent_id
    })
    |> ClipMedia.put_media_meta(profile.id)
    |> Repo.insert()
  end

  # ── Reject ───────────────────────────────────────────────────────────

  @doc """
  Rejects a rendered, pending clip as `user_id` with `note` (trimmed,
  required: `:note_required`; at most #{@max_note} characters:
  `:note_too_long`). Writes no posts. The note reaches the agent through
  `social_clip_list`'s `review_note`.
  """
  @spec reject_clip(Ecto.UUID.t(), term(), term(), term(), keyword()) ::
          {:ok, Clip.t()} | {:error, refusal() | Changeset.t()}
  def reject_clip(org_id, clip_id, user_id, note, opts \\ []) do
    now = now(opts)

    with {:ok, clip} <- fetch_clip(org_id, clip_id),
         :ok <- pending(clip),
         {:ok, profile} <- profile(org_id, clip),
         :ok <- Social.approver_check(org_id, profile, user_id),
         {:ok, note} <- note(note) do
      Repo.transaction(fn ->
        with {:ok, clip} <- lock_clip(clip),
             :ok <- pending(clip),
             {:ok, clip} <-
               clip |> Clip.review_changeset({:reject, user_id, note}, now) |> Repo.update() do
          clip
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast()
    end
  end

  defp note(note) when is_binary(note) do
    case String.trim(note) do
      "" ->
        {:error, :note_required}

      trimmed ->
        if String.length(trimmed) > @max_note, do: {:error, :note_too_long}, else: {:ok, trimmed}
    end
  end

  defp note(_), do: {:error, :note_required}

  # ── Undo ─────────────────────────────────────────────────────────────

  @doc """
  Takes back `user_id`'s own decision inside the window and returns the
  clip to review pending. Only the clip's reviewer may undo
  (`:not_reviewer`), and only a decided clip (`:not_decided`).

    * approved: the clip's posts are locked `FOR UPDATE`; every one must
      still be `approved` with `publish_after` after `now`, else
      `:window_closed` and nothing changes. They are deleted.
    * rejected: only before `reviewed_at` + the window, else
      `:window_closed`.

  An undo racing `ClipPublish`'s claim publishes at most once: the claim
  nils `publish_after` under the same row, so whichever commits first wins.
  """
  @spec undo_clip_decision(Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, Clip.t()} | {:error, refusal() | Changeset.t()}
  def undo_clip_decision(org_id, clip_id, user_id, opts \\ []) do
    now = now(opts)

    with {:ok, clip} <- fetch_clip(org_id, clip_id),
         {:ok, profile} <- profile(org_id, clip),
         :ok <- Social.approver_check(org_id, profile, user_id) do
      Repo.transaction(fn ->
        with {:ok, clip} <- lock_clip(clip),
             :ok <- reviewer(clip, user_id),
             :ok <- take_back(clip, now),
             {:ok, clip} <- clip |> Clip.review_changeset(:reset_pending) |> Repo.update() do
          clip
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast()
    end
  end

  defp reviewer(%Clip{review_status: status}, _user_id) when status not in ~w(approved rejected),
    do: {:error, :not_decided}

  defp reviewer(%Clip{reviewed_by_user_id: user_id}, user_id), do: :ok
  defp reviewer(%Clip{}, _user_id), do: {:error, :not_reviewer}

  defp take_back(%Clip{review_status: "approved", id: clip_id}, now) do
    posts =
      Repo.all(from(p in Post, where: p.clip_id == ^clip_id, order_by: p.id, lock: "FOR UPDATE"))

    if posts != [] and Enum.all?(posts, &undoable?(&1, now)) do
      Enum.each(posts, &Repo.delete!/1)
      :ok
    else
      {:error, :window_closed}
    end
  end

  defp take_back(%Clip{review_status: "rejected", reviewed_at: reviewed_at}, now) do
    closes = DateTime.add(reviewed_at, ClipPublish.window_ms(), :millisecond)
    if DateTime.compare(now, closes) == :lt, do: :ok, else: {:error, :window_closed}
  end

  defp undoable?(%Post{status: "approved", publish_after: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) == :gt

  defp undoable?(%Post{}, _now), do: false

  # ── Retry one post (stage 3) ─────────────────────────────────────────

  @doc """
  A human's retry of ONE clip post. The clip's other posts are never
  touched, and there is no agent path.

  Refused, writing nothing: `:not_found` (missing or another org's post),
  `:not_a_clip_post` (no `clip_id`), the `post_approver_check/4` refusal on
  the post's account (an agent id is `:not_a_human`), and `:not_failed`
  for anything not retryable (published, scheduled, queued, or a failed row
  that was "cancelled before publishing").

    * approved with a `refused_reason` (refused before the vendor): exactly
      `Platform.Social.Publishing.retry_publish/3`, unchanged, which
      re-checks the approver, honours `{:wait_until, at}` for a rate-limited
      post, and re-runs `publish_post/2`;
    * `failed` (the vendor refused it, which `retry_publish/3` answers
      `:not_refused`): the row is locked and re-approved by THIS human with
      `Post.approval_changeset/2` (so the record names who retried), its
      error cleared, then `publish_post/2` runs the full guard.

  Each vendor call counts in `publish_attempts`.
  """
  @spec retry_post(Ecto.UUID.t(), term(), term()) ::
          {:ok, Post.t()} | {:error, refusal() | term()}
  def retry_post(org_id, post_id, user_id) do
    with {:ok, post} <- fetch_post(org_id, post_id),
         :ok <- clip_post(post),
         {:ok, account, profile} <- account_and_profile(org_id, post),
         :ok <- Social.post_approver_check(org_id, profile, account, user_id) do
      case post do
        %Post{status: "approved", refused_reason: reason} when is_binary(reason) ->
          Publishing.retry_publish(org_id, post.id, user_id)

        %Post{status: "failed"} ->
          retry_failed(org_id, post.id, user_id)

        %Post{} ->
          {:error, :not_failed}
      end
    end
  end

  @cancelled "cancelled before publishing"

  defp retry_failed(org_id, post_id, user_id) do
    Repo.transaction(fn ->
      case Social.lock_post(org_id, post_id) do
        %Post{status: "failed", error: error} = post when error != @cancelled ->
          post
          |> Post.approval_changeset(user_id)
          |> Changeset.change(error: nil)
          |> Repo.update()
          |> case do
            {:ok, approved} ->
              PostEvents.record!(approved, "approved", {:human, user_id}, note: "retry")
              approved

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        _ ->
          Repo.rollback(:not_failed)
      end
    end)
    |> case do
      {:ok, %Post{id: id}} -> Publishing.publish_post(org_id, id)
      error -> error
    end
  end

  defp fetch_post(org_id, post_id) do
    with {:ok, id} <- Ecto.UUID.cast(post_id),
         %Post{} = post <- Social.get_post(org_id, id) do
      {:ok, post}
    else
      _ -> {:error, :not_found}
    end
  end

  defp clip_post(%Post{clip_id: nil}), do: {:error, :not_a_clip_post}
  defp clip_post(%Post{}), do: :ok

  defp account_and_profile(org_id, %Post{account_id: account_id}) do
    with %Account{} = account <- Social.get_account(org_id, account_id),
         %Profile{} = profile <- Social.get_profile(org_id, account.profile_id) do
      {:ok, account, profile}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Shared ───────────────────────────────────────────────────────────

  defp fetch_clip(org_id, clip_id) do
    with {:ok, id} <- Ecto.UUID.cast(clip_id),
         %Clip{} = clip <- Social.get_clip(org_id, id) do
      {:ok, clip}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_clip(%Clip{id: id}) do
    case Repo.one(from(c in Clip, where: c.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      clip -> {:ok, clip}
    end
  end

  defp pending(%Clip{status: "rendered", review_status: "pending"}), do: :ok
  defp pending(%Clip{}), do: {:error, :not_pending}

  defp profile(org_id, %Clip{profile_id: profile_id}) do
    case Social.get_profile(org_id, profile_id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :not_found}
    end
  end

  # Every id must be a live account of the clip's profile; another org's
  # account is not in the profile, so it is refused the same way.
  defp accounts(_profile, ids) when ids in [nil, []], do: {:error, :no_platforms}

  defp accounts(%Profile{id: profile_id}, ids) when is_list(ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case account(profile_id, id) do
        {:ok, account} -> {:cont, {:ok, [account | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, accounts} -> {:ok, Enum.reverse(accounts)}
      error -> error
    end
  end

  defp accounts(_profile, _ids), do: {:error, :no_platforms}

  defp account(profile_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Account{profile_id: ^profile_id, archived_at: nil} = account <- Repo.get(Account, id) do
      if account.approval_mode == "draft_only",
        do: {:error, :account_draft_only},
        else: {:ok, account}
    else
      _ -> {:error, :account_not_in_profile}
    end
  end

  defp broadcast({:ok, %Clip{} = clip} = result) do
    Social.broadcast_clip(clip)
    result
  end

  defp broadcast(error), do: error

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp publish_server(opts), do: Keyword.get(opts, :publish_server, ClipPublish)
end
