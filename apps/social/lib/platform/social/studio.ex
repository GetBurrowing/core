defmodule Platform.Social.Studio do
  @moduledoc """
  Social Studio: the context for posts that are planned inside Burrow and
  never sent. Slice A holds the
  basics (enablement, create and read) plus slice B: approval, planning,
  revoking, changes requested, versioned edits and retargets, creative
  acceptance and the receipts list. Nothing here ever sends: no function calls
  a send-side module (a source test pins that).

  ## Writers (slice B)

  Every post transition runs through one private writer, `write/6`: scoped
  load; one transaction; the locks below; the checks above decided AGAIN on the
  LOCKED rows; then the transition. Each transition bumps `state_rev` once
  and writes exactly its events, atomically. A refused or stale call rolls
  back with nothing written and no event.

  ## Submitting a draft

  `resubmit/5` is "submit": any Studio `draft`, rejected or never rejected,
  goes to `needs_approval`. Human only (an agent id is `:not_a_human`; no agent
  submission path exists), same checks and `expect` as every transition, one
  `submitted` event, `state_rev` bumped, `version` kept, rejection fields
  cleared, no approval and no plan. Any other status is `:not_a_draft`.

  ## Lock order (every Studio write, slices A, B and C)

  1. the profile row, `FOR SHARE` (`Social.lock_profile/3`);
  2. the account row(s), `FOR SHARE` (`Social.lock_account/3`), in ASCENDING
     account id when there are several (a retarget locks the old and the new
     account; `accept_render/4` locks every requested destination, and the
     current account of an existing post it replays);
  3. the post row `FOR UPDATE` (`accept_render/4`: the clip row `FOR UPDATE`).

  Two writers that need overlapping rows therefore take them in the same order
  whatever order the caller named them in, and cannot deadlock. `FOR SHARE`
  locks never conflict with each other; they make a plain `UPDATE` of the row
  (archive, owner change, approver removal) wait for the writer in flight. A
  writer that finds, after the post lock, that the post moved to another
  account since its first read starts the attempt again with that account in
  the lock set (still ascending).

  ## The flow boundary

  A post is `legacy` or `studio` (`social_posts.flow`). Studio functions act
  only on Studio rows and answer `{:error, :not_studio_post}` for a legacy
  row; legacy functions refuse a Studio row with `{:error, :studio_post}`.
  Every send-side path (publish, retry, sweeps, vendor cancel, status read,
  webhook, `apply_outcome/2`) refuses a Studio row BEFORE any external call:
  the database CHECKs behind them are the second line, because a CHECK cannot
  undo a send.

  ## Check order

  1. scoped load (a row in another org reads `:not_found`);
  2. `profile.studio_enabled`, else `{:error, :studio_disabled}`;
  3. flow;
  4. `{:error, :account_archived}` (a write on an archived account);
  5. actor: `Platform.Social.post_approver_check/4` in its vocabulary, then
     then the project (see "The project" below), then `social.use`
     (`{:error, :no_social_access}`: a user locked out of the Social module,
     or denied `social.use` on the profile's project, may not write Studio
     rows even when they are an approver);
  6. stale tokens: `state_rev` (and `version` when given), then the receipt
     authority of plan and replan.

  ## The project

  `Platform.Access.Grants` accepts no org resource, so `social.use` is decided
  on the profile's project. Studio enablement and writes therefore need a live
  project (not archived, not scheduled for deletion) in the profile's org.
  One refusal covers every way that fails: `{:error, :studio_needs_project}`
  (no project, archived, scheduled for deletion, missing, or another org's).
  The project is validated BEFORE it is used as the permission target.

  The public helpers (`require_studio_project/1`, `require_social_use/2`,
  `authorize_studio_actor/2`) run the actor step in this order: approver check
  (the caller's, first), project, module lock, then
  `Platform.Access.can?(scope, "social.use", {:project, id})`. They must be
  given the profile row read UNDER `Social.lock_profile/3`, because
  `Social.update_profile/3` can move `project_id` between a caller's first
  load and the lock. Lock order: the profile row first, always.

  ## Authority is decided under the lock (slices A, B, C)

  A check made before the lock does not stand in for the one under it. Every
  Studio write with a human actor locks the profile row (`Social.lock_profile/3`),
  then the account row (`Social.lock_account/3`, `FOR SHARE` for creators), and
  decides again on those rows, in the check order: `studio_enabled`, flow, account
  archived, then the actor (approver or owner check, then
  `authorize_studio_actor/2`). Owner changes, approver removals and archiving
  that commit between the first load and the lock are therefore honoured. An
  early refusal before the lock is allowed as a shortcut only.

  ### The switch-off exception

  Switching Studio OFF is the safe direction, so `set_enabled(..., false)` by
  an authorised live-human approver is allowed when the project is missing or
  invalid (`:studio_needs_project` is not raised). The module lock still
  refuses it, and so does a `social.use` deny on a VALID project. Enabling, and
  every content write, still need the valid project and the scoped permission.
  Legacy profiles and legacy functions are unchanged.

  ## Known limitation (documented, not redesigned)

  A Studio post is never deleted by this code (`Social.delete_post/2`,
  `Social.delete_profile/2` and clip undo refuse Studio rows), and one that
  has an approval row cannot be removed even by an FK cascade
  (`social_post_approvals.post_id` is `restrict`). A Studio draft with no
  approval row can still be removed by a direct SQL delete or an org-level
  cascade, since `social_posts` cascades from its account and profile. No
  trigger is added.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    Account,
    AgentDraftRequest,
    Approvals,
    Clip,
    ClipRender,
    Links,
    Post,
    PostApproval,
    PostEvents,
    Profile
  }

  @type error ::
          :not_found
          | :studio_disabled
          | :not_studio_post
          | :no_social_access
          | :studio_needs_project
          | Social.approver_refusal()
          | term()

  # ── Enablement ───────────────────────────────────────────────────────

  @doc "Whether Studio is switched on for `profile`."
  @spec enabled?(Profile.t()) :: boolean()
  def enabled?(%Profile{studio_enabled: enabled}), do: enabled == true

  @doc """
  Switches Studio on or off for a profile. The actor must pass
  `Platform.Social.approver_check/3` (the rule for managing the profile); a
  profile in another org reads `:not_found`. Turning it off touches no row
  and no process: Studio rows stay inert and no worker acts on them.

  Writes the profile row, so it takes `Social.lock_profile(:update)` and
  decides on the row read under that lock (a `project_id` changed since the
  caller loaded the profile is honoured). Order: approver check, then (for
  enabling) the project and scoped permission as in `authorize_studio_actor/2`.

  **Switch-off exception.** Switching OFF is allowed for an authorised
  live-human approver even when the profile has no project or an invalid one
  (no `:studio_needs_project`). The module lock still refuses it
  (`:no_social_access`), and so does a `social.use` deny on a VALID project.
  Enabling requires the valid project and the scoped permission.
  """
  @spec set_enabled(Ecto.UUID.t(), Ecto.UUID.t(), term(), boolean()) ::
          {:ok, Profile.t()} | {:error, error()}
  def set_enabled(org_id, profile_id, user_id, enabled) when is_boolean(enabled) do
    with %Profile{} <- Social.get_profile(org_id, profile_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        # Lock order: profile row first. Everything below decides on `locked`.
        locked = Social.lock_profile(org_id, profile_id, :update) || Repo.rollback(:not_found)

        with :ok <- Social.approver_check(org_id, locked, user_id),
             :ok <- authorize_enable_change(locked, user_id, enabled),
             {:ok, updated} <-
               locked |> Ecto.Changeset.change(studio_enabled: enabled) |> Repo.update() do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # Enabling needs the full actor step; switching off needs only the module
  # lock, plus the scoped permission when the project is valid.
  defp authorize_enable_change(profile, user_id, true),
    do: authorize_studio_actor(profile, user_id)

  defp authorize_enable_change(profile, user_id, false) do
    with :ok <- require_module_use(user_id) do
      case require_studio_project(profile) do
        {:ok, project_id} -> require_project_use(user_id, project_id)
        {:error, :studio_needs_project} -> :ok
      end
    end
  end

  # ── Create and read ──────────────────────────────────────────────────

  @doc """
  Creates a Studio post, version 1, on `account_id` as `user_id`: status
  `draft` or `needs_approval` (default `needs_approval`), no approval, no
  schedule, no publish timer, no approval card. Writes `created` (and
  `submitted` for `needs_approval`) in the same transaction as the post; an
  event that fails to write rolls the post back.
  """
  @spec create_post(Ecto.UUID.t(), Ecto.UUID.t(), term(), map()) ::
          {:ok, Post.t()} | {:error, error() | Ecto.Changeset.t()}
  def create_post(org_id, account_id, user_id, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("status", "needs_approval")

    with %Account{} = account <- Social.get_account(org_id, account_id) || {:error, :not_found},
         %Profile{} = profile <-
           Social.get_profile(org_id, account.profile_id) || {:error, :not_found},
         :ok <- require_enabled(profile),
         :ok <- require_live(account),
         :ok <- Social.post_approver_check(org_id, profile, account, user_id) do
      Repo.transaction(fn ->
        # Lock order: profile row first (see `Social.lock_profile/3`). `:share`
        # conflicts with `delete_profile/2`'s `:update`, so creation and deletion
        # serialise; a profile deleted meanwhile reads as not found.
        locked = Social.lock_profile(org_id, profile, :share) || Repo.rollback(:not_found)

        # The account row next (profile first, then account). The creator's
        # `FOR SHARE` makes an owner change or archive wait for creates in
        # flight; a create after it commits reads the new row.
        locked_account =
          Social.lock_account(locked, account.id, :share) || Repo.rollback(:not_found)

        # Everything from check order 2 on is decided AGAIN on the locked rows:
        # the pre-lock checks above are only early refusals.
        if !enabled?(locked), do: Repo.rollback(:studio_disabled)

        with {:error, reason} <- require_live(locked_account), do: Repo.rollback(reason)

        with {:error, reason} <-
               Social.post_approver_check(org_id, locked, locked_account, user_id),
             do: Repo.rollback(reason)

        # The project and `social.use` are decided on the LOCKED profile too:
        # `project_id` may have moved since it was loaded.
        with {:error, reason} <- authorize_studio_actor(locked, user_id),
             do: Repo.rollback(reason)

        changeset =
          %Post{account_id: account.id, flow: "studio"}
          |> Post.studio_create_changeset(attrs)

        case Repo.insert(changeset) do
          {:ok, post} ->
            PostEvents.record!(post, "created", {:human, user_id})

            if post.status == "needs_approval",
              do: PostEvents.record!(post, "submitted", {:human, user_id})

            post

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  # ── Agent drafts ─────────────────────────────────────────────────────

  @agent_draft_keys ~w(request_id body media_file_ids link_url status)
  @max_request_id 200
  @max_agent_media 20

  @doc """
  The agent tool `social_studio_draft_create`: creates a Studio post, version 1,
  status `draft`, on `account_id`, and nothing else. No submit, approval, plan,
  timer or vendor call; a person submits it from Today. `attrs` (string or atom
  keys): `request_id` (required), `body` (required), `media_file_ids`,
  `link_url`, and `status` (only `"draft"`; any other value is
  `{:error, :status_not_allowed}`, never changed). An `idea_id`, with any
  value, is `{:error, :idea_not_supported}`: v1 does not link drafts to ideas,
  and the key is refused, never ignored. Any other key is
  `{:error, :field_not_allowed, keys}`.

  `scope` is the agent's home-org scope, resolved by the caller from the agent
  (`Platform.Social.Tools`), never from a client argument: the one access rule
  the legacy agent draft path (`Platform.Social.AgentDrafts`) applies, org
  visibility through `Social.visible_orgs/1`. On top: Studio on for the profile
  and a live project (`require_studio_project/1`). The human approver check is
  NOT used. An account or profile outside the scope reads `:not_found`.

  Lock order is `create_post/4`'s: profile row `FOR SHARE`, then account row
  `FOR SHARE`. Every
  decision (Studio on, account live, the agent and its home org, project) is
  made AGAIN on the locked rows, and again on a retry, before the request is
  looked up, so a replay never reveals a draft to a caller that lost access.

  Retry safety: `request_id` is unique per (agent, account): Studio's unit is
  one post on one account. The same id with the same content returns the one
  existing post (`{:ok, post, :replayed}`); the same id with different content
  (text, link or media) is `{:error, :request_id_conflict}` and touches
  nothing; the same id on another account the agent may use is a separate
  draft; on an account it may not use it is refused like any other call
  (`:not_found`), before any request row is read, so nothing of the first
  draft shows. Concurrent repeats are decided by the unique index on
  `social_agent_draft_requests`: the loser's transaction rolls back whole.

  Media is by reference: each `media_file_ids` entry must be a finalized,
  live Burrow Files row in the profile's org and project
  (`:file_not_in_project`, `:file_not_ready`). Banned phrases of the profile's
  voice refuse the draft (`{:error, :banned_phrase, phrase}`). The post's
  `created` event has actor `{:agent, agent_id}`; that event is what Today
  reads to mark it agent-drafted.
  """
  @spec create_agent_draft(Social.scope(), term(), term(), map()) ::
          {:ok, Post.t(), :created | :replayed} | {:error, term()} | {:error, atom(), term()}
  def create_agent_draft(scope, account_id, agent_id, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- refuse_idea(attrs),
         :ok <- refuse_agent_keys(attrs),
         :ok <- require_draft_status(attrs),
         {:ok, request_id} <- request_id(attrs),
         {:ok, account_id} <- cast_uuid(account_id),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, media_ids} <- media_ids(attrs),
         %Account{} = account <- Social.get_account(scope, account_id) || {:error, :not_found},
         %Profile{} = profile <-
           Social.get_profile(scope, account.profile_id) || {:error, :not_found},
         :ok <- require_enabled(profile),
         :ok <- require_live(account) do
      draft = %{
        request_id: request_id,
        body: attrs["body"],
        media_ids: media_ids,
        link_url: blank_to_nil(attrs["link_url"]),
        agent_id: agent_id,
        account_id: account.id
      }

      agent_draft_attempt(scope, profile, account, draft)
    end
  end

  defp agent_draft_attempt(scope, profile, account, draft) do
    hash = draft_hash(draft)

    result =
      Repo.transaction(fn ->
        # Lock order, as `create_post/4`: profile row, then account row.
        locked = Social.lock_profile(scope, profile, :share) || Repo.rollback(:not_found)

        locked_account =
          Social.lock_account(locked, account.id, :share) || Repo.rollback(:not_found)

        # Decided AGAIN on the locked rows, in the check order; the checks
        # before the transaction were early refusals only.
        with {:error, reason} <- require_enabled(locked), do: Repo.rollback(reason)
        with {:error, reason} <- require_live(locked_account), do: Repo.rollback(reason)

        with {:error, reason} <- agent_authority(scope, locked, draft.agent_id),
             do: Repo.rollback(reason)

        with {:error, reason} <- require_studio_project(locked), do: Repo.rollback(reason)

        # Only now is the request looked up: a replay is decided on the same
        # authority as a first call.
        case existing_request(draft.agent_id, locked_account.id, draft.request_id) do
          nil -> insert_agent_draft!(locked, draft, hash)
          request -> replay_or_conflict!(request, hash)
        end
      end)

    case result do
      {:ok, {:created, post}} -> {:ok, post, :created}
      {:ok, {:replayed, post}} -> {:ok, post, :replayed}
      {:error, {:banned_phrase, phrase}} -> {:error, :banned_phrase, phrase}
      {:error, :lost_race} -> lost_race(draft, hash)
      {:error, reason} -> {:error, reason}
    end
  end

  # The agent's authority is the legacy draft path's: the org scope the caller
  # derived from the agent. It is read again under the lock: the agent must
  # still exist and its home org must still see the profile's org.
  defp agent_authority(scope, %Profile{org_id: org_id}, agent_id) do
    with %Platform.Agents.Agent{} = agent <- Repo.get(Platform.Agents.Agent, agent_id),
         true <- Social.org_visible?(scope, org_id),
         true <- Social.org_visible?(Platform.Experiments.Tools.home_org(agent), org_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp existing_request(agent_id, account_id, request_id) do
    Repo.one(
      from(r in AgentDraftRequest,
        where:
          r.agent_id == ^agent_id and r.account_id == ^account_id and
            r.request_id == ^request_id
      )
    )
  end

  defp replay_or_conflict!(%AgentDraftRequest{content_hash: hash, post_id: post_id}, hash) do
    case lock_replayed_post(post_id) do
      %Post{discarded_at: %DateTime{}} -> Repo.rollback(:post_discarded)
      %Post{} = post -> {:replayed, post}
      nil -> Repo.rollback(:not_found)
    end
  end

  defp replay_or_conflict!(%AgentDraftRequest{}, _hash), do: Repo.rollback(:request_id_conflict)

  defp insert_agent_draft!(%Profile{} = profile, draft, hash) do
    changeset =
      %Post{account_id: draft.account_id, flow: "studio"}
      |> Post.studio_create_changeset(%{
        "body" => draft.body,
        "media_file_ids" => draft.media_ids,
        "link_url" => draft.link_url,
        "status" => "draft"
      })

    unless changeset.valid?, do: Repo.rollback(changeset)

    with phrase when is_binary(phrase) <-
           Platform.Social.Voice.banned_phrase(
             Ecto.Changeset.get_field(changeset, :body),
             profile
           ),
         do: Repo.rollback({:banned_phrase, phrase})

    with {:error, reason} <- check_agent_media(draft.media_ids, profile),
         do: Repo.rollback(reason)

    post = Repo.insert!(changeset)
    PostEvents.record!(post, "created", {:agent, draft.agent_id})

    request =
      Repo.insert!(
        %AgentDraftRequest{
          agent_id: draft.agent_id,
          account_id: draft.account_id,
          post_id: post.id,
          request_id: draft.request_id,
          content_hash: hash
        },
        # The unique index on (agent, account, request id) decides a race: the
        # second insert waits for the first to commit, then does nothing.
        on_conflict: :nothing
      )

    if own_request?(request, draft),
      do: {:created, post},
      else: Repo.rollback(:lost_race)
  end

  defp own_request?(%AgentDraftRequest{id: id}, draft) do
    match?(
      %AgentDraftRequest{id: ^id},
      existing_request(draft.agent_id, draft.account_id, draft.request_id)
    )
  end

  # Another connection committed the same request id first; this transaction
  # rolled back with nothing written. Answer from the winner's row.
  defp lost_race(draft, hash) do
    result =
      Repo.transaction(fn ->
        with %AgentDraftRequest{content_hash: ^hash, post_id: post_id} <-
               existing_request(draft.agent_id, draft.account_id, draft.request_id),
             %Post{discarded_at: nil} = post <- lock_replayed_post(post_id) do
          post
        else
          %Post{discarded_at: %DateTime{}} -> Repo.rollback(:post_discarded)
          %AgentDraftRequest{} -> Repo.rollback(:request_id_conflict)
          _ -> Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, post} -> {:ok, post, :replayed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_replayed_post(id),
    do: Repo.one(from(p in Post, where: p.id == ^id, lock: "FOR SHARE"))

  defp check_agent_media([], _profile), do: :ok

  defp check_agent_media(ids, %Profile{} = profile) do
    Enum.find_value(ids, :ok, fn id ->
      case Platform.Files.get_file(id) do
        %{deleted_at: nil, project_id: project_id} = file
        when is_binary(project_id) ->
          cond do
            project_id != profile.project_id or
                not Platform.Social.OrgFiles.in_org?(file, profile.org_id) ->
              {:error, :file_not_in_project}

            not Platform.Files.finalized_upload?(file) ->
              {:error, :file_not_ready}

            true ->
              nil
          end

        _ ->
          {:error, :file_not_in_project}
      end
    end)
  end

  defp refuse_idea(attrs),
    do: if(Map.has_key?(attrs, "idea_id"), do: {:error, :idea_not_supported}, else: :ok)

  defp refuse_agent_keys(attrs) do
    case Map.keys(attrs) -- @agent_draft_keys do
      [] -> :ok
      keys -> {:error, :field_not_allowed, Enum.sort(keys)}
    end
  end

  defp require_draft_status(%{"status" => status}) when status != nil and status != "draft",
    do: {:error, :status_not_allowed}

  defp require_draft_status(_attrs), do: :ok

  defp request_id(%{"request_id" => id}) when is_binary(id) do
    if String.trim(id) != "" and String.length(id) <= @max_request_id,
      do: {:ok, id},
      else: {:error, :request_id_required}
  end

  defp request_id(_attrs), do: {:error, :request_id_required}

  defp cast_uuid(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, uuid}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_uuid(_id), do: {:error, :not_found}

  defp media_ids(%{"media_file_ids" => ids})
       when is_list(ids) and length(ids) <= @max_agent_media do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case cast_uuid(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        _ -> {:halt, {:error, :file_not_in_project}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp media_ids(%{"media_file_ids" => nil}), do: {:ok, []}
  defp media_ids(%{"media_file_ids" => _}), do: {:error, :too_many_files}
  defp media_ids(_attrs), do: {:ok, []}

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  # What "the same request" means: its content. The destination account and
  # the request id are the key, never part of the hash.
  defp draft_hash(draft) do
    [draft.body, draft.media_ids, draft.link_url]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Reads one Studio post in the caller's org (check order 1 to 3)."
  @spec get_post(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Post.t()} | {:error, error()}
  def get_post(org_id, post_id) do
    with %Post{} = post <- Social.get_post(org_id, post_id) || {:error, :not_found},
         {:ok, profile} <- Social.profile_of_post(post),
         :ok <- require_enabled(profile),
         :ok <- require_studio(post),
         true <- is_nil(post.discarded_at) || {:error, :not_found} do
      {:ok, post}
    end
  end

  @doc "A profile's Studio posts, oldest first. Legacy posts are never listed."
  @spec list_posts(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, [Post.t()]} | {:error, error()}
  def list_posts(org_id, profile_id) do
    with %Profile{} = profile <- Social.get_profile(org_id, profile_id) || {:error, :not_found},
         :ok <- require_enabled(profile) do
      {:ok,
       Repo.all(
         from(po in Post,
           join: a in Account,
           on: a.id == po.account_id,
           where: a.profile_id == ^profile.id and po.flow == "studio" and is_nil(po.discarded_at),
           order_by: [asc: po.inserted_at, asc: po.id]
         )
       )}
    end
  end

  @doc "Recently discarded drafts in one visible profile, limited to accounts this human can discard."
  def list_discarded_drafts(org_id, profile_id, user_id, page \\ 0)
      when is_integer(page) and page >= 0 do
    with {:ok, profile, accounts} <- recovery_accounts(org_id, profile_id, user_id) do
      account_ids = Map.keys(accounts)

      posts =
        Repo.all(
          from(p in Post,
            where:
              p.flow == "studio" and p.account_id in ^account_ids and not is_nil(p.discarded_at),
            order_by: [desc: p.discarded_at, desc: p.id],
            limit: 20,
            offset: ^(page * 20)
          )
        )

      events = posts |> Enum.map(& &1.id) |> PostEvents.list_for_posts()

      {:ok,
       Enum.map(posts, fn post ->
         event =
           events
           |> Map.get(post.id, [])
           |> Enum.reverse()
           |> Enum.find(&(&1.action == "discarded"))

         account = Map.fetch!(accounts, post.account_id)
         reason = restore_reason(profile, account, user_id)

         %{
           post: post,
           account: account,
           event: event,
           history: Map.get(events, post.id, []),
           can_restore?: is_nil(reason),
           restore_reason: reason
         }
       end)}
    end
  end

  @doc "Discarded destination reservations for one render, limited to accounts this human can discard."
  def discarded_render_reservations(org_id, profile_id, user_id, render_id) do
    with {:ok, _profile, accounts} <- recovery_accounts(org_id, profile_id, user_id),
         {:ok, render_id} <- Ecto.UUID.cast(render_id) do
      account_ids = Map.keys(accounts)

      rows =
        Repo.all(
          from(p in Post,
            where:
              p.flow == "studio" and
                (p.account_id in ^account_ids or p.accepted_account_id in ^account_ids) and
                p.clip_render_id == ^render_id and not is_nil(p.discarded_at),
            select: %{account_id: p.account_id, accepted_account_id: p.accepted_account_id}
          )
        )

      {:ok,
       Enum.map(rows, fn row ->
         %{
           account_id: if(Map.has_key?(accounts, row.account_id), do: row.account_id),
           accepted_account_id:
             if(Map.has_key?(accounts, row.accepted_account_id), do: row.accepted_account_id)
         }
       end)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp recovery_accounts(org_id, profile_id, user_id) do
    with %Platform.Accounts.User{archived_at: nil} = user <- Platform.Accounts.get_user(user_id),
         %Profile{} = profile <- Social.get_profile(org_id, profile_id),
         true <- Enum.any?(Social.list_profiles_for_user(user), &(&1.id == profile.id)),
         :ok <- require_enabled(profile),
         :ok <- require_social_use(user.id, profile) do
      accounts =
        profile.org_id
        |> Social.list_accounts(profile_id: profile.id, include_archived: true)
        |> Enum.filter(&(Social.post_rejecter_check(profile.org_id, profile, &1, user.id) == :ok))
        |> Map.new(&{&1.id, &1})

      {:ok, profile, accounts}
    else
      _ -> {:error, :not_found}
    end
  end

  defp restore_reason(_profile, %{archived_at: archived_at}, _user_id)
       when not is_nil(archived_at), do: :account_archived

  defp restore_reason(profile, account, user_id) do
    if Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok,
      do: nil,
      else: :approver_required
  end

  defp require_enabled(%Profile{} = profile),
    do: if(enabled?(profile), do: :ok, else: {:error, :studio_disabled})

  defp require_studio(%Post{} = post),
    do: if(Post.studio?(post), do: :ok, else: {:error, :not_studio_post})

  @doc """
  The project, module lock and project-scoped `social.use` steps for a Studio
  actor, in that order. Call it AFTER the approver check and on the profile row
  read under `Social.lock_profile/3` (profile row first in the lock order); a
  stale struct can carry a `project_id` that has since changed. Returns `:ok`,
  `{:error, :studio_needs_project}` or `{:error, :no_social_access}`.
  """
  @spec authorize_studio_actor(Profile.t(), term()) ::
          :ok | {:error, :studio_needs_project | :no_social_access}
  def authorize_studio_actor(%Profile{} = profile, user_id) do
    with {:ok, project_id} <- require_studio_project(profile),
         :ok <- require_module_use(user_id) do
      require_project_use(user_id, project_id)
    end
  end

  @doc """
  The profile's live same-org project, or `{:error, :studio_needs_project}` for
  no project, an archived one, one scheduled for deletion, or another org's.
  Pass the profile row read under `Social.lock_profile/3`.
  """
  @spec require_studio_project(Profile.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :studio_needs_project}
  def require_studio_project(%Profile{project_id: nil}), do: {:error, :studio_needs_project}

  def require_studio_project(%Profile{project_id: project_id, org_id: org_id}) do
    if Platform.Tasks.live_project_in_org?(project_id, org_id),
      do: {:ok, project_id},
      else: {:error, :studio_needs_project}
  end

  @doc """
  The scoped permission check: the user passes the module lock and holds
  `social.use` on the profile's project. `:ok` or `{:error, :no_social_access}`.
  Needs a valid project (`{:error, :studio_needs_project}` otherwise); pass the
  profile row read under the lock, as for `authorize_studio_actor/2`.
  """
  @spec require_social_use(term(), Profile.t()) ::
          :ok | {:error, :studio_needs_project | :no_social_access}
  def require_social_use(user_id, %Profile{} = profile) do
    with {:ok, project_id} <- require_studio_project(profile),
         :ok <- require_module_use(user_id) do
      require_project_use(user_id, project_id)
    end
  end

  # The actor holds `social.use` (the module permission, honouring a module
  # lock). Runs after the approver check, so `user_id` is a live human here.
  defp require_module_use(user_id) do
    with %{} = user <- Platform.Accounts.get_user(user_id),
         true <-
           Platform.Access.module_access?(
             Platform.Access.Scope.for_user(user),
             :social,
             "social.use"
           ) do
      :ok
    else
      _ -> {:error, :no_social_access}
    end
  end

  # `social.use` decided on the (already validated) project, so a project-level
  # deny refuses even when the module itself is visible.
  defp require_project_use(user_id, project_id) do
    with %{} = user <- Platform.Accounts.get_user(user_id),
         true <-
           Platform.Access.can?(
             Platform.Access.Scope.for_user(user),
             "social.use",
             {:project, project_id}
           ) do
      :ok
    else
      _ -> {:error, :no_social_access}
    end
  end

  # ── Slice B: the writer ──────────────────────────────────────────────

  @type expect :: %{required(:state_rev) => integer(), optional(atom()) => term()}

  # The one place a post transition starts. `opts`:
  #   * `:actor_check` (ctx -> :ok | {:error, _}): the actor step;
  #   * `:archived` (ctx -> :refuse | :allow): default `:refuse`;
  #   * `:extra_accounts` (post -> [account id]): further accounts the
  #     transition reads (a retarget's new account), locked with the post's.
  # `fun` receives the ctx built from LOCKED rows and returns `{:ok, result}` or
  # `{:error, reason}`; an error rolls the transaction back.
  defp write(org_id, post_id, actor, expect, opts, fun) do
    with %Post{} = post0 <- Social.get_post(org_id, post_id) || {:error, :not_found},
         {:ok, profile0} <- Social.profile_of_post(post0) do
      write_attempt(org_id, post0, profile0, actor, expect, opts, fun, 3)
    end
  end

  defp write_attempt(org_id, post0, profile0, actor, expect, opts, fun, attempts_left) do
    extra = Keyword.get(opts, :extra_accounts, fn _ -> [] end).(post0)

    result =
      Repo.transaction(fn ->
        # Lock order: profile row, then account row(s) in id order, then post.
        profile = Social.lock_profile(org_id, profile0, :share) || Repo.rollback(:not_found)
        locked = lock_accounts_in_order(profile, [post0.account_id | extra])
        post = lock_post(post0.id) || Repo.rollback(:not_found)

        # The post may have been retargeted between the first read and the
        # lock, to an account this pass has not locked. Never lock that account
        # now: it would come after the post, against profile -> accounts
        # ascending -> post. Nothing has been written, so end the
        # transaction and start again, which locks the right account in order.
        # The bound is the three attempts `write/6` makes (two restarts); when
        # the last one still finds an unlocked destination the answer is the
        # stale shape, never a late lock.
        if not Map.has_key?(locked, post.account_id) and attempts_left > 1 do
          {:moved, post}
        else
          account =
            Map.get(locked, post.account_id) ||
              Repo.rollback({:stale, %{state_rev: post.state_rev, version: post.version}})

          ctx = %{
            org_id: org_id,
            profile: profile,
            post: post,
            account: account,
            accounts: locked,
            actor: actor,
            expect: expect
          }

          with :ok <- require_enabled(profile),
               :ok <- require_studio(post),
               :ok <- require_live_unless(ctx, opts),
               :ok <- Keyword.fetch!(opts, :actor_check).(ctx),
               :ok <- require_not_discarded(ctx, opts),
               :ok <- check_stale(ctx),
               {:ok, result} <- fun.(ctx) do
            result
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)

    case result do
      {:ok, {:moved, post}} ->
        write_attempt(org_id, post, profile0, actor, expect, opts, fun, attempts_left - 1)

      other ->
        other
    end
  end

  # Locks the accounts of `profile` among `ids` FOR SHARE in ascending id order
  # and returns `%{id => account}`. An id that is not an account of this profile
  # (unknown, another profile's) is simply absent.
  defp lock_accounts_in_order(profile, ids) do
    ids
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn id, acc ->
      case Social.lock_account(profile, id, :share) do
        nil -> acc
        account -> Map.put(acc, id, account)
      end
    end)
  end

  defp lock_post(id), do: Repo.one(from(p in Post, where: p.id == ^id, lock: "FOR UPDATE"))

  defp require_live_unless(ctx, opts) do
    case Keyword.get(opts, :archived, fn _ -> :refuse end).(ctx) do
      :allow -> :ok
      :refuse -> require_live(ctx.account)
    end
  end

  defp require_not_discarded(%{post: %{discarded_at: nil}}, _opts), do: :ok

  defp require_not_discarded(_ctx, opts) do
    if Keyword.get(opts, :allow_discarded, false), do: :ok, else: {:error, :post_discarded}
  end

  # Approver (a): `post_approver_check/4` on the post's account, then the
  # project, module lock and `social.use` on the LOCKED profile.
  defp approver_actor(%{actor: {:human, user_id}} = ctx) do
    with :ok <- Social.post_approver_check(ctx.org_id, ctx.profile, ctx.account, user_id) do
      authorize_studio_actor(ctx.profile, user_id)
    end
  end

  # Rejecter: the same, with the owner-gone fallback.
  defp rejecter_actor(%{actor: {:human, user_id}} = ctx) do
    with :ok <- Social.post_rejecter_check(ctx.org_id, ctx.profile, ctx.account, user_id) do
      authorize_studio_actor(ctx.profile, user_id)
    end
  end

  defp check_stale(%{post: post, expect: expect}) do
    cond do
      not (is_map(expect) and is_integer(Map.get(expect, :state_rev))) ->
        {:error, :expect_required}

      expect.state_rev != post.state_rev ->
        stale(post)

      Map.get(expect, :version) not in [nil, post.version] ->
        stale(post)

      true ->
        :ok
    end
  end

  defp stale(post), do: {:error, {:stale, %{state_rev: post.state_rev, version: post.version}}}

  defp human(user_id), do: {:human, user_id}

  @doc "Reversibly discard an unapproved Studio draft as an authorized human."
  def discard_draft(org_id, post_id, user_id, expect) do
    actor = human(user_id)

    write(
      org_id,
      post_id,
      actor,
      expect,
      [actor_check: &rejecter_actor/1, archived: fn _ -> :allow end, allow_discarded: true],
      fn ctx ->
        cond do
          ctx.post.status != "draft" ->
            {:error, :not_a_draft}

          not is_nil(ctx.post.discarded_at) ->
            {:error, :already_discarded}

          not discard_safe?(ctx.post) ->
            {:error, :approval_not_current}

          true ->
            updated = bump(ctx.post, discarded_at: DateTime.utc_now())
            PostEvents.record!(updated, "discarded", actor)
            {:ok, updated}
        end
      end
    )
  end

  @doc "Restore a previously discarded Studio draft as an authorized human."
  def restore_draft(org_id, post_id, user_id, expect) do
    actor = human(user_id)

    write(
      org_id,
      post_id,
      actor,
      expect,
      [actor_check: &approver_actor/1, allow_discarded: true],
      fn ctx ->
        cond do
          ctx.post.status != "draft" ->
            {:error, :not_a_draft}

          is_nil(ctx.post.discarded_at) ->
            {:error, :not_discarded}

          not discard_safe?(ctx.post) ->
            {:error, :approval_not_current}

          restore_destination_taken?(ctx.post) ->
            {:error, :duplicate_destination}

          true ->
            updated = bump(ctx.post, discarded_at: nil)
            PostEvents.record!(updated, "restored", actor)
            {:ok, updated}
        end
      end
    )
  end

  defp discard_safe?(post) do
    is_nil(post.scheduled_at) and is_nil(post.planned_by_user_id) and
      is_nil(post.planned_set_at) and is_nil(post.approved_by_user_id) and
      is_nil(post.approved_at) and is_nil(current_receipt(post))
  end

  defp restore_destination_taken?(%Post{clip_render_id: nil}), do: false

  defp restore_destination_taken?(post) do
    destination =
      if is_nil(post.accepted_account_id) do
        dynamic([p], p.account_id == ^post.account_id)
      else
        dynamic(
          [p],
          p.account_id == ^post.account_id or p.accepted_account_id == ^post.accepted_account_id
        )
      end

    Repo.exists?(
      from(p in Post,
        where:
          p.flow == "studio" and p.clip_render_id == ^post.clip_render_id and p.id != ^post.id,
        where: ^destination
      )
    )
  end

  defp actor_id({_kind, id}), do: id

  defp current_receipt(%Post{id: id}) do
    Repo.one(from(a in PostApproval, where: a.post_id == ^id and a.state == "current"))
  end

  # (b) receipt authority: the receipt's approver still passes the approver
  # check for the post's account now.
  defp receipt_authority?(ctx, %PostApproval{approved_by_user_id: approver_id}),
    do: Social.post_approver_check(ctx.org_id, ctx.profile, ctx.account, approver_id) == :ok

  defp receipt_authority?(_ctx, nil), do: false

  defp end_receipt!(%PostApproval{} = receipt, state, actor, reason) do
    {kind, id} = actor_ends(actor)

    receipt
    |> Ecto.Changeset.change(
      state: state,
      ended_at: DateTime.utc_now(),
      ended_by_kind: kind,
      ended_by_id: id,
      ended_reason: reason
    )
    |> Repo.update!()
  end

  defp actor_ends({:human, id}), do: {"human", id}
  defp actor_ends({:agent, id}), do: {"agent", id}

  defp bump(post, changes) do
    post
    |> Ecto.Changeset.change(Keyword.put(changes, :state_rev, post.state_rev + 1))
    |> Repo.update!()
  end

  @clear_plan [scheduled_at: nil, planned_by_user_id: nil, planned_set_at: nil]
  @clear_approval [approved_by_user_id: nil, approved_at: nil]

  defp snapshot(%Post{} = post) do
    %{
      "account_id" => post.account_id,
      "version" => post.version,
      "body" => post.body,
      "link_url" => post.link_url,
      "media_file_ids" => post.media_file_ids || [],
      "cover_file_id" => post.cover_file_id,
      "cover_offset_ms" => post.cover_offset_ms,
      "platform_options" => post.platform_options || %{},
      "is_aigc" => post.is_aigc == true,
      "ai_disclosure" => post.ai_disclosure
    }
  end

  # ── approve_version/4 ────────────────────────────────────────────────

  @doc """
  Approves the version the caller saw (`expect` = `%{state_rev:, version:}`,
  optionally `fingerprint:` the `Approvals.content_fingerprint/1` shown).
  `needs_approval` to `approved`: one `current` receipt for this version and
  account, the post's approver columns, `approved` event. It is NOT planning
  (`scheduled_at` stays nil) and never sends.

  On an `approved` or `planned` post it is the re-approval after an authority change: allowed
  only when the current receipt's approver no longer passes the approver check
  (authority changed); the old receipt becomes `superseded` ("authority
  changed"), any plan is cleared with `plan_cancelled`, and the status ends
  `approved`. When the receipt's authority is intact it answers
  `{:error, :already_approved}`.

  Errors: the check-order refusals, `{:stale, _}`, `:expect_required`,
  `:not_awaiting_approval`, `:already_approved`.
  """
  @spec approve_version(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect()) ::
          {:ok, %{post: Post.t(), approval: PostApproval.t()}} | {:error, error()}
  def approve_version(org_id, post_id, user_id, expect) do
    actor = human(user_id)

    write(org_id, post_id, actor, expect, [actor_check: &approver_actor/1], fn ctx ->
      fingerprint = Approvals.content_fingerprint(ctx.post)

      cond do
        Map.get(ctx.expect, :fingerprint) not in [nil, fingerprint] ->
          stale(ctx.post)

        ctx.post.status == "needs_approval" ->
          {:ok, approve!(ctx, fingerprint, nil)}

        ctx.post.status in ~w(approved planned) ->
          receipt = current_receipt(ctx.post)

          if receipt_authority?(ctx, receipt),
            do: {:error, :already_approved},
            else: {:ok, approve!(ctx, fingerprint, receipt)}

        true ->
          {:error, :not_awaiting_approval}
      end
    end)
  end

  defp approve!(ctx, fingerprint, old_receipt) do
    %{post: post, actor: actor} = ctx
    user_id = actor_id(actor)

    if old_receipt, do: end_receipt!(old_receipt, "superseded", actor, "authority changed")

    receipt =
      %PostApproval{}
      |> PostApproval.changeset(%{
        post_id: post.id,
        version: post.version,
        account_id: post.account_id,
        approved_by_user_id: user_id,
        approved_at: DateTime.utc_now(),
        state: "current",
        content_fingerprint: fingerprint,
        snapshot: snapshot(post)
      })
      |> Repo.insert!()

    was_planned? = post.status == "planned"

    updated =
      bump(
        post,
        [status: "approved", approved_by_user_id: user_id, approved_at: receipt.approved_at] ++
          @clear_plan
      )

    PostEvents.record!(updated, "approved", actor, note: if(old_receipt, do: "authority changed"))

    if was_planned? do
      PostEvents.record!(updated, "plan_cancelled", actor, note: "authority changed")
    end

    %{post: updated, approval: receipt}
  end

  # ── plan_post/4,5 and cancel_plan/4 ──────────────────────────────────

  @doc """
  Plans (or replans) an approved post inside Burrow at a future UTC time.
  `planned_at` is the last argument or `expect.planned_at`. Needs (a) the actor
  and (b) the current receipt's approver to pass the approver check now
  (`{:error, :approval_needs_refresh}` otherwise, nothing changed). Writes
  `planned` (note: the previous time on a replan). Nothing is sent.

  Errors: the check-order refusals, `{:stale, _}`, `:not_approved`,
  `:approval_needs_refresh`, `:invalid_time`, `:time_in_past`.
  """
  @spec plan_post(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect(), term()) ::
          {:ok, %{post: Post.t(), approval: PostApproval.t()}} | {:error, error()}
  def plan_post(org_id, post_id, user_id, expect, planned_at \\ nil) do
    planned_at = planned_at || (is_map(expect) && Map.get(expect, :planned_at))
    actor = human(user_id)

    write(org_id, post_id, actor, expect, [actor_check: &approver_actor/1], fn ctx ->
      post = ctx.post
      receipt = if post.status in ~w(approved planned), do: current_receipt(post)

      cond do
        is_nil(receipt) or receipt.version != post.version or
            receipt.account_id != post.account_id ->
          {:error, :not_approved}

        not receipt_authority?(ctx, receipt) ->
          {:error, :approval_needs_refresh}

        true ->
          with {:ok, at} <- future_time(planned_at) do
            updated =
              bump(post,
                status: "planned",
                scheduled_at: at,
                planned_by_user_id: actor_id(actor),
                planned_set_at: DateTime.utc_now()
              )

            note =
              if post.status == "planned",
                do: "previous time: " <> DateTime.to_iso8601(post.scheduled_at)

            PostEvents.record!(updated, "planned", actor, note: note)
            {:ok, %{post: updated, approval: receipt}}
          end
      end
    end)
  end

  defp future_time(%DateTime{} = dt) do
    at = dt |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)

    if DateTime.compare(at, DateTime.utc_now()) == :gt,
      do: {:ok, at},
      else: {:error, :time_in_past}
  end

  defp future_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> future_time(dt)
      _ -> {:error, :invalid_time}
    end
  end

  defp future_time(_), do: {:error, :invalid_time}

  @doc """
  Cancels a plan: `planned` back to `approved`, the receipt stays `current`,
  `scheduled_at` and the plan columns are cleared, `plan_cancelled` is written.
  The actor needs `Social.post_rejecter_check/4` only: with a live owner
  that is the owner alone; a profile approver passes only once the owner is
  archived or gone. Allowed on an archived account. Cancelling never
  grants approve or plan authority.

  Errors: the check-order refusals, `{:stale, _}`, `:not_planned`.
  """
  @spec cancel_plan(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect()) ::
          {:ok, Post.t()} | {:error, error()}
  def cancel_plan(org_id, post_id, user_id, expect) do
    actor = human(user_id)

    opts = [actor_check: &rejecter_actor/1, archived: fn _ -> :allow end]

    write(org_id, post_id, actor, expect, opts, fn ctx ->
      if ctx.post.status == "planned" do
        updated = bump(ctx.post, [status: "approved"] ++ @clear_plan)
        PostEvents.record!(updated, "plan_cancelled", actor)
        {:ok, updated}
      else
        {:error, :not_planned}
      end
    end)
  end

  # ── revoke_approval/4,5, request_changes/4,5, resubmit/4,5 ───────────

  @doc """
  Withdraws the current approval of the SAME version: `approved` or `planned`
  back to `needs_approval`. `expect.approval_id` names the receipt the caller
  saw; a different (or no) current receipt is `{:error, :approval_not_current}`.
  The receipt becomes `revoked`. Writes `approval_revoked` (note: reason) and,
  when a plan existed, `plan_cancelled`.
  """
  @spec revoke_approval(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect(), String.t() | nil) ::
          {:ok, Post.t()} | {:error, error()}
  def revoke_approval(org_id, post_id, user_id, expect, reason \\ nil) do
    reason = reason || (is_map(expect) && Map.get(expect, :reason))
    actor = human(user_id)

    write(org_id, post_id, actor, expect, [actor_check: &approver_actor/1], fn ctx ->
      receipt = current_receipt(ctx.post)

      if receipt && receipt.id == Map.get(ctx.expect, :approval_id) &&
           ctx.post.status in ~w(approved planned) do
        end_receipt!(receipt, "revoked", actor, reason || "revoked")
        was_planned? = ctx.post.status == "planned"
        updated = bump(ctx.post, [status: "needs_approval"] ++ @clear_approval ++ @clear_plan)
        PostEvents.record!(updated, "approval_revoked", actor, note: reason)
        if was_planned?, do: PostEvents.record!(updated, "plan_cancelled", actor)
        {:ok, updated}
      else
        {:error, :approval_not_current}
      end
    end)
  end

  @doc """
  `needs_approval` to `draft` with the reason on the post (`Post.rejected?/1`).
  Writes `rejected` (note: reason). A blank reason is `:reason_required`.
  """
  @spec request_changes(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect(), String.t() | nil) ::
          {:ok, Post.t()} | {:error, error()}
  def request_changes(org_id, post_id, user_id, expect, reason \\ nil) do
    reason = reason || (is_map(expect) && Map.get(expect, :reason))
    actor = human(user_id)

    write(org_id, post_id, actor, expect, [actor_check: &approver_actor/1], fn ctx ->
      with :ok <-
             if(ctx.post.status == "needs_approval",
               do: :ok,
               else: {:error, :not_awaiting_approval}
             ),
           {:ok, changed} <- reject_changes(ctx.post, reason) do
        updated =
          changed
          |> Ecto.Changeset.put_change(:state_rev, ctx.post.state_rev + 1)
          |> Repo.update!()

        PostEvents.record!(updated, "rejected", actor, note: updated.rejection_reason)
        {:ok, updated}
      end
    end)
  end

  defp reject_changes(post, reason) do
    changeset = Post.reject_changeset(post, reason)
    if changeset.valid?, do: {:ok, changeset}, else: {:error, :reason_required}
  end

  @doc """
  Plain submit: any Studio `draft`, rejected or never
  rejected, to `needs_approval`. It is the "Submit for approval" button on a
  fresh draft and "Resubmit for approval" after requested changes.

  Human only: `user_id` is decided by the account-approver check under the
  locks (an agent id is `:not_a_human`); no agent can submit. Same `expect`
  (`state_rev` and `version`) and stale shape as every transition. Writes the
  `submitted` event (note: response), bumps `state_rev`, keeps `version`, and
  clears `rejection_reason` and `rejected_at` when there were any (the
  `rejected` event stays in the history). It creates no approval and no plan.

  A post that is not a `draft` is `{:error, :not_a_draft}`. `:not_rejected` is
  no longer a result.
  """
  @spec resubmit(Ecto.UUID.t(), Ecto.UUID.t(), term(), expect(), String.t() | nil) ::
          {:ok, Post.t()} | {:error, error()}
  def resubmit(org_id, post_id, user_id, expect, response \\ nil) do
    response = response || (is_map(expect) && Map.get(expect, :response))
    actor = human(user_id)

    write(org_id, post_id, actor, expect, [actor_check: &approver_actor/1], fn ctx ->
      if ctx.post.status == "draft" do
        updated =
          bump(ctx.post, status: "needs_approval", rejection_reason: nil, rejected_at: nil)

        PostEvents.record!(updated, "submitted", actor, note: response)
        {:ok, updated}
      else
        {:error, :not_a_draft}
      end
    end)
  end

  # ── accept_render/4 ──────────────────────────────────────────────────

  @doc """
  Creative acceptance of one render of a STUDIO clip into Studio posts, one per
  destination account. Each new post is `needs_approval`, version 1, bound to
  `clip_render_id`, with `accepted_account_id` = its first destination; no
  approval, no `publish_after`, no timer. Writes `created` and `submitted` per
  NEW post. The clip's own review fields are not touched.

  `attrs` is `%{render_id:, account_ids:}`. All or nothing, one transaction.
  Locks: profile `FOR SHARE`, then every requested account
  `FOR SHARE` in ascending id order (plus the current account of an existing
  post it replays: found in a first pass that then ENDS its transaction, and
  locked by a second, new transaction that takes the profile, then both
  accounts ascending, then the clip, and decides everything again; at most one
  restart, and a destination that changed again is the stale shape),
  then the clip `FOR UPDATE`. Every decision is made on those locked rows.

  Each requested destination is decided independently, in the check order:
  scoped load (`:not_found`, for an unknown id and for an account of
  another profile alike), `:account_archived`,
  the actor (`post_approver_check/4`, then project, module lock and
  `social.use`), and only for an authorised destination the lookup of the
  acceptance key (render, account), then `:duplicate_destination` last. A
  caller with no authority on a destination learns nothing about its posts.

  A replayed post is locked `FOR UPDATE` (last, after the profile, the accounts
  and the clip) when it is found, and the post returned is that locked row, so
  the destination the actor was authorised for is the destination returned: a
  concurrent retarget waits for the replay.

  Idempotent on the immutable pair (render, `accepted_account_id`): an account
  that already has a post for this render, even one since retargeted
  elsewhere, gets that post back unchanged and nothing is written for it.
  When that post now sits on another account B, the actor must pass the same
  checks (archived, approver, project) for B too; if not the destination is
  refused with B's reason and no post or id is returned. A destination with no
  such post that is already the CURRENT account of another post of this render
  is `:duplicate_destination`.

  If any destination is refused nothing is created and no event is written:
  `{:error, {:destinations, [%{account_id: id, reason: reason}]}}`, every
  refused destination, ascending by `account_id`, whatever the order of
  `account_ids`. A single destination uses the same envelope. Other errors:
  `:no_accounts`, `:legacy_clip`, `:render_not_found` and the gate refusals
  (`:studio_disabled`, `:not_found`).

  Returns `{:ok, %{clip: clip, posts: posts}}`, `posts` ascending by the
  requested account id.
  """
  @spec accept_render(Ecto.UUID.t(), Ecto.UUID.t(), term(), map()) ::
          {:ok, %{clip: Clip.t(), posts: [Post.t()]}}
          | {:error, error() | {:destinations, [%{account_id: term(), reason: term()}]}}
          | {:error, Ecto.Changeset.t()}
  def accept_render(org_id, clip_id, user_id, attrs) when is_map(attrs) do
    render_id = Map.get(attrs, :render_id) || Map.get(attrs, "render_id")
    account_ids = Map.get(attrs, :account_ids) || Map.get(attrs, "account_ids")

    with {:ok, clip_uuid} <- cast_id(clip_id),
         %Clip{} = clip0 <- Social.get_clip(org_id, clip_uuid) || {:error, :not_found},
         %Profile{} = profile0 <-
           Social.get_profile(org_id, clip0.profile_id) || {:error, :not_found},
         # Early refusals only; the decisions of record are made under the locks.
         :ok <- require_enabled(profile0),
         :ok <- require_studio_clip(clip0),
         {:ok, requested} <- requested_ids(account_ids) do
      accept_attempt(org_id, clip0, profile0, user_id, render_id, requested, [], false)
    end
  end

  defp requested_ids(ids) when is_list(ids) and ids != [] do
    {:ok, ids |> Enum.map(&normalize_id/1) |> Enum.uniq() |> Enum.sort()}
  end

  defp requested_ids(_), do: {:error, :no_accounts}

  defp normalize_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> to_string(id)
    end
  end

  # One pass is one transaction. A replay that finds its post now sits on an
  # account it has not locked ends the pass (committing it, so every lock is
  # released) and starts exactly one more, new transaction that locks the
  # profile, then every needed account ascending, then the clip, and decides
  # everything again. If that second pass finds the post on
  # yet another unlocked account, the destination changed again: stale.
  defp accept_attempt(org_id, clip0, profile0, user_id, render_id, requested, hint, restarted?) do
    result =
      Repo.transaction(fn ->
        profile = Social.lock_profile(org_id, profile0, :share) || Repo.rollback(:not_found)
        locked = lock_accounts_in_order(profile, requested ++ hint)
        clip = lock_clip(clip0.id) || Repo.rollback(:not_found)

        with :ok <- require_enabled(profile),
             :ok <- require_studio_clip(clip) do
          case decide_destinations(org_id, profile, locked, requested, user_id, render_id) do
            {:need_accounts, ids, _post} when not restarted? ->
              {:retry, ids}

            {:need_accounts, _ids, post} ->
              Repo.rollback({:stale, %{state_rev: post.state_rev, version: post.version}})

            {:refused, failures} ->
              Repo.rollback({:destinations, failures})

            {:ok, existing} ->
              with {:ok, render} <- accept_render_row(clip, render_id) do
                posts =
                  Enum.map(requested, fn id ->
                    accept_one!(Map.fetch!(locked, id), existing, clip, render, profile, user_id)
                  end)

                %{clip: Repo.get!(Clip, clip.id), posts: posts}
              else
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {:retry, ids}} ->
        accept_attempt(
          org_id,
          clip0,
          profile0,
          user_id,
          render_id,
          requested,
          Enum.uniq(hint ++ ids),
          true
        )

      other ->
        other
    end
  end

  # One decision per requested destination, on the locked rows. Returns
  # `{:ok, existing}` (`%{account_id => post}` replays), `{:refused, failures}`
  # (ascending by account id) or `{:need_accounts, ids, post}` when an existing
  # post sits on an account that is not locked yet.
  defp decide_destinations(org_id, profile, locked, requested, user_id, render_id) do
    steps =
      Enum.map(requested, &decide_destination(org_id, profile, locked, &1, user_id, render_id))

    missing =
      for {:need_account, id, post} <- steps, not Map.has_key?(locked, id), do: {id, post}

    cond do
      missing != [] ->
        {:need_accounts, missing |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
         missing |> hd() |> elem(1)}

      true ->
        failures =
          for {id, {:error, reason}} <- Enum.zip(requested, steps),
              do: %{account_id: id, reason: reason}

        if failures == [] do
          {:ok,
           for({id, {:replay, post}} <- Enum.zip(requested, steps), into: %{}, do: {id, post})}
        else
          {:refused, failures}
        end
    end
  end

  # The check order for one destination: scoped, archived, actor, then the acceptance key,
  # then `:duplicate_destination` last.
  defp decide_destination(org_id, profile, locked, id, user_id, render_id) do
    with {:ok, account} <- accept_scoped(org_id, locked, id),
         :ok <- require_live(account),
         :ok <- accept_actor(org_id, profile, account, user_id) do
      case existing_post(render_id, account) do
        nil ->
          if render_destination_taken?(render_id, account),
            do: {:error, :duplicate_destination},
            else: :new

        %Post{account_id: current} = post when current == account.id ->
          accept_replay(post)

        %Post{account_id: current} = post ->
          case Map.fetch(locked, current) do
            {:ok, current_account} ->
              with :ok <- require_live(current_account),
                   :ok <- accept_actor(org_id, profile, current_account, user_id) do
                accept_replay(post)
              end

            :error ->
              {:need_account, current, post}
          end
      end
    end
  end

  defp accept_replay(%Post{discarded_at: %DateTime{}}), do: {:error, :draft_discarded}
  defp accept_replay(%Post{} = post), do: {:replay, post}

  defp accept_scoped(_org_id, locked, id) do
    case Map.fetch(locked, id) do
      {:ok, account} ->
        {:ok, account}

      # Not locked: no such account, or an account of another profile. One
      # answer for both, so a caller cannot learn an id exists elsewhere.
      :error ->
        {:error, :not_found}
    end
  end

  defp accept_actor(org_id, profile, account, user_id) do
    with :ok <- Social.post_approver_check(org_id, profile, account, user_id) do
      authorize_studio_actor(profile, user_id)
    end
  end

  # The post holding the acceptance key (render, accepted account), wherever it
  # points now, LOCKED `FOR UPDATE` (last in the lock order: profile, accounts
  # ascending, then the post). The destination decision and the post returned
  # are therefore the same locked row: a concurrent retarget waits for this
  # transaction instead of moving the post between the check and the return.
  # Only called for a destination the actor is authorised for.
  defp existing_post(render_id, %Account{id: account_id}) do
    case Ecto.UUID.cast(render_id) do
      {:ok, rid} ->
        Repo.one(
          from(p in Post,
            where:
              p.flow == "studio" and p.clip_render_id == ^rid and
                p.accepted_account_id == ^account_id,
            lock: "FOR UPDATE"
          )
        )

      :error ->
        nil
    end
  end

  defp render_destination_taken?(render_id, %Account{id: account_id}) do
    case Ecto.UUID.cast(render_id) do
      {:ok, rid} ->
        Repo.exists?(
          from(p in Post,
            where: p.flow == "studio" and p.clip_render_id == ^rid and p.account_id == ^account_id
          )
        )

      :error ->
        false
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp require_studio_clip(%Clip{flow: "studio"}), do: :ok
  defp require_studio_clip(%Clip{}), do: {:error, :legacy_clip}

  defp lock_clip(id),
    do: Repo.one(from(c in Clip, where: c.id == ^id and is_nil(c.removed_at), lock: "FOR UPDATE"))

  defp accept_render_row(%Clip{id: clip_id}, render_id) do
    with {:ok, rid} <- Ecto.UUID.cast(render_id),
         %ClipRender{file_id: file_id} = render when is_binary(file_id) <-
           Repo.one(
             from(r in ClipRender,
               where: r.id == ^rid and r.clip_id == ^clip_id and is_nil(r.removed_at)
             )
           ) do
      {:ok, render}
    else
      _ -> {:error, :render_not_found}
    end
  end

  defp accept_one!(account, existing, clip, render, profile, user_id) do
    case Map.fetch(existing, account.id) do
      # the row locked while its destination was decided, never a reload
      {:ok, post} -> post
      :error -> insert_accepted!(account, clip, render, profile, user_id)
    end
  end

  defp insert_accepted!(account, clip, render, profile, user_id) do
    start_s = render.actual_start_s || clip.start_s
    link = Links.effective_link(nil, profile.home_url, clip.source_url, start_s)
    caption = render.caption || clip.caption

    attrs = %{
      "status" => "needs_approval",
      "body" => Links.append_to_body(caption, link),
      "link_url" => link,
      "media_file_ids" => [render.file_id],
      "media_meta" => %{
        render.file_id => %{
          "duration_s" => render.duration_s,
          "width" => render.width,
          "height" => render.height
        }
      }
    }

    changeset =
      %Post{
        account_id: account.id,
        flow: "studio",
        clip_id: clip.id,
        clip_render_id: render.id,
        accepted_account_id: account.id
      }
      |> Post.studio_create_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, post} ->
        PostEvents.record!(post, "created", {:human, user_id})
        PostEvents.record!(post, "submitted", {:human, user_id})
        post

      {:error, changeset} ->
        # Decided already (and the clip lock serialises acceptances), so this is
        # the unique index as a last line only; it uses the same envelope.
        Repo.rollback(
          if(Post.duplicate_destination?(changeset),
            do: {:destinations, [%{account_id: account.id, reason: :duplicate_destination}]},
            else: changeset
          )
        )
    end
  end

  # ── save_version/5 ───────────────────────────────────────────────────

  @doc """
  The ONLY content writer for a Studio row: a new `version` of the post.

  `actor` is `{:human, user_id}` (a bare user id means the same) or
  `{:agent, agent_id}`. `attrs` may carry the content fields
  (`#{inspect(Post.studio_content_fields())}`) and `account_id` (a retarget).
  Any other key is `{:error, {:field_not_allowed, keys}}` and nothing is read.
  Nothing to change is `{:error, :no_changes}`.

  Always: `version` +1, `state_rev` +1, `edited` (body before/after, only when
  the body changed) or `retargeted` (note: old and new account), then
  `version_saved`. On an `approved` or `planned` post (humans only) the current
  receipt is superseded, the post returns to `needs_approval` with its approver
  and plan columns cleared, and `approval_revoked` (and `plan_cancelled` when
  planned) follow: the server revokes whatever the UI warned. `draft` stays
  `draft`.

  Agents may write only in `draft` and `needs_approval` (`:post_locked`
  otherwise) and never retarget (`:agent_cannot_retarget`).

  Retarget: the actor passes the approver check on the NEW account (which must
  be live, in the same profile: otherwise `:not_found`) and on the OLD one,
  or, when the old account is archived, the rejecter check. A render's
  destination that already holds a post is `{:error, :duplicate_destination}`.
  A new approval is always needed.

  Returns `{:ok, %{post:, version:, revoked_approval:, cancelled_plan?:}}`.
  """
  @spec save_version(Ecto.UUID.t(), Ecto.UUID.t(), term(), map(), expect()) ::
          {:ok, map()}
          | {:error, error() | {:field_not_allowed, [String.t()]} | Ecto.Changeset.t()}
  def save_version(org_id, post_id, actor, attrs, expect) do
    actor = normalize_actor(actor)

    with {:ok, attrs} <- normalize_save_attrs(attrs) do
      opts = [
        actor_check: fn ctx -> save_actor(ctx, attrs) end,
        archived: fn ctx -> if retarget?(ctx.post, attrs), do: :allow, else: :refuse end,
        extra_accounts: fn _post -> List.wrap(attrs["account_id"]) end
      ]

      write(org_id, post_id, actor, expect, opts, fn ctx -> do_save(ctx, attrs) end)
    end
  end

  defp normalize_actor({:human, _} = actor), do: actor
  defp normalize_actor({:agent, _} = actor), do: actor
  defp normalize_actor(user_id), do: {:human, user_id}

  @save_keys Enum.map(Post.studio_content_fields(), &Atom.to_string/1) ++ ["account_id"]

  defp normalize_save_attrs(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Map.keys(attrs) -- @save_keys do
      [] -> {:ok, attrs}
      keys -> {:error, {:field_not_allowed, Enum.sort(keys)}}
    end
  end

  defp normalize_save_attrs(_), do: {:error, {:field_not_allowed, []}}

  defp retarget?(%Post{account_id: current}, %{"account_id" => id}) when is_binary(id),
    do: id != current

  defp retarget?(_post, _attrs), do: false

  # Agents: draft/needs_approval only, never a retarget, and (every Studio
  # write) on a live same-org project, decided on the LOCKED profile row. No
  # approver or `social.use` check: those are human-only. Humans: (a) on the
  # post's account, and on a retarget also (a) on the new account.
  defp save_actor(%{actor: {:agent, _}} = ctx, attrs) do
    cond do
      ctx.post.status not in ~w(draft needs_approval) ->
        {:error, :post_locked}

      retarget?(ctx.post, attrs) ->
        {:error, :agent_cannot_retarget}

      true ->
        with {:ok, _project_id} <- require_studio_project(ctx.profile), do: :ok
    end
  end

  defp save_actor(%{actor: {:human, user_id}} = ctx, attrs) do
    if retarget?(ctx.post, attrs) do
      with {:ok, new_account} <- target_account(ctx, attrs),
           :ok <- old_account_check(ctx),
           :ok <-
             Social.post_approver_check(ctx.org_id, ctx.profile, new_account, user_id) do
        authorize_studio_actor(ctx.profile, user_id)
      end
    else
      approver_actor(ctx)
    end
  end

  # An archived old account is checked with the rejecter rule, so a gone
  # owner does not strand the post; a live account with the approver rule.
  defp old_account_check(%{account: %Account{archived_at: nil}} = ctx),
    do: approver_check_only(ctx)

  defp old_account_check(ctx), do: rejecter_check_only(ctx)

  defp approver_check_only(%{actor: {:human, id}} = ctx),
    do: Social.post_approver_check(ctx.org_id, ctx.profile, ctx.account, id)

  defp rejecter_check_only(%{actor: {:human, id}} = ctx),
    do: Social.post_rejecter_check(ctx.org_id, ctx.profile, ctx.account, id)

  # The retarget's new account, from the rows locked in `write/6` (the profile,
  # then both accounts in id order, then the post). An id that is no account of
  # this profile is `:not_found`, whether or not it exists elsewhere.
  defp target_account(ctx, %{"account_id" => id}) do
    with {:ok, id} <- Ecto.UUID.cast(id) |> or_not_found(),
         {:ok, new} <- locked_target(ctx, id),
         :ok <- require_live(new) do
      {:ok, new}
    end
  end

  defp locked_target(ctx, id) do
    case Map.fetch(ctx.accounts, id) do
      {:ok, account} ->
        {:ok, account}

      # Same rule as `accept_render`: no such account and an account of
      # another profile are both `:not_found`.
      :error ->
        {:error, :not_found}
    end
  end

  defp or_not_found({:ok, id}), do: {:ok, id}
  defp or_not_found(:error), do: {:error, :not_found}

  defp do_save(ctx, attrs) do
    %{post: post, actor: actor} = ctx
    retarget? = retarget?(post, attrs)

    with {:ok, options} <- clean_options(ctx, attrs, retarget?),
         {:ok, changes} <-
           Post.studio_content_changes(
             post,
             put_options(attrs, options),
             %{org_id: ctx.org_id, profile_id: ctx.profile.id}
           )
           |> changeset_error(),
         :ok <- something_to_save(changes, retarget?),
         {:ok, new_account} <- new_account(ctx, attrs, retarget?),
         :ok <- no_duplicate_destination(post, new_account) do
      apply_version!(ctx, changes, new_account, actor)
    end
  end

  defp changeset_error({:ok, _} = ok), do: ok
  defp changeset_error({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}

  defp something_to_save(changes, retarget?),
    do: if(map_size(changes) == 0 and not retarget?, do: {:error, :no_changes}, else: :ok)

  # Platform options are validated for the account the post will be on.
  defp clean_options(_ctx, attrs, _retarget) when not is_map_key(attrs, "platform_options"),
    do: {:ok, nil}

  defp clean_options(ctx, attrs, retarget?) do
    platform =
      if retarget? do
        case Ecto.UUID.cast(attrs["account_id"]) do
          {:ok, id} ->
            case Map.get(ctx.accounts, id) do
              %Account{platform: platform} -> platform
              _ -> ctx.account.platform
            end

          :error ->
            ctx.account.platform
        end
      else
        ctx.account.platform
      end

    case Platform.Social.PlatformOptions.validate(platform, attrs["platform_options"] || %{}) do
      {:ok, clean} -> {:ok, clean}
      {:error, errors} -> {:error, {:invalid_options, errors}}
    end
  end

  defp put_options(attrs, nil), do: attrs
  defp put_options(attrs, options), do: Map.put(attrs, "platform_options", options)

  defp new_account(_ctx, _attrs, false), do: {:ok, nil}

  defp new_account(ctx, attrs, true), do: target_account(ctx, attrs)

  defp no_duplicate_destination(_post, nil), do: :ok
  defp no_duplicate_destination(%Post{clip_render_id: nil}, _new), do: :ok

  defp no_duplicate_destination(%Post{} = post, %Account{id: new_id}) do
    taken? =
      Repo.exists?(
        from(p in Post,
          where:
            p.flow == "studio" and p.clip_render_id == ^post.clip_render_id and
              p.account_id == ^new_id and p.id != ^post.id
        )
      )

    if taken?, do: {:error, :duplicate_destination}, else: :ok
  end

  defp apply_version!(ctx, changes, new_account, actor) do
    %{post: post} = ctx
    receipt = if post.status in ~w(approved planned), do: current_receipt(post)
    was_planned? = post.status == "planned"
    revoke? = post.status in ~w(approved planned)

    ended =
      if receipt,
        do:
          end_receipt!(
            receipt,
            "superseded",
            actor,
            if(new_account, do: "account changed", else: "version changed")
          )

    base =
      changes
      |> Map.to_list()
      |> then(&(&1 ++ [version: post.version + 1]))
      |> then(&if(new_account, do: &1 ++ [account_id: new_account.id], else: &1))
      |> then(
        &if(revoke?,
          do: &1 ++ [status: "needs_approval"] ++ @clear_approval ++ @clear_plan,
          else: &1
        )
      )

    updated =
      post
      |> Ecto.Changeset.change(Keyword.put(base, :state_rev, post.state_rev + 1))
      |> Ecto.Changeset.unique_constraint(:account_id,
        name: :social_posts_studio_destination_key,
        message: "duplicate_destination"
      )
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Repo.rollback(
            if(Post.duplicate_destination?(changeset),
              do: :duplicate_destination,
              else: changeset
            )
          )
      end

    if Map.has_key?(changes, :body) do
      PostEvents.record!(updated, "edited", actor,
        body_before: post.body,
        body_after: updated.body
      )
    end

    if new_account do
      PostEvents.record!(updated, "retargeted", actor,
        note: "account #{post.account_id} -> #{new_account.id}"
      )
    end

    PostEvents.record!(updated, "version_saved", actor)

    if revoke? do
      PostEvents.record!(updated, "approval_revoked", actor,
        version: post.version,
        account_id: post.account_id
      )
    end

    if was_planned? do
      PostEvents.record!(updated, "plan_cancelled", actor,
        version: post.version,
        account_id: post.account_id
      )
    end

    {:ok,
     %{
       post: updated,
       version: updated.version,
       revoked_approval: ended,
       cancelled_plan?: was_planned?
     }}
  end

  @doc """
  A Studio post's receipts, newest first, `{:ok, [PostApproval]}` (check order
  1 to 3; a read, so no actor).
  """
  @spec list_approvals(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [PostApproval.t()]} | {:error, error()}
  def list_approvals(org_id, post_id) do
    with {:ok, post} <- get_post(org_id, post_id) do
      {:ok,
       Repo.all(
         from(a in PostApproval,
           where: a.post_id == ^post.id,
           order_by: [desc: a.approved_at, desc: a.id]
         )
       )}
    end
  end

  defp require_live(%Account{archived_at: nil}), do: :ok
  defp require_live(%Account{}), do: {:error, :account_archived}
end
