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
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social.{Account, Clip, ClipMedia, Post, Profile, Publisher, RenderQueue}

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

  @spec create_profile(Ecto.UUID.t(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def create_profile(org_id, attrs) do
    case Ecto.UUID.cast(org_id) do
      {:ok, org_id} ->
        %Profile{org_id: org_id}
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
        case Platform.Tasks.get_project(project_id) do
          %{org_id: ^org_id} -> changeset
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
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> limit(1)
    |> Repo.one()
  end

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
  has no published-at column). Rows carry `status`, `error`,
  `rejection_reason` and `rejected_at`.
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

      with :ok <- require_channel(changeset, account.profile_id),
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
           :ok <- require_channel(changeset, profile_id_of(post)),
           {:ok, updated} <- Repo.update(changeset) do
        {:ok, needs_approval_written(updated)}
      end
    end
  end

  # ── needs_approval (Social 3/7) ──────────────────────────────────────

  @doc """
  Refuses `needs_approval` while the post's profile has no channel
  (`social_profiles.space_id`): the approval card has nowhere to go. Called
  BEFORE the write by every path that can set the status (`create_post/3`,
  `update_post/3`, `Platform.Social.AgentDrafts`), so the row is unchanged.
  """
  @spec require_channel(Ecto.Changeset.t() | String.t(), Ecto.UUID.t() | Profile.t()) ::
          :ok | {:error, :profile_has_no_channel}
  def require_channel(%Changeset{} = changeset, profile),
    do: require_channel(Changeset.get_field(changeset, :status), profile)

  def require_channel("needs_approval", %Profile{space_id: nil}),
    do: {:error, :profile_has_no_channel}

  def require_channel("needs_approval", %Profile{}), do: :ok

  def require_channel("needs_approval", profile_id) when is_binary(profile_id) do
    case Repo.get(Profile, profile_id) do
      %Profile{} = profile -> require_channel("needs_approval", profile)
      nil -> {:error, :profile_has_no_channel}
    end
  end

  def require_channel(_status, _profile), do: :ok

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
  approver. Every caller is guarded by `approver_check/3` (Social 3/7)
  before any write:

    * an id that is not a user (an agent id included) is a changeset error
      on `:approved_by_user_id`, "must be a human user" (member 1's text,
      kept; the error's metadata carries `reason: :not_a_human`);
    * an archived user is `{:error, :approver_archived}`;
    * a user not in the profile's `approver_user_ids` is
      `{:error, :not_an_approver}`;
    * a user who can no longer read the profile's org is
      `{:error, :approver_no_access}`.

  Pass `lock: true` from inside a transaction to re-read the post `FOR
  UPDATE` (`Platform.Social.Approvals` does).
  """
  @spec approve_post(Ecto.UUID.t(), Post.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Post.t()} | {:error, term()}
  def approve_post(org_id, post, approver_user_id, opts \\ []) do
    with {:ok, post} <- fetch_for_approval(org_id, post, opts),
         :ok <- refuse_approved_again(post),
         {:ok, profile} <- profile_of_post(post) do
      changeset = Post.approval_changeset(post, approver_user_id)

      case approver_check(profile.org_id, profile, approver_user_id) do
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

  @typedoc "Why `approver_check/3` refused."
  @type approver_refusal ::
          :not_a_human | :approver_archived | :not_an_approver | :approver_no_access

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
      "the profile needs a project in its org to store renders in; set the profile's project first"

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
