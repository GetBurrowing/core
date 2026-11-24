defmodule Platform.Social.QualityReview do
  @moduledoc """
  The optional legacy quality stage, separate from final publishing authority.
  A pass records the content fields reviewed, not immutable dispatch bytes.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    Account,
    ApprovalCard,
    Approvals,
    Post,
    PostEvents,
    Profile,
    PublishingCompleteness
  }

  @kind "social_quality_review"
  @pass_fields [:quality_passed_by_user_id, :quality_passed_at, :quality_pass_fingerprint]

  def enabled?(%Profile{quality_reviewer_user_ids: ids}), do: is_list(ids) and ids != []

  def valid_pass?(
        %Post{
          quality_passed_by_user_id: who,
          quality_passed_at: %DateTime{},
          quality_pass_fingerprint: mark
        } = post
      )
      when is_binary(who) and is_binary(mark), do: mark == Approvals.content_fingerprint(post)

  def valid_pass?(%Post{}), do: false

  def check_approval(%Profile{} = profile, %Post{} = post) do
    if enabled?(profile) and (post.status == "quality_review" or not valid_pass?(post)),
      do: {:error, :quality_review_required},
      else: :ok
  end

  @doc "Applied after effective title/link edits, before any legacy submission write."
  def route_submission(%Changeset{} = changeset, %Profile{} = profile) do
    post = Changeset.apply_changes(changeset)

    cond do
      post.flow != "legacy" ->
        changeset

      not enabled?(profile) ->
        if Changeset.get_change(changeset, :status) == "quality_review",
          do:
            Changeset.add_error(changeset, :status, "quality review is not enabled",
              reason: :status_not_allowed
            ),
          else: changeset

      post.status == "needs_approval" and not valid_pass?(post) ->
        changeset |> Changeset.put_change(:status, "quality_review") |> clear_pass()

      post.status == "quality_review" ->
        clear_pass(changeset)

      post.status == "draft" and content_changed?(changeset) ->
        clear_pass(changeset)

      true ->
        changeset
    end
  end

  defp content_changed?(changeset),
    do:
      Approvals.content_fingerprint(changeset.data) !=
        Approvals.content_fingerprint(Changeset.apply_changes(changeset))

  def clear_pass(changeset),
    do: Enum.reduce(@pass_fields, changeset, &Changeset.put_change(&2, &1, nil))

  def pass(org_id, post_id, user_id, opts \\ []) do
    observed = Social.get_post(org_id, post_id)

    expected =
      Keyword.get_lazy(opts, :expected_fingerprint, fn ->
        observed && Approvals.content_fingerprint(observed)
      end)

    transition(org_id, post_id, fn post, account, profile ->
      with :ok <- Social.quality_reviewer_check(org_id, profile, user_id),
           :ok <- quality_status(post),
           true <- expected == Approvals.content_fingerprint(post) || {:error, :post_changed},
           :ok <- Social.require_channel("needs_approval", profile, account),
           :ok <- complete(post, account),
           {:ok, passed} <-
             post
             |> Changeset.change(
               status: "needs_approval",
               quality_passed_by_user_id: user_id,
               quality_passed_at: DateTime.utc_now(),
               quality_pass_fingerprint: Approvals.content_fingerprint(post)
             )
             |> Repo.update() do
        PostEvents.record!(passed, "submitted", {:human, user_id}, note: "Passed quality review")
        passed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> after_transition()
  end

  # Preserve the existing by-hand request's completeness exception.
  defp complete(_post, %Account{approval_mode: "draft_only"}), do: :ok
  defp complete(post, account), do: PublishingCompleteness.check(post, account)

  def edit(org_id, post_id, user_id, attrs) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &(not is_atom(&1))) do
      {:error, {:invalid_keys, Enum.reject(Map.keys(attrs), &is_atom/1)}}
    else
      transition(org_id, post_id, fn post, account, profile ->
        with :ok <- Social.quality_reviewer_check(org_id, profile, user_id),
             :ok <- quality_status(post) do
          changeset =
            post
            |> Post.draft_edit_changeset(Map.take(attrs, [:body, :scheduled_at]), false)
            |> PublishingCompleteness.put_title(attrs, account)
            |> clear_pass()

          changeset =
            if Map.has_key?(attrs, :title) and account.platform != "youtube",
              do: Changeset.add_error(changeset, :title, "is only used for YouTube"),
              else: changeset

          with true <- changeset.valid? || {:error, changeset},
               :ok <- Social.refuse_scheduling_on_archived(org_id, post, changeset),
               {:ok, updated} <- Repo.update(changeset) do
            PostEvents.record!(updated, "edited", {:human, user_id},
              body_before: post.body,
              body_after: updated.body
            )

            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> after_transition()
    end
  end

  def send_back(org_id, post_id, user_id, note) do
    with {:ok, note} <- note(note) do
      transition(org_id, post_id, fn post, account, profile ->
        with :ok <- send_back_check(org_id, profile, account, user_id),
             :ok <- quality_status(post),
             {:ok, updated} <-
               post
               |> Changeset.change(status: "draft", rejection_reason: note, rejected_at: nil)
               |> clear_pass()
               |> Repo.update() do
          # A request to revise is not a terminal publishing rejection.
          PostEvents.record!(updated, "revision_requested", {:human, user_id}, note: note)
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, post} ->
          dismiss_quality(post)
          notify_author(post, note)
          {:ok, post}

        error ->
          error
      end
    end
  end

  # Sending preparation back to draft is recovery, not a quality pass or
  # content-edit grant. The account's current final approver can recover it
  # even after the profile's last quality reviewer has been removed.
  defp send_back_check(org_id, profile, account, user_id) do
    case Social.quality_reviewer_check(org_id, profile, user_id) do
      :ok -> :ok
      {:error, _} -> Social.post_approver_check(org_id, profile, account, user_id)
    end
  end

  def return_to_review(org_id, post_id, user_id) do
    transition(org_id, post_id, fn post, account, profile ->
      with :ok <- Social.post_preparer_check(org_id, profile, account, user_id),
           true <- post.status == "needs_approval" || {:error, :not_needs_approval},
           true <- enabled?(profile) || {:error, :quality_review_not_enabled},
           true <- not valid_pass?(post) || {:error, :quality_review_already_passed},
           {:ok, updated} <-
             post |> Changeset.change(status: "quality_review") |> clear_pass() |> Repo.update() do
        PostEvents.record!(updated, "submitted", {:human, user_id},
          note: "Sent to quality review"
        )

        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> after_transition()
  end

  @doc "Re-read the legacy post under profile, account and post locks, in that order."
  def lock_context(org_id, post_or_id) do
    id = if is_struct(post_or_id, Post), do: post_or_id.id, else: post_or_id

    with %Post{} = observed <- Social.get_post(org_id, id) || {:error, :not_found},
         {:ok, observed_profile} <- Social.profile_of_post(observed),
         %Profile{} = profile <-
           Social.lock_profile(org_id, observed_profile.id, :share) || {:error, :not_found},
         %Account{} = account <-
           Social.lock_account(profile, observed.account_id, :share) || {:error, :not_found},
         %Post{} = post <- Social.lock_post(org_id, observed.id) || {:error, :not_found},
         true <- post.account_id == account.id || {:error, :not_found},
         :ok <- Social.refuse_studio(post) do
      {:ok, {post, account, profile}}
    end
  end

  defp transition(org_id, post_id, fun) do
    Repo.transaction(fn ->
      case lock_context(org_id, post_id) do
        {:ok, {post, account, profile}} -> fun.(post, account, profile)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp quality_status(%Post{status: "quality_review"}), do: :ok
  defp quality_status(%Post{}), do: {:error, :not_in_quality_review}

  defp note(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, :note_required}

      value ->
        if String.length(value) <= Post.max_rejection_reason(),
          do: {:ok, value},
          else: {:error, :note_too_long}
    end
  end

  defp note(_), do: {:error, :note_required}

  defp after_transition({:ok, post}), do: {:ok, Social.needs_approval_written(post)}
  defp after_transition(other), do: other

  @doc "After commit only: retire final cards before drawing the quality stage."
  def after_write(%Post{flow: "legacy", status: "quality_review"} = post) do
    supersede_cards(post)

    with {:ok, profile} <- Social.profile_of_post(post),
         %Account{} = account <- Social.get_account(profile.org_id, post.account_id) do
      for user_id <- profile.quality_reviewer_user_ids || [],
          Social.quality_reviewer_check(profile.org_id, profile, user_id) == :ok do
        listed? =
          Platform.Inbox.unread_scope(user_id)
          |> where(
            [i],
            i.kind == @kind and i.source_type == "social_post" and i.source_id == ^post.id
          )
          |> Repo.exists?()

        unless listed? do
          Platform.Inbox.emit(%{
            user_id: user_id,
            kind: @kind,
            source_type: "social_post",
            source_id: post.id,
            title: "Quality review requested",
            body: "#{Approvals.platform_label(account.platform)} · #{profile.name}",
            url: Platform.Social.PostPresentation.url(post, profile, {:user, user_id})
          })
        end
      end
    end

    post
  end

  def after_write(%Post{} = post), do: post

  def supersede_cards(%Post{} = post) do
    Repo.update_all(
      from(c in ApprovalCard, where: c.post_id == ^post.id and c.state == "pending"),
      set: [state: "superseded", updated_at: DateTime.utc_now()]
    )

    with {:ok, profile} <- Social.profile_of_post(post),
         %Account{} = account <- Social.get_account(profile.org_id, post.account_id) do
      for user_id <-
            Enum.uniq((profile.approver_user_ids || []) ++ List.wrap(account.owner_user_id)) do
        Platform.Inbox.dismiss_by_source(user_id, "social_post", post.id,
          kind: "social_post_approval"
        )
      end
    end

    :ok
  end

  def dismiss_quality(%Post{} = post) do
    with {:ok, profile} <- Social.profile_of_post(post) do
      for id <- profile.quality_reviewer_user_ids || [],
          do: Platform.Inbox.dismiss_by_source(id, "social_post", post.id, kind: @kind)
    end

    :ok
  end

  defp notify_author(post, note) do
    notify_human_author(post)
    notify_agent_author(post, note)
  end

  defp notify_human_author(post) do
    author =
      post.id
      |> PostEvents.list_for_post()
      |> Enum.find(&(&1.action == "created" and &1.actor_kind == "human"))

    with %{actor_id: id} when is_binary(id) <- author,
         %{archived_at: nil} = user <- Platform.Accounts.get_user(id),
         {:ok, profile} <- Social.profile_of_post(post),
         true <- Enum.any?(Social.list_profiles_for_user(user), &(&1.id == profile.id)) do
      Platform.Inbox.emit(%{
        user_id: id,
        kind: "social_post_revision",
        source_type: "social_post",
        source_id: post.id,
        title: "Changes requested",
        body: "A post for #{profile.name} was sent back to draft with a review note.",
        url: Platform.Social.PostPresentation.url(post, profile, {:user, id})
      })
    end

    :ok
  end

  defp notify_agent_author(post, note) do
    with {:ok, profile} <- Social.profile_of_post(post),
         id when is_binary(id) <- PostEvents.drafting_agent_id(post),
         %{name: name} <- Repo.get(Platform.Agents.Agent, id),
         true <- is_binary(profile.space_id),
         {:ok, participant} <- Approvals.system_participant(profile.space_id) do
      Platform.Chat.post_message(%{
        space_id: profile.space_id,
        participant_id: participant.id,
        content_type: "text",
        content: "@[#{name}] Quality review sent this post back: #{note}",
        metadata: %{"social_revision" => %{"post_id" => post.id, "idea_id" => post.idea_id}}
      })
    end

    :ok
  end
end
