defmodule Platform.Social.Studio do
  @moduledoc """
  Social Studio: the context for posts that are planned inside Burrow and
  never sent. Slice A holds the
  basics only: enablement, create and read. Approval, planning and versioned
  edits are slice B's.

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
  6. stale tokens (slice B).

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
  alias Platform.Social.{Account, Post, PostEvents, Profile}

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

  @doc "Reads one Studio post in the caller's org (check order 1 to 3)."
  @spec get_post(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Post.t()} | {:error, error()}
  def get_post(org_id, post_id) do
    with %Post{} = post <- Social.get_post(org_id, post_id) || {:error, :not_found},
         {:ok, profile} <- Social.profile_of_post(post),
         :ok <- require_enabled(profile),
         :ok <- require_studio(post) do
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
           where: a.profile_id == ^profile.id and po.flow == "studio",
           order_by: [asc: po.inserted_at, asc: po.id]
         )
       )}
    end
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

  defp require_live(%Account{archived_at: nil}), do: :ok
  defp require_live(%Account{}), do: {:error, :account_archived}
end
