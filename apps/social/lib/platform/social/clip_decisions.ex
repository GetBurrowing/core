defmodule Platform.Social.ClipDecisions do
  @moduledoc """
  A human's decision on a rendered clip (Clip Studio 2/9, task 01a16662, as
  changed by the B3 clip integration): choosing a clip for posting makes
  DRAFT posts that take the normal review path, reject sends a note back to
  the agent, and undo takes a reject (or a pre-B3 approval still inside its
  window) back.

  ## Choosing a clip makes drafts, never an approval

  `draft_clip/5` marks the clip chosen (`Platform.Social.Clip.review_changeset/3`
  with `{:approve, user_id}`: that column records the human's CLIP decision,
  it is not a post approval and nothing reads it as one), applies the human's
  title/caption edits (`Clip.human_edit_changeset/2`) and writes one legacy
  `draft` post per selected account (per-platform status is never rolled up),
  in one transaction. The posts share the clip's ONE idea (Social authoring
  2/11: `Platform.Social.Ideas.find_or_create_for_clip!/3`) and each gets a
  `created` change-log entry. A draft is never `needs_approval` or
  `approved`: there is no card, no notification, no approver on the post and
  no `publish_after`. Its body is the caption as the person edited it; the
  link is `link_url` on its own and is not appended to the body. `scheduled_at`
  is set only when the person gave a time. A YouTube account's title goes
  into `platform_options["title"]` through
  `Platform.Social.set_platform_options/4`, the human path that validates it.

  The draft then goes through the same entries as every legacy draft: sending
  it for review is `Platform.Social.update_post/3` (or the agent's
  `Platform.Social.AgentDrafts.update_agent_draft/4`) setting `needs_approval`,
  which writes the approval card, and only `Platform.Social.approve_post/4`
  (the card's approve) approves. Any completeness rule applies inside those
  shared entries, not here.

  `publish_after` is the pre-B3 undo window of a one-click approval. Nothing
  here writes it. `Platform.Social.ClipPublish` and the undo below remain only
  for rows written by earlier releases.

  ## Humans only

  Every entry takes a user id and checks it with
  `Platform.Social.approver_check/3` on the clip's profile before anything
  else: an agent id is `:not_a_human`, a user off the approver list
  `:not_an_approver`. `draft_clip/5` also applies the per-account rule to
  each account (an owned account needs its owner, `:not_the_owner`), and any
  refusal rolls the whole decision back. No agent tool reaches this module.

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
    ClipPublish,
    ClipVersions,
    Ideas,
    Links,
    PlatformOptions,
    Post,
    PostEvents,
    PublishingCompleteness,
    Profile,
    Publishing
  }

  @max_note 2_000

  @type refusal ::
          :not_found
          | :render_not_found
          | :not_pending
          | :not_decided
          | :no_platforms
          | :account_not_in_profile
          | :account_draft_only
          | :note_required
          | :note_too_long
          | :not_reviewer
          | :window_closed
          | :invalid_schedule
          | :schedule_in_past
          | :not_a_clip_post
          | :not_failed
          | Social.approver_refusal()

  # ── Draft ────────────────────────────────────────────────────────────

  @doc """
  Chooses a rendered, pending clip as `user_id` and writes a legacy `draft`
  post on each of `attrs["account_ids"]`. `attrs` may carry the human's
  `"title"` and `"caption"` edits and an explicit `"scheduled_at"` (a
  `DateTime` or ISO 8601 string in the future; absent means no time).
  `attrs["render_id"]` is required and binds every post to that playable
  version; it never defaults to latest.

  Refusals, in order, each writing nothing: `:not_found` (missing or another
  org's clip), `:not_pending` (not rendered, or not review pending), the
  `approver_check/3` refusal, `:invalid_schedule` / `:schedule_in_past`,
  `:no_platforms` (no account ids), `:account_not_in_profile` (an id that is
  not a live account of the clip's profile, another org's included),
  `:account_draft_only`. A `post_approver_check/4` refusal (e.g.
  `:not_the_owner`), `{:invalid_options, errors}` (a YouTube title over its
  limit) or a changeset error rolls everything back.

  Returns `{:ok, %{clip: clip, posts: posts}}`.
  """
  @spec draft_clip(Ecto.UUID.t(), term(), term(), map(), keyword()) ::
          {:ok, %{clip: Clip.t(), posts: [Post.t()]}} | {:error, refusal() | Changeset.t()}
  def draft_clip(org_id, clip_id, user_id, attrs, opts \\ []) do
    now = now(opts)
    attrs = if is_map(attrs), do: attrs, else: %{}

    with {:ok, clip} <- fetch_clip(org_id, clip_id),
         :ok <- refuse_studio_clip(clip),
         :ok <- pending(clip),
         {:ok, profile} <- profile(org_id, clip),
         :ok <- Social.approver_check(org_id, profile, user_id),
         {:ok, scheduled_at} <- schedule(attrs["scheduled_at"], now),
         {:ok, accounts} <- accounts(profile, attrs["account_ids"]) do
      Repo.transaction(fn ->
        # The checks above are cheap early refusals. The decision of record is
        # made again on the rows read under the lock (`Social.lock_account/3`
        # documents the convention): the locked profile, its approver list and
        # each account's owner, archive and approval mode as they are now.
        with %Profile{} = profile <-
               Social.lock_profile(org_id, profile.id, :share) || {:error, :not_found},
             :ok <- Social.approver_check(org_id, profile, user_id),
             {:ok, accounts} <- relock_accounts(profile, accounts),
             {:ok, clip} <- lock_clip(clip),
             :ok <- pending(clip),
             {:ok, render} <- selected_render(org_id, profile, clip, attrs["render_id"]),
             {:ok, clip} <- review(clip, render, user_id, attrs, now),
             version_clip = version_clip(clip, render, attrs),
             {:ok, posts} <-
               write_drafts(org_id, profile, version_clip, accounts, user_id, scheduled_at) do
          %{clip: clip, posts: posts}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, %{clip: clip}} = result ->
          Social.broadcast_clip(clip)
          result

        error ->
          error
      end
    end
  end

  # Re-reads each selected account under a `FOR SHARE` row lock, after the
  # profile lock, and applies the live-account rules to the committed row.
  defp relock_accounts(%Profile{} = profile, accounts) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn %Account{id: id}, {:ok, acc} ->
      case Social.lock_account(profile, id, :share) do
        %Account{archived_at: nil, approval_mode: mode} = account when mode != "draft_only" ->
          {:cont, {:ok, [account | acc]}}

        %Account{archived_at: nil} ->
          {:halt, {:error, :account_draft_only}}

        _gone_or_archived ->
          {:halt, {:error, :account_not_in_profile}}
      end
    end)
    |> case do
      {:ok, locked} -> {:ok, Enum.reverse(locked)}
      error -> error
    end
  end

  defp schedule(nil, _now), do: {:ok, nil}
  defp schedule("", _now), do: {:ok, nil}

  defp schedule(%DateTime{} = at, now),
    do: if(DateTime.compare(at, now) == :gt, do: {:ok, at}, else: {:error, :schedule_in_past})

  defp schedule(text, now) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> schedule(at, now)
      _ -> {:error, :invalid_schedule}
    end
  end

  defp schedule(_other, _now), do: {:error, :invalid_schedule}

  # Resolve again under the promotion lock: an event carries the version the
  # human actually saw, even if another render completed before the click.
  defp selected_render(org_id, profile, clip, render_id) do
    with {:ok, render} <- ClipVersions.get(org_id, profile.id, clip.id, render_id),
         file_id when is_binary(file_id) <- render.file_id,
         %Platform.Files.File{} <- Platform.Files.get_file(file_id) do
      {:ok, render}
    else
      _ -> {:error, :render_not_found}
    end
  end

  defp version_clip(clip, render, attrs) do
    %{
      clip
      | render_file_id: render.file_id,
        title: Map.get(attrs, "title", render.headline),
        caption: Map.get(attrs, "caption", render.caption),
        start_s: render.actual_start_s,
        end_s: render.actual_end_s,
        duration_s: render.duration_s,
        width: render.width,
        height: render.height,
        byte_size: render.byte_size
    }
  end

  defp review(clip, render, user_id, attrs, now) do
    clip
    |> Clip.human_edit_changeset(Map.take(attrs, ["title", "caption"]))
    |> Clip.review_changeset({:approve, user_id}, now)
    |> Changeset.put_change(:reviewed_render_id, render.id)
    |> Repo.update()
  end

  defp write_drafts(org_id, profile, clip, accounts, user_id, scheduled_at) do
    idea = Ideas.find_or_create_for_clip!(clip, profile, user_id)

    Enum.reduce_while(accounts, {:ok, []}, fn account, {:ok, acc} ->
      with :ok <- Social.post_approver_check(org_id, profile, account, user_id),
           {:ok, post} <- insert_draft(profile, clip, idea, account, scheduled_at),
           _created = PostEvents.record!(post, "created", {:human, user_id}) do
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

  # A `draft`: never `needs_approval` or `approved`, so no approval card is
  # written and no approver is recorded. `clip_id`, `clip_render_id` and
  # `idea_id` are set on the struct, never cast. The body is the caption as
  # it stands; the link is its own field. `publish_after` is not written.
  defp insert_draft(profile, clip, idea, account, scheduled_at) do
    link = Links.effective_link(nil, profile.home_url, clip.source_url, clip.start_s)

    %Post{
      account_id: account.id,
      clip_id: clip.id,
      clip_render_id: clip.reviewed_render_id,
      idea_id: idea.id
    }
    |> Post.changeset(%{
      status: "draft",
      body: clip.caption,
      link_url: link,
      scheduled_at: scheduled_at,
      media_file_ids: List.wrap(clip.render_file_id),
      generated_by_agent_id: clip.submitted_by_agent_id
    })
    |> Changeset.put_change(:media_meta, %{
      clip.render_file_id => %{
        "duration_s" => clip.duration_s,
        "width" => clip.width,
        "height" => clip.height
      }
    })
    |> put_title(account, clip)
    |> insert_valid()
  end

  defp insert_valid(%Changeset{errors: [{:title, {message, _}} | _]}),
    do: {:error, {:invalid_options, %{"title" => message}}}

  defp insert_valid(%Changeset{} = changeset), do: Repo.insert(changeset)

  # A platform that takes a video title (YouTube) gets the reviewed title
  # through `PublishingCompleteness.put_title/3`, the narrow title input that
  # validates it and leaves every other platform option alone. Other
  # platforms take no title option and are untouched.
  defp put_title(changeset, %Account{platform: platform} = account, clip) do
    title = clip.title

    if "title" in PlatformOptions.keys(platform) and is_binary(title) and
         String.trim(title) != "" do
      PublishingCompleteness.put_title(changeset, %{title: title}, account)
    else
      changeset
    end
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
         :ok <- refuse_studio_clip(clip),
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

  Pass `render_id: id` to undo exactly that approval after a later render
  clears the clip's review fields. Ownership and the deadline come from its
  posts. A newer render or approval is preserved. Without the option, undo
  targets the current review decision (including a rejection).

  An undo racing `ClipPublish`'s claim publishes at most once: the claim
  nils `publish_after` under the same row, so whichever commits first wins.
  """
  @spec undo_clip_decision(Ecto.UUID.t(), term(), term(), keyword()) ::
          {:ok, Clip.t()} | {:error, refusal() | Changeset.t()}
  def undo_clip_decision(org_id, clip_id, user_id, opts \\ []) do
    now = now(opts)

    with {:ok, clip} <- fetch_clip(org_id, clip_id),
         :ok <- refuse_studio_clip(clip),
         {:ok, profile} <- profile(org_id, clip),
         :ok <- Social.approver_check(org_id, profile, user_id) do
      Repo.transaction(fn ->
        with {:ok, clip} <- lock_clip(clip),
             {:ok, clip} <- undo_selected(clip, user_id, now, opts) do
          clip
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast()
    end
  end

  # The toast retains the approved identity even if a render has reset the
  # clip's review fields. Ownership and the window come from those posts.
  defp undo_selected(clip, user_id, now, opts) do
    case Keyword.fetch(opts, :render_id) do
      {:ok, id} ->
        with {:ok, id} <- Ecto.UUID.cast(id) do
          posts = posts_for_version(clip.id, id)

          cond do
            Enum.any?(posts, &Post.studio?/1) ->
              {:error, :studio_post}

            posts == [] ->
              {:error, :not_decided}

            Enum.any?(posts, &(&1.approved_by_user_id != user_id)) ->
              {:error, :not_reviewer}

            not Enum.all?(posts, &undoable?(&1, now)) ->
              {:error, :window_closed}

            true ->
              Enum.each(posts, &Repo.delete!/1)
              if clip.reviewed_render_id == id, do: reset_review(clip), else: {:ok, clip}
          end
        else
          _ -> {:error, :render_not_found}
        end

      :error ->
        with :ok <- reviewer(clip, user_id), :ok <- take_back(clip, now), do: reset_review(clip)
    end
  end

  # Social Studio: a Studio clip has its own review; the legacy clip draft
  # and the undo of a pre-B3 one-click approval never act
  # on it. The marker is the clip's own column, never the profile toggle, and it
  # is never written after insert, so one check before the lock is enough.
  defp refuse_studio_clip(%Clip{flow: "studio"}), do: {:error, :studio_clip}
  defp refuse_studio_clip(%Clip{}), do: :ok

  defp reset_review(clip), do: clip |> Clip.review_changeset(:reset_pending) |> Repo.update()

  defp posts_for_version(clip_id, render_id) do
    query = from(p in Post, where: p.clip_id == ^clip_id, order_by: p.id, lock: "FOR UPDATE")
    query = if render_id, do: from(p in query, where: p.clip_render_id == ^render_id), else: query
    Repo.all(query)
  end

  defp reviewer(%Clip{review_status: status}, _user_id) when status not in ~w(approved rejected),
    do: {:error, :not_decided}

  defp reviewer(%Clip{reviewed_by_user_id: user_id}, user_id), do: :ok
  defp reviewer(%Clip{}, _user_id), do: {:error, :not_reviewer}

  defp take_back(
         %Clip{review_status: "approved", id: clip_id, reviewed_render_id: render_id},
         now
       ) do
    posts = posts_for_version(clip_id, render_id)

    cond do
      Enum.any?(posts, &Post.studio?/1) ->
        {:error, :studio_post}

      posts != [] and Enum.all?(posts, &undoable?(&1, now)) ->
        Enum.each(posts, &Repo.delete!/1)
        :ok

      true ->
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
    * `failed` with an existing vendor job: after current authority and
      eligibility checks under the post lock, retain the legacy local retry
      transition and retry that exact job. No new B3 content approval or
      schedule rewrite occurs; a supplied schedule is refused.
    * `failed` without a vendor job: require an explicit future schedule
      and the shared locked completeness/reapproval checks before publishing.

  Both retry paths verify the expected job identity under the relevant post
  locks. A changed or disappeared job is refused, never switched to creation.

  Each vendor call counts in `publish_attempts`.
  """
  @spec retry_post(Ecto.UUID.t(), term(), term()) ::
          {:ok, Post.t()} | {:error, refusal() | term()}
  def retry_post(org_id, post_id, user_id, opts \\ []) do
    with {:ok, post} <- fetch_post(org_id, post_id),
         :ok <- clip_post(post),
         {:ok, account, profile} <- account_and_profile(org_id, post),
         :ok <- Social.post_approver_check(org_id, profile, account, user_id) do
      case post do
        %Post{status: "approved", refused_reason: reason} when is_binary(reason) ->
          Publishing.retry_publish(org_id, post.id, user_id, opts)

        %Post{status: "failed"} ->
          retry_failed(
            org_id,
            post.id,
            user_id,
            opts,
            Keyword.get(opts, :expected_external_id, Publishing.existing_job_id(post))
          )

        %Post{} ->
          {:error, :not_failed}
      end
    end
  end

  @cancelled "cancelled before publishing"

  # Retain external_id when reapproving: the guarded publishing path uses
  # it to retry the existing vendor post rather than replaying its creation.
  defp retry_failed(org_id, post_id, user_id, opts, expected_id) do
    Repo.transaction(fn ->
      case Social.lock_post(org_id, post_id) do
        %Post{status: "failed", error: error} = post when error != @cancelled ->
          with :ok <- Social.refuse_studio(post),
               :ok <- clip_post(post),
               {:ok, account, profile} <- account_and_profile(org_id, post),
               :ok <- Social.post_approver_check(org_id, profile, account, user_id),
               :ok <- Publishing.check_expected_job(post, expected_id),
               {:ok, approved} <- prepare_retry(org_id, post, user_id, opts, expected_id) do
            note =
              if expected_id,
                do: "Retry existing vendor job; no new content or schedule review",
                else: "retry"

            PostEvents.record!(approved, "approved", {:human, user_id}, note: note)
            approved
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _ ->
          Repo.rollback(:not_failed)
      end
    end)
    |> case do
      # Recheck identity again under the publisher's own lock; never select a
      # different job or creation if it changed after this local transition.
      {:ok, %Post{id: id}} ->
        Publishing.publish_post(org_id, id, expected_external_id: expected_id)

      error ->
        error
    end
  end

  # Explicit legacy same-job exception: retain the prior local retry state
  # transition, not a B3 approval of current content. The remote retry takes
  # only its job id, so an elapsed local schedule is neither changed nor gated.
  defp prepare_retry(_org_id, post, user_id, opts, expected_id) when is_binary(expected_id) do
    if Keyword.has_key?(opts, :scheduled_at) do
      {:error, :existing_job_schedule_not_allowed}
    else
      post |> Post.approval_changeset(user_id) |> Changeset.change(error: nil) |> Repo.update()
    end
  end

  defp prepare_retry(org_id, post, user_id, opts, nil) do
    if match?(%DateTime{}, opts[:scheduled_at]),
      do: Social.reapprove_post(org_id, post.id, user_id, opts),
      else: {:error, :publish_time_required}
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
    case Repo.one(
           from(c in Clip, where: c.id == ^id and is_nil(c.removed_at), lock: "FOR UPDATE")
         ) do
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
end
