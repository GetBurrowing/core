defmodule Platform.Social do
  @moduledoc """
  Social's context (task 01a140a8, Social 1/7): CRUD for profiles, accounts,
  posts and clips, every call scoped to the caller's org.

  ## Org scoping

  Every function takes the caller's `org_id` first. A row belongs to the org
  of its profile (`social_profiles.org_id`); accounts, posts and clips join
  up to it. All reads AND writes go through `scoped_query/2`, which is built
  from ONE decision, `visible_orgs/1` (marked `RBAC SWAP POINT`), so moving
  to the Platform.Access query API once it lands on main is one edit. The
  "org id" may also be core's agent home-org shape, `:root` or
  `{:tenant, org_id}` (Social 4/7). A row in another org is indistinguishable
  from a missing id: `get_*` answers `nil`, `list_*` omits it, and every
  write answers `{:error, :not_found}`.

  ## No secret

  `secret_slug` is set here, never cast: `"social:<account_id>"`. It is
  inert data and no secret is read from it: the Zernio API key is
  install-level, one Vault row at slug `"social:zernio:api_key"`, scope
  `{:integration, nil}`, owned by `Platform.Social.Secrets` (task 01a14722).

  ## Approver guard

  `approve_post/3` is the only path that sets `approved_by_user_id` /
  `approved_at`. It looks the id up through `Platform.Accounts.get_user/1`
  and refuses anything that is not a user (an agent id included) with
  "must be a human user"; the FK to `users` is the second layer. Profile
  `approver_user_ids` get the same check on write. Whether the approver is
  in the profile's list is Social 3/7's rule.

  ## Project for renders (task 01a16532)

  A profile's clip renders are stored as files in its project. A new
  profile without an explicit `project_id` takes
  `default_render_project_id/1`: the org's only non-archived project, or
  the first by name (then id). An org with no projects leaves it nil. No
  project is ever created for this: a silently created project clutters
  the project switcher (design canvas 01a16763-cfb1, rule 5), so the
  ticket's "or create a Social project" option was dropped.
  `set_profile_project/4` is the approver-only way to correct it; there
  is no agent tool for it.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Platform.Repo

  alias Platform.Social.{
    Account,
    Clip,
    ClipMedia,
    ConnectInvite,
    Post,
    Profile,
    Publisher,
    RenderQueue
  }

  @not_a_user "must be a human user"

  # ── Scoping ──────────────────────────────────────────────────────────

  @typedoc """
  Who is asking. A bare org id (member 1's callers), or core's agent home-org
  shape: `:root` (an unpinned or root-pinned agent, every org) or
  `{:tenant, org_id}` (one org). Anything else sees nothing.
  """
  @type scope :: Ecto.UUID.t() | :root | {:tenant, Ecto.UUID.t()}

  @doc """
  RBAC SWAP POINT: the ONE authorization decision in Social. Answers which
  orgs a scope may read and write: `:all` or a list of org ids (empty means
  nothing). Every scoped read and write (`scoped_query/2`), the agent draft
  path (`Platform.Social.AgentDrafts`) and the agent tools' `org_id` filter
  (`org_visible?/2`) derive from it, so moving to Platform.Access's
  owner-capped `%Scope{}` once it lands on main is one edit here. A non-UUID
  org id matches nothing.
  """
  @spec visible_orgs(scope() | term()) :: :all | [Ecto.UUID.t()]
  def visible_orgs(:root), do: :all
  def visible_orgs({:tenant, org_id}), do: visible_orgs(org_id)

  def visible_orgs(org_id) when is_binary(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, org_id} -> [org_id]
      :error -> []
    end
  end

  def visible_orgs(_), do: []

  @doc "Whether `scope` may see rows in `org_id` (derived from `visible_orgs/1`)."
  @spec org_visible?(scope() | term(), term()) :: boolean()
  def org_visible?(scope, org_id) do
    case {visible_orgs(scope), Ecto.UUID.cast(org_id)} do
      {_, :error} -> false
      {:all, {:ok, _}} -> true
      {orgs, {:ok, org_id}} -> org_id in orgs
    end
  end

  # The one org filter every read and write in this module goes through,
  # built from `visible_orgs/1`.
  defp scoped_query(schema, scope) do
    case visible_orgs(scope) do
      :all -> from(x in schema)
      [] -> where(schema, false)
      org_ids -> org_filter(schema, org_ids)
    end
  end

  defp org_filter(Profile, org_ids), do: where(Profile, [p], p.org_id in ^org_ids)

  defp org_filter(Account, org_ids) do
    from(a in Account,
      join: p in Profile,
      on: p.id == a.profile_id,
      where: p.org_id in ^org_ids
    )
  end

  defp org_filter(Clip, org_ids) do
    from(c in Clip, join: p in Profile, on: p.id == c.profile_id, where: p.org_id in ^org_ids)
  end

  defp org_filter(Post, org_ids) do
    from(po in Post,
      join: a in Account,
      on: a.id == po.account_id,
      join: p in Profile,
      on: p.id == a.profile_id,
      where: p.org_id in ^org_ids
    )
  end

  defp scoped_get(schema, org_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> schema |> scoped_query(org_id) |> where([x], x.id == ^id) |> Repo.one()
      :error -> nil
    end
  end

  # Writes re-read the row through the scope, so a struct from another org
  # (or a stale one) is refused exactly like a missing id.
  defp fetch(schema, org_id, %{id: id}), do: fetch(schema, org_id, id)

  defp fetch(schema, org_id, id) do
    case scoped_get(schema, org_id, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # ── Profiles ─────────────────────────────────────────────────────────

  @spec get_profile(Ecto.UUID.t(), Ecto.UUID.t()) :: Profile.t() | nil
  def get_profile(org_id, id), do: scoped_get(Profile, org_id, id)

  @spec list_profiles(Ecto.UUID.t()) :: [Profile.t()]
  def list_profiles(org_id),
    do: Profile |> scoped_query(org_id) |> order_by([p], asc: p.name) |> Repo.all()

  @doc """
  Creates a profile in `org_id`. When `attrs` carry no `project_id` key
  (atom or string), the project defaults to
  `default_render_project_id/1`; an explicit `project_id` (nil included)
  wins and is still validated against the org.
  """
  @spec create_profile(Ecto.UUID.t(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def create_profile(org_id, attrs) do
    case Ecto.UUID.cast(org_id) do
      {:ok, org_id} ->
        %Profile{org_id: org_id, project_id: default_project_unless_given(org_id, attrs)}
        |> Profile.changeset(attrs)
        |> validate_profile(org_id)
        |> Repo.insert()

      :error ->
        {:error, :not_found}
    end
  end

  @spec update_profile(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), map()) ::
          {:ok, Profile.t()} | {:error, term()}
  def update_profile(org_id, profile, attrs) do
    with {:ok, profile} <- fetch(Profile, org_id, profile) do
      profile
      |> Profile.changeset(attrs)
      |> validate_profile(profile.org_id)
      |> Repo.update()
    end
  end

  defp default_project_unless_given(org_id, attrs) do
    if Map.has_key?(attrs, :project_id) or Map.has_key?(attrs, "project_id"),
      do: nil,
      else: default_render_project_id(org_id)
  end

  @doc """
  The project a new profile in `org_id` stores its renders in: the org's
  non-archived projects ordered by name, then id; none -> nil, otherwise
  the first. Never creates a project.

  KEEP IN SYNC with the SQL in
  `priv/repo/migrations/20261023070500_backfill_social_profile_project.exs`
  (task 01a16532 stage 2), which applies this same rule to existing
  profiles with a nil project. Names compare in byte order (Elixir term
  order), which is why that SQL sorts with `COLLATE "C"`.
  """
  @spec default_render_project_id(term()) :: Ecto.UUID.t() | nil
  def default_render_project_id(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, org_id} ->
        [org_id: org_id]
        |> Platform.Tasks.list_projects_unscoped()
        |> Enum.filter(&is_nil(&1.archived_at))
        |> Enum.min_by(&{&1.name, &1.id}, fn -> nil end)
        |> case do
          nil -> nil
          project -> project.id
        end

      :error ->
        nil
    end
  end

  @doc """
  Sets the project a profile's renders are stored in. Only an approver of
  the profile may (`approver_check/3`, checked before anything else; a
  refusal writes nothing). Only `project_id` is cast; it must name a
  non-archived project in the profile's org, so another org's project, an
  unknown id, an archived project or a blank are refused. Agents are never
  approvers, and there is deliberately no agent tool for this.
  """
  @spec set_profile_project(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), term(), term()) ::
          {:ok, Profile.t()}
          | {:error, :not_found | approver_refusal() | Ecto.Changeset.t()}
  def set_profile_project(org_id, profile, user_id, project_id) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         :ok <- approver_check(org_id, profile, user_id) do
      profile
      |> Changeset.cast(%{project_id: project_id}, [:project_id])
      |> Changeset.validate_required([:project_id])
      |> validate_project_in_org(profile.org_id)
      |> validate_project_not_archived()
      |> Repo.update()
    end
  end

  defp validate_project_not_archived(%Changeset{valid?: false} = changeset), do: changeset

  defp validate_project_not_archived(changeset) do
    case Platform.Tasks.get_project(Changeset.get_field(changeset, :project_id)) do
      %{archived_at: nil} -> changeset
      _ -> Changeset.add_error(changeset, :project_id, "must not be an archived project")
    end
  end

  @doc "Deletes the profile and (FK `delete_all`) its accounts, posts and clips."
  @spec delete_profile(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t()) ::
          {:ok, Profile.t()} | {:error, term()}
  def delete_profile(org_id, profile) do
    with {:ok, profile} <- fetch(Profile, org_id, profile), do: Repo.delete(profile)
  end

  defp validate_profile(changeset, org_id) do
    changeset
    |> validate_project_in_org(org_id)
    |> validate_space_in_org(org_id)
    |> validate_approvers()
  end

  # Social 3/7: the profile's channel must be a space in the profile's org,
  # read through core's public Chat API (never a Repo query on chat_spaces).
  defp validate_space_in_org(changeset, org_id) do
    case Changeset.get_change(changeset, :space_id) do
      nil ->
        changeset

      space_id ->
        case Platform.Chat.get_space(space_id) do
          %{org_id: ^org_id, archived_at: nil} -> changeset
          _ -> Changeset.add_error(changeset, :space_id, "must be a space in the profile's org")
        end
    end
  end

  defp validate_project_in_org(changeset, org_id) do
    case Changeset.get_field(changeset, :project_id) do
      nil ->
        changeset

      project_id ->
        with {:ok, project_id} <- Ecto.UUID.cast(project_id),
             %{org_id: ^org_id} <- Platform.Tasks.get_project(project_id) do
          changeset
        else
          _ -> Changeset.add_error(changeset, :project_id, "must belong to the profile's org")
        end
    end
  end

  defp validate_approvers(changeset) do
    ids = Changeset.get_field(changeset, :approver_user_ids) || []

    if Enum.all?(ids, &human_user?/1),
      do: changeset,
      else: Changeset.add_error(changeset, :approver_user_ids, @not_a_user)
  end

  # Through core's context, never a Repo query on core's users table. An
  # agent id is not in users, so it answers nil here.
  defp human_user?(id) do
    case Platform.Accounts.get_user(id) do
      %{archived_at: nil} -> true
      _ -> false
    end
  end

  # ── Accounts ─────────────────────────────────────────────────────────

  @doc "The Vault slug naming an account's credential. Set by this module only."
  @spec account_secret_slug(Account.t() | Ecto.UUID.t()) :: String.t()
  def account_secret_slug(%Account{id: id}), do: account_secret_slug(id)
  def account_secret_slug(id) when is_binary(id), do: "social:#{id}"

  @spec get_account(Ecto.UUID.t(), Ecto.UUID.t()) :: Account.t() | nil
  def get_account(org_id, id), do: scoped_get(Account, org_id, id)

  @doc """
  Lists the org's accounts. Options: `:profile_id`, and `:include_archived`
  (default false: archived accounts are omitted).
  """
  @spec list_accounts(Ecto.UUID.t(), keyword()) :: [Account.t()]
  def list_accounts(org_id, opts \\ []) do
    Account
    |> scoped_query(org_id)
    |> filter_profile(opts[:profile_id])
    |> then(fn q ->
      if opts[:include_archived], do: q, else: where(q, [a], is_nil(a.archived_at))
    end)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> Repo.all()
  end

  defp filter_profile(query, nil), do: query
  defp filter_profile(query, profile_id), do: where(query, [x], x.profile_id == ^profile_id)

  @doc "Creates an account under a profile in the caller's org. `approval_mode` defaults to `approve_first`."
  @spec create_account(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), map()) ::
          {:ok, Account.t()} | {:error, term()}
  def create_account(org_id, profile, attrs) do
    with {:ok, profile} <- fetch(Profile, org_id, profile) do
      id = Platform.Types.UUIDv7.generate()

      %Account{id: id, profile_id: profile.id, secret_slug: account_secret_slug(id)}
      |> Account.changeset(attrs)
      |> Repo.insert()
    end
  end

  @spec update_account(Ecto.UUID.t(), Account.t() | Ecto.UUID.t(), map()) ::
          {:ok, Account.t()} | {:error, term()}
  def update_account(org_id, account, attrs) do
    with {:ok, account} <- fetch(Account, org_id, account) do
      account |> Account.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Sets the account's owner, the person it posts as (task 01a14ce1), or
  clears it with nil. `owner_user_id` is never cast from attrs, so this is
  the only writer. An id that is not a users row is a changeset error on
  `:owner_user_id`. Who may call this is the caller's rule (the connect
  flow decides it); this function only writes.
  """
  @spec set_account_owner(Ecto.UUID.t(), Account.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, Account.t()} | {:error, term()}
  def set_account_owner(org_id, account, owner_user_id) do
    with {:ok, account} <- fetch(Account, org_id, account) do
      account |> Account.owner_changeset(owner_user_id) |> Repo.update()
    end
  end

  @doc "Archives an account: hidden from the default list, posts stay readable, no new posts."
  @spec archive_account(Ecto.UUID.t(), Account.t() | Ecto.UUID.t()) ::
          {:ok, Account.t()} | {:error, term()}
  def archive_account(org_id, account) do
    with {:ok, account} <- fetch(Account, org_id, account) do
      account
      |> Changeset.change(archived_at: account.archived_at || DateTime.utc_now())
      |> Repo.update()
    end
  end

  # ── Removing an account (task 01a14ac6) ──────────────────────────────

  # Posts a removal cancels. Drafts are never touched; published and failed
  # are terminal already.
  @cancellable_on_removal ~w(scheduled approved needs_approval)
  @removed_error "cancelled: account removed"

  @typedoc "What happened at the vendor when an account was removed."
  @type removal_vendor :: :disconnected | :not_connected | {:unconfirmed, term()}

  @doc """
  What `remove_account/4` would cancel, read-only. Cancellable posts are the
  account's posts in `scheduled`, `approved` or `needs_approval` (drafts,
  published and failed are untouched and not counted). `shared` counts the
  cancellable posts whose non-nil `task_id` is also on a post of ANOTHER
  account (a multi-account social task); `cancelled` counts the rest. The
  account must be a live row of `profile` in the caller's org, else
  `{:error, :not_found}`.
  """
  @spec removal_preview(scope(), Profile.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{account: Account.t(), cancelled: non_neg_integer(), shared: non_neg_integer()}}
          | {:error, :not_found}
  def removal_preview(org_id, profile, account_id) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         {:ok, account} <- live_account_of(org_id, profile, account_id) do
      {single, shared} = account |> cancellable_query() |> Repo.all() |> split_shared(account)
      {:ok, %{account: account, cancelled: length(single), shared: length(shared)}}
    end
  end

  @doc """
  Removes a connected (or never-connected) account: the server-side path
  behind the Connections "Remove" control. In order:

    1. the profile is re-read through the org scope and the account must be
       a live (`archived_at` nil) row of it, else `{:error, :not_found}`;
    2. `approver_check/3` FIRST: a refusal is returned with nothing written
       and no vendor request;
    3. ONE transaction under the profile row lock: the cancellable posts
       (see `removal_preview/3`) are locked and set to `failed` with error
       "#{@removed_error}" (there is no `cancelled` status), and the account
       is archived (`archived_at`). Nothing is deleted; post history stays;
    4. after commit, each cancelled post is reported to
       `Platform.Social.TaskBridge.post_changed/1`;
    5. after commit, best effort, through the configured publisher: each
       cancelled post that was `scheduled` with an `external_id` is deleted at
       the vendor, then an account with a `provider_account_ref` is
       disconnected. A never-connected row makes no vendor call.

  Answers `{:ok, archived_account, %{cancelled: n, shared: m, vendor: v}}`.
  `vendor` is `:disconnected`, `:not_connected` (nothing to tell the vendor)
  or `{:unconfirmed, reason}` when any vendor call failed (no key, no
  publisher, a 503): the archive and the cancels STAND either way.
  """
  @spec remove_account(scope(), Profile.t() | Ecto.UUID.t(), term(), Ecto.UUID.t()) ::
          {:ok, Account.t(),
           %{cancelled: non_neg_integer(), shared: non_neg_integer(), vendor: removal_vendor()}}
          | {:error, :not_found | approver_refusal() | term()}
  def remove_account(org_id, profile, user_id, account_id) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         {:ok, _account} <- live_account_of(org_id, profile, account_id),
         :ok <- approver_check(org_id, profile, user_id),
         {:ok, {archived, cancelled}} <- archive_and_cancel(org_id, profile, account_id) do
      Enum.each(cancelled, &Platform.Social.TaskBridge.post_changed(&1.id))
      {single, shared} = split_shared(cancelled, archived)

      {:ok, archived,
       %{
         cancelled: length(single),
         shared: length(shared),
         vendor: tell_vendor(archived, cancelled)
       }}
    end
  end

  defp live_account_of(org_id, %Profile{id: profile_id}, account_id) do
    case scoped_get(Account, org_id, account_id) do
      %Account{profile_id: ^profile_id, archived_at: nil} = account -> {:ok, account}
      _ -> {:error, :not_found}
    end
  end

  defp cancellable_query(%Account{id: account_id}) do
    Post
    |> where([p], p.account_id == ^account_id and p.status in ^@cancellable_on_removal)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
  end

  # Splits posts into {single, shared}: shared when another account holds a
  # post with the same non-nil task_id.
  defp split_shared(posts, %Account{id: account_id}) do
    task_ids = posts |> Enum.map(& &1.task_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    shared_tasks =
      if task_ids == [] do
        MapSet.new()
      else
        Post
        |> where([p], p.task_id in ^task_ids and p.account_id != ^account_id)
        |> select([p], p.task_id)
        |> distinct(true)
        |> Repo.all()
        |> MapSet.new()
      end

    {shared, single} = Enum.split_with(posts, &MapSet.member?(shared_tasks, &1.task_id))
    {single, shared}
  end

  # Returns {:ok, {archived_account, cancelled_posts_before_the_write}}: the
  # pre-write structs keep the old status, which step 5 reads.
  defp archive_and_cancel(org_id, profile, account_id) do
    Repo.transaction(fn ->
      locked = lock_profile(org_id, profile) || Repo.rollback(:not_found)

      account =
        case live_account_of(org_id, locked, account_id) do
          {:ok, account} -> account
          {:error, reason} -> Repo.rollback(reason)
        end

      posts = account |> cancellable_query() |> lock("FOR UPDATE") |> Repo.all()
      Enum.each(posts, &cancel_for_removal!/1)

      case archive_account(org_id, account) do
        {:ok, archived} -> {archived, posts}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp cancel_for_removal!(%Post{} = post) do
    post
    |> Changeset.change(status: "failed", error: @removed_error)
    |> Changeset.change(Post.refusal_cleared())
    |> Changeset.check_constraint(:status, name: :social_posts_status_check)
    |> Changeset.check_constraint(:approved_by_user_id,
      name: :social_posts_approved_needs_approver_check
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Best effort, after commit: never raises past here, never rolls back.
  defp tell_vendor(account, cancelled) do
    deletes =
      Enum.filter(cancelled, &(&1.status == "scheduled" and present?(&1.external_id)))

    connected? = present?(account.provider_account_ref)

    if deletes == [] and not connected? do
      :not_connected
    else
      case Publisher.impl() do
        {:error, reason} ->
          {:unconfirmed, reason}

        adapter ->
          delete_results =
            Enum.map(deletes, &vendor_call(fn -> adapter.delete(account, &1.external_id) end))

          disconnect =
            if connected?,
              do: [vendor_call(fn -> adapter.disconnect_account(account) end)],
              else: []

          case Enum.find(delete_results ++ disconnect, &(&1 != :ok)) do
            nil -> if connected?, do: :disconnected, else: :not_connected
            {:error, reason} -> {:unconfirmed, reason}
          end
      end
    end
  end

  defp vendor_call(fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # ── Connecting an account (task 01a14801) ────────────────────────────

  @doc """
  The platforms a human can add an account on: `Account.platforms/0`
  filtered to the configured publisher's `platforms/0`, in
  `Account.platforms/0` order. `[]` when no publisher is configured. This is
  the ONE list the Connections picker reads.
  """
  @spec connectable_platforms() :: [String.t()]
  def connectable_platforms do
    case Publisher.impl() do
      {:error, :publisher_not_configured} ->
        []

      module ->
        supported = module.platforms()
        Enum.filter(Account.platforms(), &(&1 in supported))
    end
  end

  @doc """
  Makes sure the vendor holds a profile for `profile`, creating it lazily on
  the first connect (never on `create_profile/2`, so a Fake install never
  calls out).

  Inside one transaction the profile is re-read through the org scope with
  `FOR UPDATE` (the `lock_post/2` pattern). A present `provider_profile_ref`
  answers `{:ok, profile}` with NO publisher call. Otherwise the publisher's
  `ensure_profile/1` runs: `{:ok, ref}` writes ONLY `provider_profile_ref`
  (a dedicated `Changeset.change/2`, not the editable cast) and answers the
  updated profile; `:not_required` answers the profile unchanged, ref still
  nil; `{:error, reason}` writes nothing and answers `{:error, reason}`.

  Trade-off, accepted: the single profile row lock is held across ONE
  bounded HTTP call to the vendor. That serialises two concurrent first
  connects (the second waits, then sees the ref and makes no call); the
  vendor `Idempotency-Key` (our profile id) is the backstop.
  """
  @spec ensure_provider_profile(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t()) ::
          {:ok, Profile.t()} | {:error, term()}
  def ensure_provider_profile(org_id, profile) do
    Repo.transaction(fn ->
      case lock_profile(org_id, profile) do
        nil ->
          Repo.rollback(:not_found)

        %Profile{provider_profile_ref: ref} = locked when is_binary(ref) ->
          locked

        locked ->
          case publisher_ensure_profile(locked) do
            {:ok, ref} when is_binary(ref) ->
              locked
              |> Changeset.change(provider_profile_ref: ref)
              |> Repo.update()
              |> case do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end

            :not_required ->
              locked

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  end

  defp publisher_ensure_profile(profile) do
    case Publisher.impl() do
      {:error, :publisher_not_configured} = error -> error
      module -> module.ensure_profile(profile)
    end
  end

  defp lock_profile(org_id, %Profile{id: id}), do: lock_profile(org_id, id)

  defp lock_profile(org_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Profile
        |> scoped_query(org_id)
        |> where([x], x.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Adds an account on `platform` under `profile` for the human `user_id`, the
  server-side path behind the Connections "Add account" control. In order:

    1. `approver_check/3`: an agent id, an archived user or a non-approver is
       refused with its reason and nothing is written (defence in depth beside
       the LiveView's own check);
    2. `platform` must be in `connectable_platforms/0`, else
       `{:error, :unsupported_platform}`;
    3. `ensure_provider_profile/2` BEFORE any row is written, so a vendor
       failure leaves no orphan account;
    4. an existing never-connected account on that profile and platform
       (not archived, `status` nil, `provider_account_ref` nil) is REUSED;
       otherwise one is created. Abandoning a connect is retried, not
       deleted, so re-adding never piles up duplicates. Step 4 runs under the
       profile row lock so two concurrent adds share one row.

  Answers `{:ok, account, profile}` (the profile carries any new ref). It
  does not start OAuth (`connect_url/2` is the caller's next step).
  """
  @spec add_account(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), term(), term()) ::
          {:ok, Account.t(), Profile.t()} | {:error, term()}
  def add_account(org_id, profile, user_id, platform) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         :ok <- approver_check(org_id, profile, user_id),
         :ok <- connectable(platform),
         {:ok, profile} <- ensure_provider_profile(org_id, profile),
         {:ok, account} <- reuse_or_create_account(org_id, profile, platform) do
      {:ok, account, profile}
    end
  end

  defp connectable(platform) do
    if platform in connectable_platforms(), do: :ok, else: {:error, :unsupported_platform}
  end

  defp reuse_or_create_account(org_id, profile, platform) do
    Repo.transaction(fn ->
      _locked = lock_profile(org_id, profile)

      case never_connected_account(profile, platform) do
        %Account{} = account ->
          account

        nil ->
          case create_account(org_id, profile, %{platform: platform}) do
            {:ok, account} -> account
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp never_connected_account(%Profile{id: profile_id}, platform) do
    Account
    |> where([a], a.profile_id == ^profile_id and a.platform == ^platform)
    |> where([a], is_nil(a.archived_at) and is_nil(a.status) and is_nil(a.provider_account_ref))
    |> not_invite_bound()
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> limit(1)
    |> Repo.one()
  end

  # ── OAuth return (task 01a14807) ─────────────────────────────────────

  @ref_index :social_accounts_provider_account_ref_live_index

  @typedoc "Why `complete_connect/4` or `reconcile_accounts/3` refused."
  @type connect_refusal ::
          approver_refusal()
          | :not_found
          | :profile_not_linked
          | :not_listed
          | :no_pending_account
          | :ref_in_use
          | term()

  @doc """
  The OAuth return leg: turns "the vendor says account `ref` is connected
  under this profile" into a stored `provider_account_ref` plus status
  `"connected"` on our never-connected row. In order:

    1. the profile is re-read through the org scope (`:not_found`);
    2. `approver_check/3` FIRST, so a refusal sends no request and writes
       nothing;
    3. the profile must carry `provider_profile_ref`, else
       `:profile_not_linked` with no request;
    4. ONE `list_accounts/1` call. `ref` must be listed with `profile_ref`
       equal to the profile's ref and `active?` true, else `:not_listed` and
       nothing is written. The URL's account id is never trusted on its own,
       and the platform used is the LISTED one: `params.platform` is ignored;
    5. under the profile row lock, in one transaction: a live row of this
       profile already holding `ref` answers `{:ok, account,
       :already_connected}`, writing at most a newly reported account type
       (never nil over a stored one). Otherwise the never-connected row
       on (profile, listed platform) gets ONLY `provider_account_ref`,
       `status` and (when its `handle` is nil) `handle`, through a dedicated
       `Changeset.change/2`: `{:ok, account, :connected}`. No such row is
       `:no_pending_account` (no row is created). A ref held by another
       profile's live row trips the unique index: `:ref_in_use`.
  """
  @spec complete_connect(
          Ecto.UUID.t(),
          Profile.t() | Ecto.UUID.t(),
          connect_auth() | term(),
          map()
        ) ::
          {:ok, Account.t(), :connected | :already_connected} | {:error, connect_refusal()}
  def complete_connect(org_id, profile, auth, params) when is_map(params) do
    ref = Map.get(params, :account_ref)

    with {:ok, profile} <- fetch(Profile, org_id, profile),
         {:ok, auth} <- connect_authorized(org_id, profile, auth),
         :ok <- linked(profile),
         {:ok, entries} <- publisher_list_accounts(profile),
         {:ok, entry} <- listed_entry(entries, profile, ref) do
      connect_listed(org_id, profile, entry, auth)
    end
  end

  @typedoc """
  Who is completing a connect (task 01a14ce1, stage 2). `{:approver, user_id}`
  is the profile approver's own connect (a bare user id means the same).
  `{:invite, nonce, user_id}` is an invitee returning from a connect that
  `start_invite_connect/3` started: `nonce` is the per-connect nonce from
  the `redirect_url`, never the shared invite token.
  """
  @type connect_auth :: {:approver, term()} | {:invite, String.t(), term()}

  # Re-authorized on every call, BEFORE the vendor request, so a refusal
  # sends nothing and writes nothing. The invite branch is re-checked under
  # the row locks in connect_listed/4.
  defp connect_authorized(org_id, profile, {:approver, user_id}) do
    with :ok <- approver_check(org_id, profile, user_id), do: {:ok, :approver}
  end

  defp connect_authorized(_org_id, profile, {:invite, nonce, user_id}) do
    with {:ok, invite} <- invite_by_nonce(nonce),
         :ok <- invite_connect_check(invite, profile, user_id) do
      {:ok, {:invite, invite.connect_nonce_hash, user_id}}
    end
  end

  defp connect_authorized(org_id, profile, user_id),
    do: connect_authorized(org_id, profile, {:approver, user_id})

  @doc """
  The pre-ship pickup: fills our never-connected rows from the vendor's list,
  for a return that never reached us. Same guards as `complete_connect/4`
  (scope, approver first, ref present). A profile with no never-connected
  row AND no live connected row lacking a `platform_account_type` answers
  `{:ok, %{connected: [], unmatched: 0, typed: []}}` with NO request.
  Otherwise ONE `list_accounts/1` call; each listed entry (matching
  `profile_ref`, `active?` true) whose ref no live row holds fills the
  oldest never-connected row on its platform, one entry per row, in list
  order, under the profile lock. `unmatched` counts the eligible entries
  that are neither already on one of this profile's rows nor filled now.

  Type backfill (task 01a1653a): an entry whose ref is already on one of
  this profile's live rows updates ONLY that row's `platform_account_type`,
  when the entry reports a known type that differs from the stored one.
  nil never overwrites a stored type. Those rows are returned in `typed`.
  """
  @spec reconcile_accounts(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), term()) ::
          {:ok, %{connected: [Account.t()], unmatched: non_neg_integer(), typed: [Account.t()]}}
          | {:error, connect_refusal()}
  def reconcile_accounts(org_id, profile, user_id) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         :ok <- approver_check(org_id, profile, user_id),
         :ok <- linked(profile) do
      if pending_accounts(profile) == [] and untyped_connected_accounts(profile) == [] do
        {:ok, %{connected: [], unmatched: 0, typed: []}}
      else
        with {:ok, entries} <- publisher_list_accounts(profile) do
          fill_pending(org_id, profile, Enum.filter(entries, &listed_under?(&1, profile)))
        end
      end
    end
  end

  defp linked(%Profile{provider_profile_ref: ref}) when is_binary(ref) and ref != "", do: :ok
  defp linked(_profile), do: {:error, :profile_not_linked}

  defp publisher_list_accounts(profile) do
    case Publisher.impl() do
      {:error, :publisher_not_configured} = error -> error
      module -> module.list_accounts(profile)
    end
  end

  defp listed_under?(%{profile_ref: profile_ref, active?: true}, %Profile{
         provider_profile_ref: profile_ref
       })
       when is_binary(profile_ref),
       do: true

  defp listed_under?(_entry, _profile), do: false

  defp listed_entry(entries, profile, ref) when is_binary(ref) and ref != "" do
    case Enum.find(entries, &(&1.ref == ref and listed_under?(&1, profile))) do
      nil -> {:error, :not_listed}
      entry -> {:ok, entry}
    end
  end

  defp listed_entry(_entries, _profile, _ref), do: {:error, :not_listed}

  # The invite branch (task 01a14ce1, stage 2). Under the profile lock and
  # the invite's row lock, in ONE transaction: re-validate the invite and the
  # caller, then fill the invite's OWN account row (never another pending
  # row), set its owner to the invitee and mark the invite used. There is no
  # approver step: the invite is the authorization. Any refusal rolls back,
  # so nothing is written.
  defp connect_listed(org_id, profile, entry, {:invite, nonce_hash, user_id}) do
    Repo.transaction(fn ->
      locked = lock_profile(org_id, profile) || Repo.rollback(:not_found)
      invite = lock_invite_by_nonce_hash(nonce_hash) || Repo.rollback(:not_found)

      with :ok <- invite_connect_check(invite, locked, user_id),
           :ok <- same_platform(invite, entry),
           :ok <- ref_free(locked, entry.ref),
           %Account{} = account <- invite_account(invite, locked) || {:error, :no_pending_account} do
        account = mark_connected!(account, entry)

        account =
          case account |> Account.owner_changeset(user_id) |> Repo.update() do
            {:ok, owned} -> owned
            {:error, changeset} -> Repo.rollback(changeset)
          end

        invite
        |> Changeset.change(
          used_at: DateTime.utc_now(),
          used_by_user_id: user_id,
          account_id: account.id,
          connect_nonce_hash: nil,
          connect_nonce_expires_at: nil
        )
        |> Repo.update!()

        {account, :connected}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {account, outcome}} -> {:ok, account, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect_listed(org_id, profile, entry, :approver) do
    Repo.transaction(fn ->
      locked = lock_profile(org_id, profile) || Repo.rollback(:not_found)

      case live_account_with_ref(locked, entry.ref) do
        %Account{} = account ->
          {backfill_type!(account, entry), :already_connected}

        nil ->
          case never_connected_account(locked, entry.platform) do
            nil -> Repo.rollback(:no_pending_account)
            account -> {mark_connected!(account, entry), :connected}
          end
      end
    end)
    |> case do
      {:ok, {account, outcome}} -> {:ok, account, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fill_pending(org_id, profile, entries) do
    Repo.transaction(fn ->
      locked = lock_profile(org_id, profile) || Repo.rollback(:not_found)
      refs = Enum.map(entries, & &1.ref)

      held =
        Account
        |> where([a], a.provider_account_ref in ^refs and is_nil(a.archived_at))
        |> select([a], {a.provider_account_ref, a})
        |> Repo.all()
        |> Map.new()

      pending = locked |> pending_accounts() |> Enum.group_by(& &1.platform)

      {connected, unmatched, typed, _pending} =
        entries
        |> Enum.uniq_by(& &1.ref)
        |> Enum.reduce({[], 0, [], pending}, fn entry, {connected, unmatched, typed, pending} ->
          case {Map.fetch(held, entry.ref), Map.get(pending, entry.platform, [])} do
            {{:ok, %Account{profile_id: profile_id} = account}, _} when profile_id == locked.id ->
              if type_backfill?(account, entry),
                do: {connected, unmatched, [backfill_type!(account, entry) | typed], pending},
                else: {connected, unmatched, typed, pending}

            {{:ok, _another_profile}, _} ->
              {connected, unmatched + 1, typed, pending}

            {:error, []} ->
              {connected, unmatched + 1, typed, pending}

            {:error, [account | rest]} ->
              {[mark_connected!(account, entry) | connected], unmatched, typed,
               Map.put(pending, entry.platform, rest)}
          end
        end)

      %{connected: Enum.reverse(connected), unmatched: unmatched, typed: Enum.reverse(typed)}
    end)
  end

  defp live_account_with_ref(%Profile{id: profile_id}, ref) do
    Account
    |> where([a], a.profile_id == ^profile_id and a.provider_account_ref == ^ref)
    |> where([a], is_nil(a.archived_at))
    |> limit(1)
    |> Repo.one()
  end

  # Never-connected rows: the `never_connected_account/2` predicate, oldest first.
  defp pending_accounts(%Profile{id: profile_id}) do
    Account
    |> where([a], a.profile_id == ^profile_id)
    |> where([a], is_nil(a.archived_at) and is_nil(a.status) and is_nil(a.provider_account_ref))
    |> not_invite_bound()
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> Repo.all()
  end

  # Live connected rows of this profile whose account type we never learned:
  # the rows the type backfill can fill (task 01a1653a).
  defp untyped_connected_accounts(%Profile{id: profile_id}) do
    Account
    |> where([a], a.profile_id == ^profile_id)
    |> where([a], is_nil(a.archived_at) and a.status == "connected")
    |> where([a], not is_nil(a.provider_account_ref) and is_nil(a.platform_account_type))
    |> Repo.all()
  end

  # A known reported type that differs from the stored one. nil (or an entry
  # without the key) never qualifies, so nil never overwrites a stored type.
  defp type_backfill?(%Account{platform_account_type: stored}, entry) do
    reported = Map.get(entry, :account_type)
    reported in Account.platform_account_types() and reported != stored
  end

  # Writes ONLY platform_account_type, through a dedicated change (not the
  # editable cast). A no-op returns the row unchanged.
  defp backfill_type!(%Account{} = account, entry) do
    if type_backfill?(account, entry) do
      account
      |> Changeset.change(platform_account_type: Map.get(entry, :account_type))
      |> Repo.update()
      |> case do
        {:ok, account} -> account
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      account
    end
  end

  # The ONLY write: ref, status, a missing handle and a reported account type.
  # Not the editable cast. A type is written only when the vendor reported one
  # we know; nil never overwrites a stored type (an entry without the key is
  # nil). Call inside a transaction; a collision on the live-ref index rolls
  # back with :ref_in_use.
  defp mark_connected!(%Account{} = account, entry) do
    account_type = Map.get(entry, :account_type)

    changes =
      [provider_account_ref: entry.ref, status: "connected"] ++
        if(is_nil(account.handle) and is_binary(entry.username),
          do: [handle: entry.username],
          else: []
        ) ++
        if(account_type in Account.platform_account_types(),
          do: [platform_account_type: account_type],
          else: []
        )

    account
    |> Changeset.change(changes)
    |> Changeset.unique_constraint(:provider_account_ref, name: @ref_index)
    |> Repo.update()
    |> case do
      {:ok, account} ->
        account

      {:error, %Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :provider_account_ref),
          do: Repo.rollback(:ref_in_use),
          else: Repo.rollback(changeset)
    end
  end

  # ── Connect invites (task 01a14ce1, stage 2) ─────────────────────────

  @invite_nonce_ttl_s 30 * 60
  @token_bytes 32

  @typedoc "Why an invite cannot be used right now."
  @type invite_refusal ::
          :not_found
          | :expired
          | :used
          | :cancelled
          | :not_the_inviter
          | :unsupported_platform
          | approver_refusal()

  @doc """
  Invites a person to connect THEIR OWN account on `platform` under
  `profile`; whoever completes it becomes the account's owner. Only a
  profile approver may invite (`approver_check/3`), and only on a
  `connectable_platforms/0` platform. The invite expires after `ttl_days`
  (default `config :social, :invite_ttl_days`, else 7).

  Answers `{:ok, invite, token}`. `token` is 32 random bytes, url-safe
  base64, returned ONCE: only its sha256 is stored. The link to share is
  `/m/social?invite=<token>`. No account row is created yet, and no vendor
  request is made.
  """
  @spec create_invite(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), term(), term(), term()) ::
          {:ok, ConnectInvite.t(), String.t()} | {:error, term()}
  def create_invite(org_id, profile, user_id, platform, ttl_days \\ nil) do
    with {:ok, profile} <- fetch(Profile, org_id, profile),
         :ok <- approver_check(org_id, profile, user_id),
         :ok <- connectable(platform),
         {:ok, days} <- invite_ttl(ttl_days) do
      token = random_token()

      %ConnectInvite{
        org_id: profile.org_id,
        profile_id: profile.id,
        platform: platform,
        token_hash: digest(token),
        created_by_user_id: user_id,
        expires_at: DateTime.add(DateTime.utc_now(), days * 86_400, :second)
      }
      |> Repo.insert()
      |> case do
        {:ok, invite} -> {:ok, invite, token}
        {:error, _} = error -> error
      end
    end
  end

  defp invite_ttl(nil), do: invite_ttl(Application.get_env(:social, :invite_ttl_days, 7))
  defp invite_ttl(days) when is_integer(days) and days > 0, do: {:ok, days}
  defp invite_ttl(_days), do: {:error, :invalid_ttl}

  @doc """
  Cancels an unused invite. Approver only (`approver_check/3` on the
  invite's profile, re-read now). A used invite is `{:error, :used}`; an
  already cancelled one answers `{:ok, invite}` with no write. Any connect
  in flight on it is refused afterwards.
  """
  @spec cancel_invite(Ecto.UUID.t(), ConnectInvite.t() | Ecto.UUID.t(), term()) ::
          {:ok, ConnectInvite.t()} | {:error, term()}
  def cancel_invite(org_id, invite, user_id) do
    Repo.transaction(fn ->
      with %ConnectInvite{} = locked <- lock_invite_in(org_id, invite) || {:error, :not_found},
           {:ok, profile} <- fetch(Profile, org_id, locked.profile_id),
           :ok <- approver_check(org_id, profile, user_id) do
        cond do
          locked.used_at -> Repo.rollback(:used)
          locked.cancelled_at -> locked
          true -> Repo.update!(Changeset.change(locked, cancelled_at: DateTime.utc_now()))
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "The profile's invites that are neither used, cancelled nor expired, oldest first."
  @spec list_pending_invites(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t()) :: [ConnectInvite.t()]
  def list_pending_invites(org_id, profile) do
    case fetch(Profile, org_id, profile) do
      {:ok, %Profile{id: profile_id}} ->
        now = DateTime.utc_now()

        ConnectInvite
        |> where([i], i.profile_id == ^profile_id)
        |> where([i], is_nil(i.used_at) and is_nil(i.cancelled_at) and i.expires_at > ^now)
        |> order_by([i], asc: i.inserted_at, asc: i.id)
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc """
  Resolves a shared invite `token` for the signed-in `user_id`. The token
  is hashed and compared in constant time; an unknown or forged token is
  `:not_found`. The user must be a live, non-archived human with access to
  the invite's org (an agent id is `:not_a_human`, another org's user
  `:approver_no_access`); they need NOT be an approver. Then the invite's
  own state: `:cancelled`, `:used` or `:expired`. Answers `{:ok, invite}`.
  Reads only.
  """
  @spec get_invite_for(term(), term()) :: {:ok, ConnectInvite.t()} | {:error, invite_refusal()}
  def get_invite_for(token, user_id) do
    with {:ok, invite} <- invite_by_token(token),
         {:ok, profile} <- invite_profile(invite),
         :ok <- invitee_check(profile, user_id),
         :ok <- invite_live(invite) do
      {:ok, invite}
    end
  end

  @doc """
  Starts a FRESH vendor connect for an invite (the vendor's own connect
  state expires in about 30 minutes, so a link cannot carry one). In order:
  `get_invite_for/2` (no write and no request on any refusal), the
  platform must still be connectable, `ensure_provider_profile/2`, then
  under the profile lock and the invite's row lock: the invite is
  re-validated, its OWN account row is bound (the row in
  `invite.account_id` while it is still never-connected, else a new row,
  never another pending row), `started_by_user_id` is set to the caller and
  a fresh per-connect nonce replaces any earlier one (only its sha256 and
  an expiry of 30 minutes are stored, so an abandoned connect's nonce is
  refused from now on). Then `connect_url/2` with
  `redirect_url: <base>/m/social?invite_connect=<nonce>`. The shared token
  never goes to the vendor.

  Options: `:base_url` (default `PlatformWeb.Endpoint.url/0`). Answers
  `{:ok, url}`.
  """
  @spec start_invite_connect(term(), term(), keyword()) ::
          {:ok, String.t()} | {:error, invite_refusal() | term()}
  def start_invite_connect(token, user_id, opts \\ []) do
    with {:ok, invite} <- get_invite_for(token, user_id),
         {:ok, profile} <- invite_profile(invite) do
      start_bound_connect(invite, profile, user_id, opts)
    end
  end

  @doc """
  "Try again" after a cancelled or failed vendor connect (task 01a14ce1,
  stage 4). The browser holds only the per-connect `nonce` from the return,
  never the shared token, so the restart is keyed on it: the nonce must
  still be live, its invite live, and the caller must be the user who
  started that connect (`:not_the_inviter` otherwise) and pass the same
  invitee check. Then exactly what `start_invite_connect/3` does after its
  lookup, so a FRESH nonce replaces this one. Answers `{:ok, url}`; any
  refusal sends no request and writes nothing.
  """
  @spec restart_invite_connect(term(), term(), keyword()) ::
          {:ok, String.t()} | {:error, invite_refusal() | term()}
  def restart_invite_connect(nonce, user_id, opts \\ []) do
    with {:ok, invite} <- invite_by_nonce(nonce),
         {:ok, profile} <- invite_profile(invite),
         :ok <- invite_connect_check(invite, profile, user_id) do
      start_bound_connect(invite, profile, user_id, opts)
    end
  end

  defp start_bound_connect(invite, profile, user_id, opts) do
    with :ok <- connectable(invite.platform),
         {:ok, profile} <- ensure_provider_profile(profile.org_id, profile),
         {:ok, {account, nonce}} <- bind_invite_connect(profile, invite.id, user_id) do
      base = Keyword.get_lazy(opts, :base_url, fn -> PlatformWeb.Endpoint.url() end)
      redirect_url = base <> "/m/social?" <> URI.encode_query(%{"invite_connect" => nonce})
      publisher_connect_url(account, profile, redirect_url)
    end
  end

  @doc """
  What the invitee landing page shows for a shared `token` (task 01a14ce1,
  stage 4). Reads only. The same lookup and invitee check as
  `get_invite_for/2` (forged, another org, an agent or an archived user is
  `{:error, :not_found | refusal}` with nothing else), but an invite that is
  no longer usable still answers with its row and profile, so the page can
  say when it expired, who sent it, or that the viewer already used it:

    * `{:ok, invite, profile}`: live, Continue may start a connect;
    * `{:error, :expired | :used | :cancelled, invite, profile}`;
    * `{:error, reason}`: nothing to show beyond "not valid".
  """
  @spec invite_landing_for(term(), term()) ::
          {:ok, ConnectInvite.t(), Profile.t()}
          | {:error, :expired | :used | :cancelled, ConnectInvite.t(), Profile.t()}
          | {:error, invite_refusal()}
  def invite_landing_for(token, user_id) do
    with {:ok, invite} <- invite_by_token(token),
         {:ok, profile} <- invite_profile(invite),
         :ok <- invitee_check(profile, user_id) do
      invite_state(invite, profile)
    end
  end

  @doc """
  The landing page's view of a vendor return carrying `nonce` (the failed
  or cancelled leg, task 01a14ce1 stage 4). Reads only. The caller must be
  the user who started that connect; answers like `invite_landing_for/2`.
  """
  @spec invite_return_for(term(), term()) ::
          {:ok, ConnectInvite.t(), Profile.t()}
          | {:error, :expired | :used | :cancelled, ConnectInvite.t(), Profile.t()}
          | {:error, invite_refusal()}
  def invite_return_for(nonce, user_id) do
    with {:ok, invite} <- invite_by_nonce(nonce),
         {:ok, profile} <- invite_profile(invite),
         :ok <- invitee_check(profile, user_id),
         :ok <- the_inviter(invite, user_id) do
      invite_state(invite, profile)
    end
  end

  defp invite_state(invite, profile) do
    case invite_live(invite) do
      :ok -> {:ok, invite, profile}
      {:error, reason} -> {:error, reason, invite, profile}
    end
  end

  defp bind_invite_connect(profile, invite_id, user_id) do
    Repo.transaction(fn ->
      locked = lock_profile(profile.org_id, profile) || Repo.rollback(:not_found)
      invite = lock_invite(invite_id) || Repo.rollback(:not_found)

      with :ok <- same_profile(invite, locked),
           :ok <- invitee_check(locked, user_id),
           :ok <- invite_live(invite) do
        account =
          case invite_account(invite, locked) do
            %Account{} = account ->
              account

            nil ->
              case create_account(locked.org_id, locked, %{platform: invite.platform}) do
                {:ok, account} -> account
                {:error, reason} -> Repo.rollback(reason)
              end
          end

        nonce = random_token()

        invite
        |> Changeset.change(
          account_id: account.id,
          started_by_user_id: user_id,
          connect_nonce_hash: digest(nonce),
          connect_nonce_expires_at: DateTime.add(DateTime.utc_now(), @invite_nonce_ttl_s, :second)
        )
        |> Repo.update!()

        {account, nonce}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp publisher_connect_url(account, profile, redirect_url) do
    case Publisher.impl() do
      {:error, :publisher_not_configured} = error -> error
      module -> module.connect_url(account, redirect_url: redirect_url, profile: profile)
    end
  end

  # Every check an invite return must pass, run before the vendor request
  # AND again under the row locks: the nonce's invite is on this profile,
  # the caller is a live human with org access, the invite is live, the
  # nonce has not expired, and the caller is who started this connect.
  defp invite_connect_check(%ConnectInvite{} = invite, %Profile{} = profile, user_id) do
    with :ok <- same_profile(invite, profile),
         :ok <- invitee_check(profile, user_id),
         :ok <- invite_live(invite),
         :ok <- nonce_live(invite) do
      the_inviter(invite, user_id)
    end
  end

  defp the_inviter(%ConnectInvite{started_by_user_id: started_by}, user_id) do
    if is_binary(started_by) and started_by == user_id,
      do: :ok,
      else: {:error, :not_the_inviter}
  end

  defp same_profile(%ConnectInvite{profile_id: id}, %Profile{id: id}), do: :ok
  defp same_profile(_invite, _profile), do: {:error, :not_found}

  defp ref_free(profile, ref) do
    if live_account_with_ref(profile, ref), do: {:error, :ref_in_use}, else: :ok
  end

  defp same_platform(%ConnectInvite{platform: platform}, %{platform: platform}), do: :ok
  defp same_platform(_invite, _entry), do: {:error, :not_listed}

  defp invitee_check(%Profile{} = profile, user_id) do
    with {:ok, user} <- live_user(user_id),
         :ok <- not_archived(user) do
      if approver_access?(user, profile), do: :ok, else: {:error, :approver_no_access}
    end
  end

  defp invite_live(%ConnectInvite{cancelled_at: %DateTime{}}), do: {:error, :cancelled}
  defp invite_live(%ConnectInvite{used_at: %DateTime{}}), do: {:error, :used}

  defp invite_live(%ConnectInvite{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :expired}
  end

  defp nonce_live(%ConnectInvite{connect_nonce_expires_at: %DateTime{} = at}) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp nonce_live(_invite), do: {:error, :not_found}

  defp invite_profile(%ConnectInvite{profile_id: profile_id, org_id: org_id}) do
    case Repo.get(Profile, profile_id) do
      %Profile{org_id: ^org_id} = profile -> {:ok, profile}
      _ -> {:error, :not_found}
    end
  end

  # The invite's OWN row, while it is still never-connected on its profile
  # and platform. Never another pending row.
  defp invite_account(%ConnectInvite{account_id: nil}, _profile), do: nil

  defp invite_account(%ConnectInvite{account_id: id, platform: platform}, %Profile{id: profile_id}) do
    Account
    |> where([a], a.id == ^id and a.profile_id == ^profile_id and a.platform == ^platform)
    |> where([a], is_nil(a.archived_at) and is_nil(a.status) and is_nil(a.provider_account_ref))
    |> Repo.one()
  end

  # Rows bound to a live invite belong to that invite: an approver's own
  # add, return or pickup never reuses or fills them.
  defp not_invite_bound(query) do
    now = DateTime.utc_now()

    bound =
      from(i in ConnectInvite,
        where:
          not is_nil(i.account_id) and is_nil(i.used_at) and is_nil(i.cancelled_at) and
            i.expires_at > ^now,
        select: i.account_id
      )

    where(query, [a], a.id not in subquery(bound))
  end

  defp invite_by_token(token) when is_binary(token) and byte_size(token) in 1..128 do
    hash = digest(token)

    case Repo.get_by(ConnectInvite, token_hash: hash) do
      %ConnectInvite{token_hash: stored} = invite ->
        if Plug.Crypto.secure_compare(stored, hash), do: {:ok, invite}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp invite_by_token(_token), do: {:error, :not_found}

  defp invite_by_nonce(nonce) when is_binary(nonce) and byte_size(nonce) in 1..128 do
    hash = digest(nonce)

    case Repo.get_by(ConnectInvite, connect_nonce_hash: hash) do
      %ConnectInvite{connect_nonce_hash: stored} = invite when is_binary(stored) ->
        if Plug.Crypto.secure_compare(stored, hash), do: {:ok, invite}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp invite_by_nonce(_nonce), do: {:error, :not_found}

  defp lock_invite(id) do
    ConnectInvite |> where([i], i.id == ^id) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp lock_invite_by_nonce_hash(hash) when is_binary(hash) do
    ConnectInvite
    |> where([i], i.connect_nonce_hash == ^hash)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_invite_by_nonce_hash(_hash), do: nil

  defp lock_invite_in(org_id, %ConnectInvite{id: id}), do: lock_invite_in(org_id, id)

  defp lock_invite_in(org_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %ConnectInvite{org_id: invite_org} = invite <- lock_invite(id),
         true <- org_visible?(org_id, invite_org) do
      invite
    else
      _ -> nil
    end
  end

  defp random_token,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp digest(value), do: :crypto.hash(:sha256, value)

  # ── Posts ────────────────────────────────────────────────────────────

  @spec get_post(Ecto.UUID.t(), Ecto.UUID.t()) :: Post.t() | nil
  def get_post(org_id, id), do: scoped_get(Post, org_id, id)

  @doc """
  Re-reads a post through the org scope with `FOR UPDATE`, for
  `Platform.Social.Publishing` (Social 2/7). Call inside a transaction.
  """
  @spec lock_post(Ecto.UUID.t(), Ecto.UUID.t()) :: Post.t() | nil
  def lock_post(org_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Post
        |> scoped_query(org_id)
        |> where([x], x.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Lists the org's posts. Filters: `:account_id`, `:profile_id` (posts on any
  of the profile's accounts), `:status`, `:statuses` (a list), `:task_id`
  (Social 6/7: the drafts linked to one task), and `:placed_from` /
  `:placed_to` (Social 7/7's calendar: a half-open `[from, to)` range of
  `DateTime`s on the post's PLACEMENT time, `scheduled_at`, or `approved_at`
  for a post published or failed at approval with no schedule; the schema
  has no published-at column), `:profile_ids` (posts on any of those
  profiles' accounts), `:updated_from` (last written at or after a
  `DateTime`), `:calendar_from` + `:calendar_to` (Social authoring 8/11:
  a half-open range on the placement with `published_at` first for a
  published post), and `refused: true` (task 01a165f1:
  `approved` posts with a `refused_reason`). Rows carry `status`, `error`,
  `rejection_reason`, `rejected_at` and the refusal fields.
  """
  @spec list_posts(Ecto.UUID.t(), keyword() | map()) :: [Post.t()]
  def list_posts(org_id, filters \\ []) do
    filters = Map.new(filters)

    Post
    |> scoped_query(org_id)
    |> then(fn q ->
      case filters[:account_id] do
        nil -> q
        account_id -> where(q, [po], po.account_id == ^account_id)
      end
    end)
    |> then(fn q ->
      case filters[:profile_id] && Ecto.UUID.cast(filters[:profile_id]) do
        nil ->
          q

        {:ok, profile_id} ->
          account_ids = from(a in Account, where: a.profile_id == ^profile_id, select: a.id)
          where(q, [po], po.account_id in subquery(account_ids))

        :error ->
          where(q, false)
      end
    end)
    |> then(fn q ->
      case filters[:status] do
        nil -> q
        status -> where(q, [po], po.status == ^status)
      end
    end)
    |> then(fn q ->
      case filters[:statuses] do
        nil -> q
        statuses when is_list(statuses) -> where(q, [po], po.status in ^statuses)
      end
    end)
    |> then(fn q ->
      case filters[:placed_from] do
        %DateTime{} = from ->
          where(q, [po], fragment("coalesce(?, ?)", po.scheduled_at, po.approved_at) >= ^from)

        nil ->
          q
      end
    end)
    |> then(fn q ->
      case filters[:placed_to] do
        %DateTime{} = to ->
          where(q, [po], fragment("coalesce(?, ?)", po.scheduled_at, po.approved_at) < ^to)

        nil ->
          q
      end
    end)
    |> then(fn q ->
      case filters[:task_id] && Ecto.UUID.cast(filters[:task_id]) do
        nil -> q
        {:ok, task_id} -> where(q, [po], po.task_id == ^task_id)
        :error -> where(q, false)
      end
    end)
    |> then(fn q ->
      # Social authoring 1/11: posts on any of several profiles' accounts.
      case filters[:profile_ids] do
        nil ->
          q

        ids when is_list(ids) ->
          account_ids = from(a in Account, where: a.profile_id in ^ids, select: a.id)
          where(q, [po], po.account_id in subquery(account_ids))
      end
    end)
    |> then(fn q ->
      # Social authoring 1/11: last written at or after this time.
      case filters[:updated_from] do
        %DateTime{} = from -> where(q, [po], po.updated_at >= ^from)
        nil -> q
      end
    end)
    |> then(fn q ->
      # Social authoring 8/11's calendar: `[from, to)` on the placement that
      # also reads `published_at`: a published post sits where it went out
      # (`published_at`, else `scheduled_at`, else `approved_at`); any other
      # post where `:placed_from` puts it (`scheduled_at`, else `approved_at`).
      case {filters[:calendar_from], filters[:calendar_to]} do
        {%DateTime{} = from, %DateTime{} = to} ->
          where(
            q,
            [po],
            fragment(
              "CASE WHEN ? = 'published' THEN coalesce(?, ?, ?) ELSE coalesce(?, ?) END",
              po.status,
              po.published_at,
              po.scheduled_at,
              po.approved_at,
              po.scheduled_at,
              po.approved_at
            ) >= ^from and
              fragment(
                "CASE WHEN ? = 'published' THEN coalesce(?, ?, ?) ELSE coalesce(?, ?) END",
                po.status,
                po.published_at,
                po.scheduled_at,
                po.approved_at,
                po.scheduled_at,
                po.approved_at
              ) < ^to
          )

        _ ->
          q
      end
    end)
    |> then(fn q ->
      # Task 01a165f1: approved posts whose publish was refused before the vendor.
      if filters[:refused] == true,
        do: where(q, [po], po.status == "approved" and not is_nil(po.refused_reason)),
        else: q
    end)
    |> order_by([po], asc: po.inserted_at, asc: po.id)
    |> Repo.all()
  end

  @doc "Creates a post on an account in the caller's org. Refused on an archived account."
  @spec create_post(Ecto.UUID.t(), Account.t() | Ecto.UUID.t(), map()) ::
          {:ok, Post.t()} | {:error, term()}
  def create_post(org_id, account, attrs) do
    with {:ok, account} <- fetch(Account, org_id, account),
         :ok <- refuse_archived(account) do
      changeset =
        %Post{account_id: account.id}
        |> Post.changeset(attrs)
        |> ClipMedia.put_media_meta(account.profile_id)

      with :ok <- require_channel(changeset, account.profile_id, account),
           {:ok, post} <- Repo.insert(changeset) do
        {:ok, needs_approval_written(post)}
      end
    end
  end

  @doc """
  Updates a post. Scheduling (a `scheduled_at` or status `scheduled`) on an
  archived account is refused, and so is `needs_approval` on a profile with
  no channel (`{:error, :profile_has_no_channel}`).
  """
  @spec update_post(Ecto.UUID.t(), Post.t() | Ecto.UUID.t(), map()) ::
          {:ok, Post.t()} | {:error, term()}
  def update_post(org_id, post, attrs) do
    with {:ok, post} <- fetch(Post, org_id, post) do
      changeset =
        post
        |> Post.changeset(attrs)
        |> ClipMedia.put_media_meta(profile_id_of_account(post.account_id))

      with :ok <- refuse_scheduling_on_archived(org_id, post, changeset),
           :ok <-
             require_channel(changeset, profile_id_of(post), Repo.get(Account, post.account_id)),
           {:ok, updated} <- Repo.update(changeset) do
        {:ok, needs_approval_written(updated)}
      end
    end
  end

  @doc """
  A human sets or clears a video post's cover (task 01a165ec stage 2).
  `attrs` is one of:

    * `%{cover_file_id: id}`: an uploaded JPG/PNG in the post's org;
    * `%{cover_offset_ms: ms}`, optionally with `duration_ms` (the
      browser's `<video>.duration`, stored only when no duration is known);
    * `:clear` (or `%{clear: true}`): no cover.

  The actor is checked exactly as for the approval card's edit
  (`post_approver_check/4`, the rule `Approvals.decide_edit/4` applies),
  on the row locked `FOR UPDATE`; a post past `needs_approval` is
  `{:error, :post_locked}`. The cover goes through the one cover rule
  (`Platform.Social.Cover`), so a refusal is `{:error, changeset}`. A
  cover change changes `Approvals.fingerprint/1`, so a card shown before
  it is refused at approve with `:post_changed`.
  """
  @spec set_cover(Ecto.UUID.t(), term(), Ecto.UUID.t(), map() | :clear) ::
          {:ok, Post.t()} | {:error, term()}
  def set_cover(org_id, actor_user_id, post_id, attrs) do
    attrs = cover_attrs(attrs)

    with {:ok, post} <- fetch(Post, org_id, post_id) do
      Repo.transaction(fn ->
        locked = Repo.one(from(p in Post, where: p.id == ^post.id, lock: "FOR UPDATE"))

        with %Post{} <- locked || {:error, :not_found},
             :ok <- refuse_cover_locked(locked),
             {:ok, profile} <- profile_of_post(locked),
             account = Repo.get!(Account, locked.account_id),
             :ok <- post_approver_check(profile.org_id, profile, account, actor_user_id),
             ctx = %{org_id: profile.org_id, profile_id: profile.id},
             {:ok, updated} <- locked |> Post.cover_changeset(attrs, ctx) |> Repo.update() do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, updated} -> {:ok, needs_approval_written(updated)}
        error -> error
      end
    end
  end

  defp cover_attrs(:clear), do: %{cover_file_id: nil, cover_offset_ms: nil}

  defp cover_attrs(%{} = attrs) do
    if Map.get(attrs, :clear) == true or Map.get(attrs, "clear") == true,
      do: cover_attrs(:clear),
      else:
        Map.take(
          attrs,
          [:cover_file_id, :cover_offset_ms, :duration_ms] ++
            ~w(cover_file_id cover_offset_ms duration_ms)
        )
  end

  defp cover_attrs(_), do: %{}

  defp refuse_cover_locked(%Post{status: status}) when status in ~w(draft needs_approval),
    do: :ok

  defp refuse_cover_locked(%Post{}), do: {:error, :post_locked}

  # ── needs_approval (Social 3/7) ──────────────────────────────────────

  @doc """
  Refuses `needs_approval` while the approval card has nowhere to go:
  an UNOWNED account's card goes to its profile's channel
  (`social_profiles.space_id`), so a profile with no channel is
  `{:error, :profile_has_no_channel}`. An OWNED account (task 01a14ce1,
  stage 3) is satisfied by its owner: the card goes to the owner's DM, so
  no profile channel is needed. Called BEFORE the write by every path that
  can set the status (`create_post/3`, `update_post/3`,
  `Platform.Social.AgentDrafts`), so the row is unchanged.

  The 2-arity form knows no account and applies the unowned rule.
  """
  @spec require_channel(
          Ecto.Changeset.t() | String.t(),
          Ecto.UUID.t() | Profile.t(),
          Account.t() | nil
        ) :: :ok | {:error, :profile_has_no_channel}
  def require_channel(status, profile, account \\ nil)

  def require_channel(%Changeset{} = changeset, profile, account),
    do: require_channel(Changeset.get_field(changeset, :status), profile, account)

  def require_channel("needs_approval", _profile, %Account{owner_user_id: owner_id})
      when is_binary(owner_id),
      do: :ok

  def require_channel("needs_approval", %Profile{space_id: nil}, _account),
    do: {:error, :profile_has_no_channel}

  def require_channel("needs_approval", %Profile{}, _account), do: :ok

  def require_channel("needs_approval", profile_id, account) when is_binary(profile_id) do
    case Repo.get(Profile, profile_id) do
      %Profile{} = profile -> require_channel("needs_approval", profile, account)
      nil -> {:error, :profile_has_no_channel}
    end
  end

  def require_channel(_status, _profile, _account), do: :ok

  @doc """
  The ONE hook every write path calls after a post is committed: when the
  post is `needs_approval`, `Platform.Social.Approvals.request_approval/1`
  posts its approval card and inbox rows, or re-renders the live card when
  one exists (an agent re-edit). Returns the post unchanged. A fan-out
  failure is logged, never raised: the post is already saved.
  """
  @spec needs_approval_written(Post.t()) :: Post.t()
  def needs_approval_written(%Post{status: "needs_approval"} = post) do
    case Platform.Social.Approvals.request_approval(post) do
      {:ok, _} ->
        post

      {:error, reason} ->
        Logger.warning("[Social] approval fan-out for post #{post.id} failed: #{inspect(reason)}")
        post
    end
  end

  def needs_approval_written(%Post{} = post), do: post

  defp profile_id_of(%Post{account_id: account_id}) do
    Repo.one(from(a in Account, where: a.id == ^account_id, select: a.profile_id))
  end

  @spec delete_post(Ecto.UUID.t(), Post.t() | Ecto.UUID.t()) ::
          {:ok, Post.t()} | {:error, term()}
  def delete_post(org_id, post) do
    with {:ok, post} <- fetch(Post, org_id, post), do: Repo.delete(post)
  end

  @doc """
  Approves a post as `approver_user_id`, the ONLY path that sets the
  approver. Every caller is guarded by `post_approver_check/4` (Social
  3/7, owner rule task 01a14ce1) before any write:

    * an id that is not a user (an agent id included) is a changeset error
      on `:approved_by_user_id`, "must be a human user" (member 1's text,
      kept; the error's metadata carries `reason: :not_a_human`);
    * an archived user is `{:error, :approver_archived}`;
    * a user not in the profile's `approver_user_ids` is
      `{:error, :not_an_approver}`;
    * a user who can no longer read the profile's org is
      `{:error, :approver_no_access}`;
    * on an account with an owner, anyone but the owner is
      `{:error, :not_the_owner}`, and an archived owner is
      `{:error, :approver_archived}`.

  Pass `lock: true` from inside a transaction to re-read the post `FOR
  UPDATE` (`Platform.Social.Approvals` does).
  """
  @spec approve_post(Ecto.UUID.t(), Post.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Post.t()} | {:error, term()}
  def approve_post(org_id, post, approver_user_id, opts \\ []) do
    with {:ok, post} <- fetch_for_approval(org_id, post, opts),
         :ok <- refuse_approved_again(post),
         {:ok, profile} <- profile_of_post(post),
         {:ok, account} <- account_of_post(post) do
      changeset = Post.approval_changeset(post, approver_user_id)

      case post_approver_check(profile.org_id, profile, account, approver_user_id) do
        :ok ->
          Repo.update(changeset)

        {:error, :not_a_human} ->
          {:error,
           Changeset.add_error(changeset, :approved_by_user_id, @not_a_user, reason: :not_a_human)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_for_approval(org_id, post, opts) do
    if Keyword.get(opts, :lock, false) do
      case lock_post(org_id, post_id(post)) do
        nil -> {:error, :not_found}
        post -> {:ok, post}
      end
    else
      fetch(Post, org_id, post)
    end
  end

  defp account_of_post(%Post{account_id: account_id}) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  defp post_id(%Post{id: id}), do: id
  defp post_id(id), do: id

  @doc false
  # The profile a post belongs to (through its account), unscoped: callers
  # have already read the post through the scope.
  @spec profile_of_post(Post.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def profile_of_post(%Post{account_id: account_id}) do
    case Repo.one(
           from(p in Profile,
             join: a in Account,
             on: a.profile_id == p.id,
             where: a.id == ^account_id
           )
         ) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  # ── Approver guard (Social 3/7) ──────────────────────────────────────

  @typedoc "Why `approver_check/3` or `post_approver_check/4` refused."
  @type approver_refusal ::
          :not_a_human
          | :approver_archived
          | :not_an_approver
          | :approver_no_access
          | :not_the_owner

  @doc """
  Whether `user_id` may approve, edit or reject posts of `profile` RIGHT
  NOW. Checked in this order, each a distinct refusal:

    1. the id resolves to a users row through `Platform.Accounts.get_user/1`,
       re-read from the database on every call (an agents row does not),
       else `:not_a_human`;
    2. `archived_at` is nil (`get_user/1` returns archived users), else
       `:approver_archived`;
    3. the id is in `profile.approver_user_ids`, else `:not_an_approver`;
    4. `approver_access?/2` (the RBAC SWAP POINT), else `:approver_no_access`.

  `org_id` must be the profile's org; anything else is `:approver_no_access`.
  """
  @spec approver_check(Ecto.UUID.t(), Profile.t(), term()) :: :ok | {:error, approver_refusal()}
  def approver_check(org_id, %Profile{} = profile, user_id) do
    with {:ok, user} <- live_user(user_id),
         :ok <- not_archived(user),
         :ok <- on_list(profile, user.id) do
      if org_id == profile.org_id and approver_access?(user, profile),
        do: :ok,
        else: {:error, :approver_no_access}
    end
  end

  @doc """
  Whether `user_id` may approve or edit posts on `account` RIGHT NOW
  (task 01a14ce1). Every approve and edit path goes through this, not
  `approver_check/3`, which stays the rule for managing the profile
  (connections, settings).

    * an account with no `owner_user_id` is exactly `approver_check/3`;
    * an owned account: the id must resolve to a users row (else
      `:not_a_human`, an agent id included), must BE the owner (else
      `:not_the_owner`, a profile approver included), must not be archived
      (else `:approver_archived`), and must pass `approver_access?/2` on the
      profile's org (else `:approver_no_access`). The owner need not be on
      `approver_user_ids`. There is NO fallback to the profile approvers
      when the owner is archived or gone.

  The owner is re-read from `account.owner_user_id` as given; callers pass
  an account row read in the same request, never an assign.
  """
  @spec post_approver_check(Ecto.UUID.t(), Profile.t(), Account.t(), term()) ::
          :ok | {:error, approver_refusal()}
  def post_approver_check(org_id, %Profile{} = profile, %Account{owner_user_id: nil}, user_id),
    do: approver_check(org_id, profile, user_id)

  def post_approver_check(org_id, %Profile{} = profile, %Account{} = account, user_id) do
    with {:ok, user} <- live_user(user_id),
         :ok <- the_owner(account, user.id),
         :ok <- not_archived(user) do
      if org_id == profile.org_id and approver_access?(user, profile),
        do: :ok,
        else: {:error, :approver_no_access}
    end
  end

  @doc """
  Whether `user_id` may REJECT a post on `account` RIGHT NOW. The same as
  `post_approver_check/4`, with one exception so posts are not stranded:
  when the account's owner is archived or no longer a users row, a user who
  passes `approver_check/3` on the profile may reject (never approve or
  edit). With a live owner, only the owner may reject.
  """
  @spec post_rejecter_check(Ecto.UUID.t(), Profile.t(), Account.t(), term()) ::
          :ok | {:error, approver_refusal()}
  def post_rejecter_check(org_id, %Profile{} = profile, %Account{} = account, user_id) do
    case post_approver_check(org_id, profile, account, user_id) do
      :ok ->
        :ok

      {:error, _} = refused ->
        if owner_gone?(account),
          do: approver_check(org_id, profile, user_id),
          else: refused
    end
  end

  defp the_owner(%Account{owner_user_id: owner_id}, user_id) do
    if owner_id == user_id, do: :ok, else: {:error, :not_the_owner}
  end

  defp owner_gone?(%Account{owner_user_id: nil}), do: false

  defp owner_gone?(%Account{owner_user_id: owner_id}) do
    case live_user(owner_id) do
      {:ok, owner} -> not_archived(owner) != :ok
      {:error, _} -> true
    end
  end

  defp live_user(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %Platform.Accounts.User{} = user -> {:ok, user}
      _ -> {:error, :not_a_human}
    end
  end

  defp not_archived(%{archived_at: nil}), do: :ok
  defp not_archived(_user), do: {:error, :approver_archived}

  defp on_list(%Profile{approver_user_ids: ids}, user_id) do
    if user_id in (ids || []), do: :ok, else: {:error, :not_an_approver}
  end

  @doc """
  RBAC SWAP POINT (approver access, Social 3/7): whether `user` may still
  read `profile`'s org at the moment of the click. `Platform.Access` is not
  on this base (`git cat-file -e <base>:apps/platform/lib/platform/access.ex`
  fails), so this is `Platform.Tenancy.visibility/1`: allowed iff it answers
  `:root_all` or `{:orgs, ids}` with the profile's org in `ids`. Once RBAC
  member 5 lands, register a resource-scoped `social.approve` permission on
  the profile and replace this body (and the `approver_user_ids` membership
  test) with `Platform.Access.can?/3`.
  """
  @spec approver_access?(Platform.Accounts.User.t(), Profile.t()) :: boolean()
  def approver_access?(user, %Profile{org_id: org_id}) do
    case Platform.Tenancy.visibility(user) do
      :root_all -> true
      {:orgs, ids} -> org_id in ids
      _ -> false
    end
  end

  @doc """
  Posts across the profiles `user` may see (Social authoring 1/11, the
  "All brands" scope). The profile ids ALWAYS come from
  `list_profiles_for_user/1`, read now: `scope` is `:all` or a list of ids
  that can only NARROW that set (an id the user cannot see is dropped, never
  read). `filters` are `list_posts/2`'s, minus `:profile_id`/`:profile_ids`.
  Each org is read through its own scope; rows come back oldest first.
  """
  @spec list_posts_for_profiles(
          Platform.Accounts.User.t() | nil,
          :all | [Ecto.UUID.t()],
          keyword() | map()
        ) :: [Post.t()]
  def list_posts_for_profiles(user, scope, filters \\ []) do
    filters = filters |> Map.new() |> Map.drop([:profile_id, :profile_ids])

    user
    |> scoped_profiles(scope)
    |> Enum.group_by(& &1.org_id, & &1.id)
    |> Enum.flat_map(fn {org_id, ids} ->
      list_posts(org_id, Map.put(filters, :profile_ids, ids))
    end)
    |> Enum.sort_by(&{&1.inserted_at, &1.id}, fn {a, ida}, {b, idb} ->
      case DateTime.compare(a, b) do
        :lt -> true
        :gt -> false
        :eq -> ida <= idb
      end
    end)
  end

  @doc """
  The accounts of the profiles `user` may see, with the same `scope` rule as
  `list_posts_for_profiles/3` (ids from `list_profiles_for_user/1`, never
  widened by the caller). `opts` are `list_accounts/2`'s
  (`:include_archived`; archived accounts are omitted by default).
  """
  @spec list_accounts_for_profiles(
          Platform.Accounts.User.t() | nil,
          :all | [Ecto.UUID.t()],
          keyword()
        ) :: [Account.t()]
  def list_accounts_for_profiles(user, scope, opts \\ []) do
    opts = Keyword.delete(opts, :profile_id)

    user
    |> scoped_profiles(scope)
    |> Enum.group_by(& &1.org_id, & &1.id)
    |> Enum.flat_map(fn {org_id, ids} ->
      org_id |> list_accounts(opts) |> Enum.filter(&(&1.profile_id in ids))
    end)
  end

  defp scoped_profiles(nil, _scope), do: []
  defp scoped_profiles(user, :all), do: list_profiles_for_user(user)

  defp scoped_profiles(user, ids) when is_list(ids),
    do: user |> list_profiles_for_user() |> Enum.filter(&(&1.id in ids))

  @doc """
  The profiles `user` may see, ordered by name (Social 7/7, the Social tab's
  switcher). Built on the two swap points: `Platform.Tenancy.visibility/1`
  says which orgs the user reads (`:root_all`, `{:orgs, ids}` or `:none`),
  and each answer goes through `visible_orgs/1`, so a move to
  Platform.Access changes the same two places as every other read. A user
  who sees org A only never gets a profile of org B.
  """
  @spec list_profiles_for_user(Platform.Accounts.User.t() | nil) :: [Profile.t()]
  def list_profiles_for_user(user) do
    orgs =
      case Platform.Tenancy.visibility(user) do
        :root_all -> visible_orgs(:root)
        {:orgs, ids} -> Enum.flat_map(ids, &visible_orgs/1)
        _ -> []
      end

    case orgs do
      [] ->
        []

      :all ->
        Profile |> order_by([p], asc: p.name, asc: p.id) |> Repo.all()

      org_ids ->
        Profile
        |> org_filter(org_ids)
        |> order_by([p], asc: p.name, asc: p.id)
        |> Repo.all()
    end
  end

  @doc """
  Needs-approval post counts per profile, `%{profile_id => n}`, in ONE
  grouped query; every id given is a key (0 when it has none). The caller
  passes ids it already read through the scope (`list_profiles_for_user/1`).
  """
  @spec needs_approval_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  def needs_approval_counts([]), do: %{}

  def needs_approval_counts(profile_ids) when is_list(profile_ids) do
    counts =
      from(po in Post,
        join: a in Account,
        on: a.id == po.account_id,
        where: a.profile_id in ^profile_ids and po.status == "needs_approval",
        group_by: a.profile_id,
        select: {a.profile_id, count(po.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(profile_ids, &{&1, Map.get(counts, &1, 0)})
  end

  # Approval moves a draft (or a post awaiting approval) to approved; it never
  # rewinds a post that is already approved, scheduled, published or failed.
  defp refuse_approved_again(%Post{status: status}) when status in ~w(draft needs_approval),
    do: :ok

  defp refuse_approved_again(%Post{}), do: {:error, :not_approvable}

  defp refuse_archived(%Account{archived_at: nil}), do: :ok
  defp refuse_archived(%Account{}), do: {:error, :account_archived}

  defp refuse_scheduling_on_archived(org_id, post, changeset) do
    scheduling? =
      Changeset.get_change(changeset, :scheduled_at) != nil or
        Changeset.get_change(changeset, :status) == "scheduled"

    if scheduling? do
      case fetch(Account, org_id, post.account_id) do
        {:ok, account} -> refuse_archived(account)
        error -> error
      end
    else
      :ok
    end
  end

  # ── Clips ────────────────────────────────────────────────────────────

  @spec get_clip(Ecto.UUID.t(), Ecto.UUID.t()) :: Clip.t() | nil
  def get_clip(org_id, id), do: scoped_get(Clip, org_id, id)

  @doc "Lists the org's clips. Options: `:profile_id`, `:status`."
  @spec list_clips(Ecto.UUID.t(), keyword()) :: [Clip.t()]
  def list_clips(org_id, opts \\ []) do
    Clip
    |> scoped_query(org_id)
    |> filter_profile(opts[:profile_id])
    |> then(fn q ->
      case opts[:status] do
        nil -> q
        status -> where(q, [c], c.status == ^status)
      end
    end)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> Repo.all()
  end

  @spec create_clip(Ecto.UUID.t(), Profile.t() | Ecto.UUID.t(), map()) ::
          {:ok, Clip.t()} | {:error, term()}
  def create_clip(org_id, profile, attrs) do
    with {:ok, profile} <- fetch(Profile, org_id, profile) do
      %Clip{profile_id: profile.id} |> Clip.changeset(attrs) |> Repo.insert()
    end
  end

  @spec update_clip(Ecto.UUID.t(), Clip.t() | Ecto.UUID.t(), map()) ::
          {:ok, Clip.t()} | {:error, term()}
  def update_clip(org_id, clip, attrs) do
    with {:ok, clip} <- fetch(Clip, org_id, clip),
         do: clip |> Clip.changeset(attrs) |> Repo.update()
  end

  @spec delete_clip(Ecto.UUID.t(), Clip.t() | Ecto.UUID.t()) ::
          {:ok, Clip.t()} | {:error, term()}
  def delete_clip(org_id, clip) do
    with {:ok, clip} <- fetch(Clip, org_id, clip), do: Repo.delete(clip)
  end

  # Clip decisions (Clip Studio 2/9)
  #
  # A human's one-step clip decision (task 01a16662): see
  # `Platform.Social.ClipDecisions`. Each takes opts with an injectable `:now`.

  defdelegate approve_clip(org_id, clip_id, user_id, attrs, opts \\ []),
    to: Platform.Social.ClipDecisions

  defdelegate reject_clip(org_id, clip_id, user_id, note, opts \\ []),
    to: Platform.Social.ClipDecisions

  defdelegate undo_clip_decision(org_id, clip_id, user_id, opts \\ []),
    to: Platform.Social.ClipDecisions

  defdelegate retry_post(org_id, post_id, user_id), to: Platform.Social.ClipDecisions

  # ── Clip rendering (Social 5/7) ──────────────────────────────────────

  @render_from ~w(candidate failed)

  @doc """
  The PubSub topic a profile's clip status changes go out on, as
  `{:social_clip, %Clip{}}` (member 7's screen subscribes).
  """
  @spec clips_topic(Ecto.UUID.t()) :: String.t()
  def clips_topic(profile_id), do: "social:clips:#{profile_id}"

  @doc false
  def broadcast_clip(%Clip{} = clip) do
    Phoenix.PubSub.broadcast(Platform.PubSub, clips_topic(clip.profile_id), {:social_clip, clip})
  end

  @doc """
  The project a profile's renders are stored under, which must exist and
  belong to the profile's org: an org-less project is readable by every
  logged-in user through Files, so it is refused.
  """
  @spec render_project(Profile.t()) :: {:ok, map()} | {:error, String.t()}
  def render_project(%Profile{project_id: nil}), do: {:error, profile_needs_project()}

  def render_project(%Profile{project_id: project_id, org_id: org_id}) do
    case Platform.Tasks.get_project(project_id) do
      %{org_id: ^org_id} = project when not is_nil(org_id) -> {:ok, project}
      _ -> {:error, profile_needs_project()}
    end
  end

  @doc "The readable refusal for a profile without a project in its org."
  @spec profile_needs_project() :: String.t()
  def profile_needs_project,
    do:
      "This profile has no project to store renders in. An approver can set one in Social › Settings › Project for renders."

  @doc """
  Queues a clip for rendering and returns at once with the clip in
  `rendering`; the render runs in `Platform.Social.RenderQueue`.

  Only a `candidate` or `failed` clip renders; a `rendered` one needs
  `force: true`; one already `rendering` is `{:error, :already_rendering}`.
  `:platforms` defaults to the platforms of the profile's non-archived
  accounts and must be among them. The profile's project is checked
  before anything is queued (`{:error, :profile_needs_project}`).
  Out-of-scope reads as `{:error, :not_found}`.
  """
  @spec render_clip(scope(), term(), keyword() | map()) ::
          {:ok, Clip.t()}
          | {:error,
             :not_found
             | :already_rendering
             | :already_rendered
             | :profile_needs_project
             | {:invalid_platforms, [String.t()]}}
  def render_clip(scope, clip_id, opts \\ []) do
    opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

    with {:ok, clip} <- fetch(Clip, scope, clip_id),
         :ok <- renderable(clip, opts["force"] == true),
         profile = Repo.get!(Profile, clip.profile_id),
         {:ok, _project} <- project_or_error(profile),
         {:ok, platforms} <- render_platforms(profile, opts["platforms"]),
         {:ok, clip} <- mark_rendering(clip, platforms) do
      RenderQueue.enqueue(clip.id, Map.get(opts, "queue", RenderQueue))
      broadcast_clip(clip)
      {:ok, clip}
    end
  end

  defp renderable(%Clip{status: status}, _force) when status in @render_from, do: :ok
  defp renderable(%Clip{status: "rendered"}, true), do: :ok
  defp renderable(%Clip{status: "rendered"}, _), do: {:error, :already_rendered}
  defp renderable(%Clip{status: "rendering"}, _), do: {:error, :already_rendering}

  defp project_or_error(profile) do
    case render_project(profile) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> {:error, :profile_needs_project}
    end
  end

  defp render_platforms(profile, requested) do
    available =
      from(a in Account,
        where: a.profile_id == ^profile.id and is_nil(a.archived_at),
        select: a.platform,
        distinct: true
      )
      |> Repo.all()

    case requested do
      nil ->
        {:ok, Enum.sort(available)}

      [] ->
        {:ok, Enum.sort(available)}

      list when is_list(list) ->
        case Enum.reject(list, &(&1 in available)) do
          [] -> {:ok, Enum.uniq(list)}
          bad -> {:error, {:invalid_platforms, Enum.map(bad, &to_string/1)}}
        end

      _ ->
        {:error, {:invalid_platforms, [inspect(requested)]}}
    end
  end

  # Conditional on the status read, so two concurrent calls cannot both
  # queue the same clip.
  defp mark_rendering(clip, platforms) do
    query = from(c in Clip, where: c.id == ^clip.id and c.status == ^clip.status, select: c)

    case Repo.update_all(query,
           set: [
             status: "rendering",
             platforms: platforms,
             error: nil,
             updated_at: DateTime.utc_now()
           ]
         ) do
      {1, [clip]} -> {:ok, clip}
      _ -> {:error, :already_rendering}
    end
  end

  defp profile_id_of_account(account_id) do
    Repo.one(from(a in Account, where: a.id == ^account_id, select: a.profile_id))
  end
end
