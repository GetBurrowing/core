defmodule Platform.Social.Ideas do
  @moduledoc """
  Ideas as a record (Social authoring 2/11, task 01a16c4e): one idea
  becomes one post per account. Backend only.

  ## Scope

  Every getter is org-scoped through `Platform.Social.visible_orgs/1`, the
  RBAC SWAP POINT, like every other getter in Social: a row outside the
  scope is `nil` / `{:error, :not_found}`, identical to a missing id.

  ## Stage is derived

  `stage/1` reads the idea's posts and is never stored, so it cannot drift
  from them. A post with no idea is its own one-post group downstream; there
  is no backfill.

  ## Revise

  `request_revision/4` is a human approver's "change this" on a
  `needs_approval` post: the post stays `needs_approval`, a
  `revision_requested` event carries the note, the card reads "Revision
  asked", and one chat message in the profile's approval space mentions
  the drafting agent so it wakes. The agent also pulls open notes through
  `social_idea_list`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Clip, Idea, Post, PostEvents, Profile}

  @max_note 2_000

  @type creator :: {:user, Ecto.UUID.t()} | {:agent, Ecto.UUID.t()}

  # ── Scoped reads ─────────────────────────────────────────────────────

  defp scoped(scope) do
    case Social.visible_orgs(scope) do
      :all -> from(i in Idea)
      [] -> where(Idea, false)
      org_ids -> where(Idea, [i], i.org_id in ^org_ids)
    end
  end

  @doc "The idea, through the scope, or nil."
  @spec get(Social.scope(), term()) :: Idea.t() | nil
  def get(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> scope |> scoped() |> where([i], i.id == ^id) |> Repo.one()
      :error -> nil
    end
  end

  @doc """
  The profile's ideas through the scope, newest first. `opts`:
  `archived: true` includes archived ideas (default false).
  """
  @spec list(Social.scope(), term(), keyword()) :: [Idea.t()]
  def list(scope, profile_id, opts \\ []) do
    case Ecto.UUID.cast(profile_id) do
      {:ok, profile_id} ->
        scope
        |> scoped()
        |> where([i], i.profile_id == ^profile_id)
        |> then(fn q ->
          if Keyword.get(opts, :archived, false),
            do: q,
            else: where(q, [i], is_nil(i.archived_at))
        end)
        |> order_by([i], desc: i.inserted_at, desc: i.id)
        |> Repo.all()

      :error ->
        []
    end
  end

  @doc "The posts of `idea` (or of each idea id), oldest first."
  @spec posts(Idea.t()) :: [Post.t()]
  def posts(%Idea{id: id}), do: posts_by_idea([id]) |> Map.get(id, [])

  @doc false
  @spec posts_by_idea([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Post.t()]}
  def posts_by_idea([]), do: %{}

  def posts_by_idea(ids) do
    from(p in Post, where: p.idea_id in ^ids, order_by: [asc: p.inserted_at, asc: p.id])
    |> Repo.all()
    |> Enum.group_by(& &1.idea_id)
  end

  # ── Create / archive ─────────────────────────────────────────────────

  @doc """
  Creates an idea under `profile_id` (read through the scope) as `creator`
  (`{:user, id}` or `{:agent, id}`). `attrs` (string or atom keys):
  `title` (required, at most 200), `brief`, `source_kind` (default `agent`
  for an agent, `human` for a user) and the optional refs `clip_id`,
  `task_id`, `meeting_id`, `message_id` and `source_url`. Every ref must
  belong to the profile's org (a clip to the profile itself), else a
  changeset error on that field; a `source_url` must be http or https.
  """
  @spec create(Social.scope(), term(), map(), creator()) ::
          {:ok, Idea.t()} | {:error, :not_found | Changeset.t()}
  def create(scope, profile_id, attrs, creator) do
    attrs = normalize(attrs)

    case Social.get_profile(scope, profile_id) do
      %Profile{} = profile ->
        attrs = Map.put_new(attrs, "source_kind", default_kind(creator))

        %Idea{org_id: profile.org_id, profile_id: profile.id}
        |> Idea.changeset(attrs, creator)
        |> validate_refs(scope, profile)
        |> Repo.insert()
        |> broadcast_written()

      nil ->
        {:error, :not_found}
    end
  end

  defp default_kind({:agent, _}), do: "agent"
  defp default_kind(_), do: "human"

  @doc "Archives an idea (its posts are untouched). Idempotent."
  @spec archive(Social.scope(), term()) :: {:ok, Idea.t()} | {:error, :not_found}
  def archive(scope, id) do
    case get(scope, id) do
      %Idea{archived_at: nil} = idea ->
        idea
        |> Changeset.change(archived_at: DateTime.utc_now())
        |> Repo.update()
        |> broadcast_written()

      %Idea{} = idea ->
        {:ok, idea}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  A human archives an idea from the Ideas tab (Social authoring 7/11): the
  user must pass `Platform.Social.approver_check/3` on the idea's profile
  (`:not_an_approver`), and an idea with a published post is refused
  (`:has_published`). Otherwise `archive/2`.
  """
  @spec archive_by_human(Social.scope(), term(), term()) ::
          {:ok, Idea.t()} | {:error, :not_found | :not_an_approver | :has_published}
  def archive_by_human(scope, id, user_id) do
    with %Idea{} = idea <- get(scope, id) || {:error, :not_found},
         :ok <- human_approver(idea, user_id) do
      if idea |> posts() |> Enum.any?(&(&1.status == "published")),
        do: {:error, :has_published},
        else: archive(scope, idea.id)
    end
  end

  @doc """
  "Ask <agent> to draft" (Social authoring 7/11): a human approver of the
  idea's profile asks the drafting agent (`drafting_agent_id/2`) to draft
  the idea. One message in the profile's approval space mentions the agent,
  posted by the Social system participant, the way `request_revision/4`
  wakes it.

  Refusals, each writing nothing: `:not_found`, `:not_an_approver`,
  `:idea_archived`, `:no_drafting_agent`, `:profile_has_no_channel`.
  """
  @spec ask_to_draft(Social.scope(), term(), term()) ::
          {:ok, %{message: map(), agent_name: String.t()}} | {:error, atom()}
  def ask_to_draft(scope, id, user_id) do
    with %Idea{} = idea <- get(scope, id) || {:error, :not_found},
         :ok <- if(idea.archived_at, do: {:error, :idea_archived}, else: :ok),
         :ok <- human_approver(idea, user_id),
         %Profile{} = profile <- Repo.get(Profile, idea.profile_id) || {:error, :not_found},
         space_id when is_binary(space_id) <-
           profile.space_id || {:error, :profile_has_no_channel},
         agent_id when is_binary(agent_id) <-
           drafting_agent_id(idea, posts(idea), profile) || {:error, :no_drafting_agent},
         %Platform.Agents.Agent{name: name} when is_binary(name) and name != "" <-
           Repo.get(Platform.Agents.Agent, agent_id) || {:error, :no_drafting_agent},
         {:ok, participant} <- Platform.Social.Approvals.system_participant(space_id),
         {:ok, message} <-
           Platform.Chat.post_message(%{
             space_id: space_id,
             participant_id: participant.id,
             content_type: "text",
             content: draft_text(name, idea, profile),
             metadata: %{"social_draft_request" => %{"idea_id" => idea.id}}
           }) do
      {:ok, %{message: message, agent_name: name}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :not_sent}
    end
  end

  defp draft_text(agent_name, idea, profile) do
    brief =
      case idea.brief do
        b when is_binary(b) and b != "" -> "\nBrief: " <> b
        _ -> ""
      end

    "@[#{agent_name}] Please draft the idea \"#{idea.title}\" for #{profile.name} " <>
      "(idea #{idea.id}).#{brief}\n" <>
      "Draft it with social_draft_create idea_id=#{idea.id}; social_idea_list shows its notes."
  end

  @doc """
  The agent that drafts `idea`: the first of its posts' drafting agents
  (`PostEvents.drafting_agent_id/1`), else the agent that created the idea,
  else the profile's `drafting_agent_id`. Nil when there is none.
  """
  @spec drafting_agent_id(Idea.t(), [Post.t()], Profile.t() | nil) :: Ecto.UUID.t() | nil
  def drafting_agent_id(%Idea{} = idea, posts, profile) do
    Enum.find_value(posts, &PostEvents.drafting_agent_id/1) || idea.created_by_agent_id ||
      (profile && profile.drafting_agent_id)
  end

  defp human_approver(%Idea{} = idea, user_id) do
    with %Profile{} = profile <- Social.get_profile(idea.org_id, idea.profile_id),
         :ok <- Social.approver_check(profile.org_id, profile, user_id) do
      :ok
    else
      _ -> {:error, :not_an_approver}
    end
  end

  # ── Live updates (Social authoring 7/11) ─────────────────────────────

  @doc """
  The PubSub topic a profile's ideas and posts change on:
  `{:social_ideas_changed, profile_id}` goes out when an idea is created or
  archived, a note is added, and on every change-log entry
  (`PostEvents.record!/4`), so the Ideas board re-derives its lanes.
  A change-log entry is broadcast from inside its transaction, so a
  subscriber re-reads after a short delay.
  """
  @spec posts_topic(Ecto.UUID.t()) :: String.t()
  def posts_topic(profile_id), do: "social:posts:#{profile_id}"

  @doc "Broadcasts `{:social_ideas_changed, profile_id}` on `posts_topic/1`."
  @spec broadcast_changed(Ecto.UUID.t() | nil) :: :ok
  def broadcast_changed(profile_id) when is_binary(profile_id) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      posts_topic(profile_id),
      {:social_ideas_changed, profile_id}
    )
  end

  def broadcast_changed(_), do: :ok

  defp broadcast_written({:ok, %Idea{profile_id: profile_id}} = ok) do
    broadcast_changed(profile_id)
    ok
  end

  defp broadcast_written(other), do: other

  @doc """
  Clip Studio: the ONE idea of `clip` (source_kind `clip`, title the clip's
  title), found or created as `user_id`. Call inside the clip approval's
  transaction, with the clip row locked.
  """
  @spec find_or_create_for_clip!(Clip.t(), Profile.t(), Ecto.UUID.t()) :: Idea.t()
  def find_or_create_for_clip!(%Clip{id: clip_id} = clip, %Profile{} = profile, user_id) do
    case Repo.one(from(i in Idea, where: i.clip_id == ^clip_id and i.source_kind == "clip")) do
      %Idea{} = idea ->
        idea

      nil ->
        %Idea{org_id: profile.org_id, profile_id: profile.id}
        |> Idea.changeset(
          %{source_kind: "clip", clip_id: clip_id, title: clip_title(clip)},
          {:user, user_id}
        )
        |> Repo.insert!()
    end
  end

  defp clip_title(%Clip{} = clip) do
    [clip.title, clip.caption, clip.episode_code, "Clip"]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> String.trim()
    |> String.slice(0, Idea.max_title())
  end

  # ── Stage ────────────────────────────────────────────────────────────

  @doc """
  The idea's stage, DERIVED from its posts (an `%Idea{}` or the post list):

    * no posts: `inbox`
    * every post `draft`: `drafting`
    * any `needs_approval`: `in_review`
    * else any `approved` or `scheduled`: `scheduled`
    * else any `published`: `live`
    * every post `failed`: `failed`
    * otherwise (drafts beside failures): `drafting`
  """
  @spec stage(Idea.t() | [Post.t()]) :: String.t()
  def stage(%Idea{} = idea), do: idea |> posts() |> stage()

  def stage([]), do: "inbox"

  def stage(posts) when is_list(posts) do
    statuses = Enum.map(posts, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == "draft")) -> "drafting"
      "needs_approval" in statuses -> "in_review"
      Enum.any?(statuses, &(&1 in ~w(approved scheduled))) -> "scheduled"
      "published" in statuses -> "live"
      Enum.all?(statuses, &(&1 == "failed")) -> "failed"
      true -> "drafting"
    end
  end

  @doc "Every stage `stage/1` can answer."
  @spec stages() :: [String.t()]
  def stages, do: ~w(inbox drafting in_review scheduled live failed)

  # ── Revise ───────────────────────────────────────────────────────────

  @doc """
  A human approver asks for a revision of a `needs_approval` post, with
  `note` (trimmed, required: `:note_required`; at most #{@max_note}
  characters: `:note_too_long`, the rules of `ClipDecisions.reject_clip`).

  Refusals, each writing nothing: `:not_found` (missing or another org's
  post), the note refusals, `:not_needs_approval`, and the
  `Platform.Social.post_approver_check/4` refusal (an agent id is
  `:not_a_human`, a user off the list `:not_an_approver`, on an owned
  account anyone but the owner `:not_the_owner`).

  The post stays `needs_approval`. In one transaction with the post locked,
  a `revision_requested` event (actor human) carries the note. After
  commit, the live card re-renders ("Revision asked") and one message in
  the profile's approval space mentions the drafting agent
  (`PostEvents.drafting_agent_id/1`); with no channel or no drafting agent
  there is no message.

  Returns `{:ok, %{post, event, message}}` (`message` may be nil).
  """
  @spec request_revision(Ecto.UUID.t(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom()}
  def request_revision(org_id, post_id, user_id, note) do
    with {:ok, note} <- note(note),
         %Post{} = post <- Social.get_post(org_id, post_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        with %Post{} = locked <- Social.lock_post(org_id, post.id) || {:error, :not_found},
             :ok <- needs_approval(locked),
             %Account{} = account <- Repo.get(Account, locked.account_id) || {:error, :not_found},
             {:ok, profile} <- Social.profile_of_post(locked),
             :ok <- Social.post_approver_check(profile.org_id, profile, account, user_id) do
          event = PostEvents.record!(locked, "revision_requested", {:human, user_id}, note: note)
          {locked, account, profile, event}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {post, account, profile, event}} ->
          rerender_card(post)
          message = notify_agent(post, account, profile, note)
          {:ok, %{post: post, event: event, message: message}}

        error ->
          error
      end
    end
  end

  @doc "The longest accepted revision note."
  @spec max_note() :: pos_integer()
  def max_note, do: @max_note

  defp note(note) when is_binary(note) do
    case String.trim(note) do
      "" ->
        {:error, :note_required}

      trimmed ->
        if String.length(trimmed) > @max_note, do: {:error, :note_too_long}, else: {:ok, trimmed}
    end
  end

  defp note(_), do: {:error, :note_required}

  defp needs_approval(%Post{status: "needs_approval"}), do: :ok
  defp needs_approval(%Post{}), do: {:error, :not_needs_approval}

  defp rerender_card(%Post{id: post_id}) do
    with %Platform.Social.ApprovalCard{} = card <- Platform.Social.Approvals.live_card(post_id),
         {:error, reason} <- Platform.Social.Approvals.rerender(card) do
      Logger.warning(
        "[Social] card #{card.id} re-render after revision failed: #{inspect(reason)}"
      )
    end

    :ok
  end

  # One message in the profile's approval space naming the drafting agent,
  # posted by the Social system participant, so the agent wakes.
  defp notify_agent(post, account, %Profile{space_id: space_id} = profile, note)
       when is_binary(space_id) do
    with agent_id when is_binary(agent_id) <- PostEvents.drafting_agent_id(post),
         %Platform.Agents.Agent{name: name} when is_binary(name) and name != "" <-
           Repo.get(Platform.Agents.Agent, agent_id),
         {:ok, participant} <- Platform.Social.Approvals.system_participant(space_id),
         {:ok, message} <-
           Platform.Chat.post_message(%{
             space_id: space_id,
             participant_id: participant.id,
             content_type: "text",
             content: revision_text(name, post, account, profile, note),
             metadata: %{"social_revision" => %{"post_id" => post.id, "idea_id" => post.idea_id}}
           }) do
      message
    else
      nil ->
        nil

      other ->
        Logger.warning(
          "[Social] revision message for post #{post.id} not sent: #{inspect(other)}"
        )

        nil
    end
  end

  defp notify_agent(_post, _account, _profile, _note), do: nil

  defp revision_text(agent_name, post, account, profile, note) do
    label = Platform.Social.Approvals.platform_label(account.platform)

    "@[#{agent_name}] Revision asked on the #{label} post for #{profile.name} " <>
      "(post #{post.id}): #{note}\n" <>
      "Revise it with social_draft_update; social_idea_list shows the open note."
  end

  # ── Draft linkage ────────────────────────────────────────────────────

  @doc """
  The idea a new draft for `profile` may join: `idea_id` read through the
  scope (another org's is `{:error, :not_found}`, like a missing id) and
  `{:error, :idea_archived}` when archived. The PROFILE check is the
  caller's (`Platform.Social.AgentDrafts`).
  """
  @spec fetch_for_draft(Social.scope(), term()) ::
          {:ok, Idea.t()} | {:error, :not_found | :idea_archived}
  def fetch_for_draft(scope, idea_id) do
    case get(scope, idea_id) do
      %Idea{archived_at: nil} = idea -> {:ok, idea}
      %Idea{} -> {:error, :idea_archived}
      nil -> {:error, :not_found}
    end
  end

  # ── Refs ─────────────────────────────────────────────────────────────

  defp validate_refs(changeset, scope, %Profile{} = profile) do
    changeset
    |> validate_ref(:clip_id, fn id ->
      match?(%Clip{profile_id: pid} when pid == profile.id, Social.get_clip(scope, id))
    end)
    |> validate_ref(:task_id, &(task_org(&1) == profile.org_id))
    |> validate_ref(:meeting_id, &(meeting_org(&1) == profile.org_id))
    |> validate_ref(:message_id, &(message_org(&1) == profile.org_id))
    |> validate_url()
  end

  defp validate_ref(changeset, field, ok?) do
    case Changeset.get_change(changeset, field) do
      nil ->
        changeset

      id ->
        if ok?.(id),
          do: changeset,
          else: Changeset.add_error(changeset, field, "must exist in the profile's org")
    end
  end

  defp validate_url(changeset) do
    case Changeset.get_change(changeset, :source_url) do
      nil ->
        changeset

      url ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            changeset

          _ ->
            Changeset.add_error(changeset, :source_url, "must be an http or https URL")
        end
    end
  end

  defp task_org(id) do
    case Platform.Tasks.get_task_record(id) do
      %{project_id: project_id} -> project_org(project_id)
      _ -> nil
    end
  end

  defp meeting_org(id) do
    case Platform.Meetings.get_meeting(id) do
      %{project_id: project_id} -> project_org(project_id)
      _ -> nil
    end
  end

  defp message_org(id) do
    with %{space_id: space_id} <- Platform.Chat.get_message(id),
         %{org_id: org_id} <- Platform.Chat.get_space(space_id) do
      org_id
    else
      _ -> nil
    end
  end

  defp project_org(project_id) when is_binary(project_id) do
    case Platform.Tasks.get_project(project_id) do
      %{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  defp project_org(_), do: nil

  defp normalize(attrs) when is_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp normalize(_), do: %{}
end
