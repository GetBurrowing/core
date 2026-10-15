defmodule Platform.SignInAdmin do
  @moduledoc """
  Manage the install's sign-in users (the bundled pocket-id) from Suite (task
  01a113ea-3ef4-7001-b3fc-5d0a1bafc5df).

  This context orchestrates two systems: pocket-id, through
  `Platform.SignInAdmin.PocketId`, and Suite's own users, through
  `Platform.Accounts` and `Platform.Tenancy`. **It never writes a Suite user
  itself.** Every user row change goes through an Accounts function
  (`find_or_create_from_oidc/1`, `relink_oidc_identity/2`, `archive_user/2`,
  `unarchive_user/1`, `note_sign_in_link_expiry/2`) and every role change
  through a Tenancy membership helper.
  `Platform.SignInAdmin.AccountsBoundaryTest` (syntactic) and the
  identical-rows test in `Platform.SignInAdminTest` (behavioural) hold that
  line.

  ## Authorization, on every call

  Every public function takes the acting user first and starts with
  `authorize/1`:

    * `{:error, :not_found}` when `Platform.SignInAdmin.Config.enabled?/0`
      is false, so an install without the switch has no such feature;
    * `{:error, :unauthorized}` unless `Platform.Access.authorize_install/1`
      is `:ok`, a fresh database read on every call (an admin demoted
      mid-session is refused on their next action). Until task
      01a1386d-fb6e stage 2 this was `Tenancy.root_admin?/1`; the Access check
      answers the same for every internal actor and is STRICTER for exactly
      one class, the external root admin (guest dominates,
      `0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`),
      who is now refused here too. The `ExternalUserScope` plug already refuses
      that user over HTTP, so HTTP outcomes are unchanged.

  Nothing reaches pocket-id or Accounts before both pass.

  ## How an invited user signs in later

  Suite links an OIDC login to a user by `oidc_sub` only, and pocket-id's
  `sub` is its user id. An invite creates (or adopts) the pocket-id user and
  then calls `Accounts.find_or_create_from_oidc/1` with that id as `sub`, the
  very call a first real login makes, so the later real login takes its
  UPDATE path and finds the same row.

  ## Remove is soft

  `remove/2` deletes the pocket-id identity (and its passkeys) and archives
  the Suite user. The users row, and every message, task, file, memory entry
  and membership attributed to it, stays. A later invite of the same email
  takes the restore path: a new pocket-id identity relinked onto the SAME
  Suite user id.

  ## Secrets

  A minted link is returned as a `Platform.SignInAdmin.Link`, whose `inspect/1`
  redacts the url and the code. Log lines carry ids and atoms only, e.g.

      sign_in_admin.invite suite_user_id=<id> path=create

  The link is never logged and never stored. Only its expiry is, as the
  Suite user's `sign_in_link_expires_at` (see below).

  ## Enable waits for every link this module minted to expire

  pocket-id v2.18.0 has no route to revoke a one-time token, and a token a
  disabled user tries to redeem is consumed and then restored, so a link sent
  before a Disable works again the moment the user is enabled. Every link
  `mint_link/2` returns is first recorded with
  `Accounts.note_sign_in_link_expiry/2` (fail closed: no record, no link), and
  `enable/3` refuses with `{:error, {:sign_in_link_live, until}}` while the
  recorded expiry is in the future, before any pocket-id request. The one
  exception is `undo: true` within 30 seconds of the Disable, which the
  Users page's Undo uses: undo means the Disable never happened (task
  01a114c1).

  This guard covers links minted by `Platform.SignInAdmin` (invite and
  resend) and nothing else. A link minted in pocket-id's own admin UI, or
  the installer's first-admin link, is not recorded, and Enable does not
  wait for it.
  """

  require Logger

  alias Platform.Access
  alias Platform.Accounts
  alias Platform.Access.Delegation
  alias Platform.SignInAdmin.{Config, Link, PocketId}
  alias Platform.Tenancy

  @passkey_concurrency 8
  @passkey_timeout 5_000
  # Must stay above 15 minutes: pocket-id mints a 6-character code at 15m or
  # less, and that code never auto-submits from `/lc/<code>`. The value sent
  # to pocket-id lives in `PocketId.one_time_token/1`; this one only stamps
  # `Link.expires_at`.
  @link_ttl_seconds 30 * 60
  @link_redirect "?redirect=%2Fsettings%2Faccount"
  # How long after a Disable `enable(actor, id, undo: true)` may skip the
  # live-link check. The Users page's Undo banner lasts 8 seconds.
  @undo_window_seconds 30
  @disabled_reason "sign-in disabled"

  @type actor :: %{:id => binary(), optional(atom()) => any()}
  @type status :: :active | :pending | :disabled | :no_identity | :not_in_suite
  @type row :: %{
          user: Accounts.User.t() | nil,
          pocket_id: PocketId.User.t() | nil,
          status: status(),
          passkeys: non_neg_integer() | nil
        }

  # -- list -----------------------------------------------------------------

  @doc """
  Every Suite user (archived included) joined to every pocket-id user on
  `oidc_sub == pocket_id.id`, each with a status:

    * `:disabled`: the pocket-id user is disabled;
    * `:pending`: the pocket-id user has no passkey yet;
    * `:active`: the pocket-id user has at least one passkey;
    * `:no_identity`: a Suite user with no pocket-id user;
    * `:not_in_suite`: a pocket-id user with no Suite row.

  Returns `{:error, :unreachable}` when pocket-id cannot be listed or any
  passkey count fails or times out: a partial table would show real users
  with a wrong status.
  """
  @spec list_users(actor()) ::
          {:ok, [row()]} | {:error, :not_found | :unauthorized | :unreachable}
  def list_users(actor) do
    with :ok <- authorize(actor),
         {:ok, identities} <- reachable(PocketId.list_users()) do
      suite_users = Accounts.list_users(include_archived: true)
      by_id = Map.new(identities, &{&1.id, &1})

      matched =
        Enum.map(suite_users, fn user -> {user, Map.get(by_id, user.oidc_sub)} end)

      linked_ids = MapSet.new(matched, fn {user, _} -> user.oidc_sub end)

      to_count =
        for {_user, %PocketId.User{disabled: false} = identity} <- matched, do: identity.id

      with {:ok, counts} <- passkey_counts(to_count) do
        suite_rows = Enum.map(matched, fn {user, identity} -> row(user, identity, counts) end)

        orphan_rows =
          for identity <- identities, not MapSet.member?(linked_ids, identity.id) do
            %{user: nil, pocket_id: identity, status: :not_in_suite, passkeys: nil}
          end

        {:ok, suite_rows ++ orphan_rows}
      end
    end
  end

  defp row(user, nil, _counts),
    do: %{user: user, pocket_id: nil, status: :no_identity, passkeys: nil}

  defp row(user, %PocketId.User{disabled: true} = identity, _counts),
    do: %{user: user, pocket_id: identity, status: :disabled, passkeys: nil}

  defp row(user, identity, counts) do
    count = Map.fetch!(counts, identity.id)
    status = if count == 0, do: :pending, else: :active
    %{user: user, pocket_id: identity, status: status, passkeys: count}
  end

  defp passkey_counts(ids) do
    ids
    |> Task.async_stream(fn id -> {id, PocketId.passkey_count(id)} end,
      max_concurrency: @passkey_concurrency,
      timeout: @passkey_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {id, {:ok, count}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, id, count)}}
      _failed, _acc -> {:halt, {:error, :unreachable}}
    end)
  end

  # -- invite ---------------------------------------------------------------

  @doc """
  Invite a person: give them a pocket-id identity and a Suite user, set their
  Suite role, and mint a 30-minute sign-in link.

  `attrs` carries `:email` (required), `:name` (optional; falls back to the
  email's local part) and `:role` (`:member` or `:admin`, or the same as a
  string).

    * An ACTIVE Suite user with that email: `{:error, :already_exists}`.
    * An ARCHIVED Suite user with that email (an earlier `remove/2`): the
      restore path. A new pocket-id user is created and relinked onto the
      same Suite user id with `Accounts.relink_oidc_identity/2`.
    * Otherwise: adopt a pocket-id user that already has the email and no
      Suite row, or create one; then `Accounts.find_or_create_from_oidc/1`
      creates the Suite user and its root membership.

  The role is then set with `Tenancy.promote_to_admin/2` or
  `Tenancy.revoke_admin/2`, which also lock it against the email-domain rule.

  If a step after this call CREATED a pocket-id user fails, that pocket-id
  user is deleted again; an adopted one never is. A failed role step also
  archives the new Suite user (reason "invite failed"), so no
  half-provisioned active user is left and a re-invite takes the restore
  path.
  """
  @spec invite(actor(), map()) ::
          {:ok, %{user: Accounts.User.t(), link: Link.t()}} | {:error, term()}
  def invite(actor, attrs) when is_map(attrs) do
    with :ok <- authorize(actor),
         {:ok, email, name, role} <- normalize_invite(attrs) do
      case suite_user_by_email(email) do
        %{archived_at: nil} -> {:error, :already_exists}
        %{archived_at: %DateTime{}} = archived -> restore(actor, archived, email, name, role)
        nil -> provision(actor, email, name, role)
      end
    end
  end

  defp restore(actor, archived, email, name, role) do
    with {:ok, identity} <- PocketId.create_user(%{email: email, name: name}) do
      case Accounts.relink_oidc_identity(archived, identity.id) do
        {:ok, user} -> finish_invite(actor, user, identity, true, role, "restore")
        {:error, _} = error -> compensate(identity, true, error)
      end
    end
  end

  defp provision(actor, email, name, role) do
    with {:ok, identity, created?} <- identity_for(email, name),
         :ok <- sub_unclaimed(identity, created?) do
      case Accounts.find_or_create_from_oidc(%{sub: identity.id, email: email, name: name}) do
        {:ok, user} ->
          finish_invite(actor, user, identity, created?, role, path_name(created?))

        {:error, _} = error ->
          compensate(identity, created?, error)
      end
    end
  end

  defp path_name(true), do: "create"
  defp path_name(false), do: "adopt"

  # The adopt branch leaves an existing pocket-id user's name as it is.
  defp identity_for(email, name) do
    case PocketId.find_by_email(email) do
      {:ok, %PocketId.User{} = existing} ->
        {:ok, existing, false}

      {:ok, nil} ->
        with {:ok, created} <- PocketId.create_user(%{email: email, name: name}) do
          {:ok, created, true}
        end

      {:error, _} = error ->
        error
    end
  end

  # A Suite row already holding this sub would make the Accounts call take
  # its UPDATE path and rewrite that person's email to the invitee's. Refuse
  # instead of re-pointing someone else's account.
  defp sub_unclaimed(identity, created?) do
    if Enum.any?(Accounts.list_users(include_archived: true), &(&1.oidc_sub == identity.id)) do
      compensate(identity, created?, {:error, :identity_in_use})
    else
      :ok
    end
  end

  defp finish_invite(actor, user, identity, created?, role, path) do
    case set_role(user, role, actor) do
      {:ok, _membership} ->
        Logger.info("sign_in_admin.invite suite_user_id=#{user.id} path=#{path}")

        case mint_link(user, identity.id) do
          {:ok, link, user} ->
            {:ok, %{user: user, link: link}}

          {:error, _} ->
            Logger.warning("sign_in_admin.invite_link_failed suite_user_id=#{user.id}")
            {:error, :link_failed}
        end

      {:error, _} = error ->
        _ = Accounts.archive_user(user, actor: actor, reason: "invite failed")
        compensate(identity, created?, error)
    end
  end

  defp set_role(user, :admin, actor), do: Tenancy.promote_to_admin(user, actor_id: actor.id)
  defp set_role(user, :member, actor), do: demote_unless_last_admin(user, actor)

  defp demote_unless_last_admin(user, actor) do
    root_org_id = Tenancy.get_root_org().id
    memberships = Tenancy.list_user_memberships(user)

    last_admin_org =
      Enum.find(memberships, fn membership ->
        membership.org_id == root_org_id and membership.role == "admin" and
          case Delegation.managers({:org, membership.org_id}) do
            [%{id: id}] -> id == user.id
            _ -> false
          end
      end)

    if last_admin_org do
      {:error,
       %{missing: "access.manage", resource: {:org, last_admin_org.org_id}, rule: :last_admin}}
    else
      Tenancy.revoke_admin(user, actor_id: actor.id)
    end
  end

  defp compensate(identity, true, error) do
    case PocketId.delete_user(identity.id) do
      :ok ->
        :ok

      {:error, _} ->
        Logger.warning("sign_in_admin.compensation_failed pocket_id_user_id=#{identity.id}")
    end

    error
  end

  defp compensate(_identity, false, error), do: error

  # -- resend / disable / enable / remove ------------------------------------

  @doc """
  Mint a fresh 30-minute sign-in link for a user. Refused for a user whose
  pocket-id identity is disabled (`:disabled`) or missing (`:no_identity`),
  and for an archived Suite user (`:archived`), who could not complete a
  sign-in anyway.
  """
  @spec resend_link(actor(), term()) :: {:ok, Link.t()} | {:error, term()}
  def resend_link(actor, user_id) do
    with :ok <- authorize(actor),
         {:ok, user} <- fetch_user(user_id),
         {:ok, identity} <- identity_of(user),
         :ok <- not_disabled(identity),
         :ok <- not_archived(user) do
      Logger.info("sign_in_admin.resend_link suite_user_id=#{user.id}")

      with {:ok, link, _user} <- mint_link(user, identity.id), do: {:ok, link}
    end
  end

  @doc """
  Disable a user's sign-in: pocket-id refuses them at token exchange,
  passkey login and JWT, and the Suite user is archived (reason "sign-in
  disabled"), which drops any live session. Refuses the actor's own id with
  `{:error, :self}`.
  """
  @spec disable(actor(), term()) :: {:ok, Accounts.User.t()} | {:error, term()}
  def disable(actor, user_id) do
    with :ok <- authorize(actor),
         :ok <- not_self(actor, user_id),
         {:ok, user} <- fetch_user(user_id),
         {:ok, _identity} <- set_disabled(user, true) do
      Logger.info("sign_in_admin.disable suite_user_id=#{user.id}")
      Accounts.archive_user(user, actor: actor, reason: @disabled_reason)
    end
  end

  @doc """
  Re-enable a disabled user in pocket-id and unarchive the Suite user.

  Refused with `{:error, {:sign_in_link_live, until}}`, before any pocket-id
  request, while a sign-in link this module minted for the user is still
  valid (`until` is its expiry): pocket-id cannot revoke it, and it would work
  again the moment the user is enabled.

  `opts`:

    * `undo: true`: skip that check, but only when the Suite user was
      archived with reason "sign-in disabled" less than 30 seconds ago. Undo
      means the Disable never happened, so the links it outlived are the ones
      the user held before. Outside that window it gets the same refusal.
      Only the Users page's `undo_disable` event passes it.
  """
  @spec enable(actor(), term(), keyword()) ::
          {:ok, Accounts.User.t()}
          | {:error,
             :not_found
             | :unauthorized
             | :user_not_found
             | :no_identity
             | {:sign_in_link_live, DateTime.t()}
             | term()}
  def enable(actor, user_id, opts \\ []) do
    with :ok <- authorize(actor),
         {:ok, user} <- fetch_user(user_id),
         :ok <- links_expired(user, Keyword.get(opts, :undo, false)),
         {:ok, _identity} <- set_disabled(user, false) do
      Logger.info("sign_in_admin.enable suite_user_id=#{user.id}")
      Accounts.unarchive_user(user)
    end
  end

  @doc """
  Soft remove: delete the pocket-id identity and its passkeys, then archive
  the Suite user (reason "sign-in removed"). The users row and everything
  attributed to it stay. An identity pocket-id no longer has is treated as
  already deleted. Refuses the actor's own id with `{:error, :self}`.
  """
  @spec remove(actor(), term()) :: {:ok, Accounts.User.t()} | {:error, term()}
  def remove(actor, user_id) do
    with :ok <- authorize(actor),
         :ok <- not_self(actor, user_id),
         {:ok, user} <- fetch_user(user_id),
         :ok <- delete_identity(user.oidc_sub) do
      Logger.info("sign_in_admin.remove suite_user_id=#{user.id}")
      Accounts.archive_user(user, actor: actor, reason: "sign-in removed")
    end
  end

  # pocket-id's 404 surfaces as `:no_identity`, never as `:not_found`, which
  # is the gate's answer and must keep meaning "this feature is off".
  defp set_disabled(user, disabled) do
    case PocketId.set_disabled(user.oidc_sub, disabled) do
      {:error, :not_found} -> {:error, :no_identity}
      other -> other
    end
  end

  defp delete_identity(sub) do
    case PocketId.delete_user(sub) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  # A recorded link expiry still in the future refuses Enable, unless this is
  # an Undo inside its window.
  defp links_expired(user, undo?) do
    until = user.sign_in_link_expires_at

    cond do
      undo? and fresh_disable?(user) -> :ok
      is_nil(until) -> :ok
      DateTime.compare(until, DateTime.utc_now()) == :gt -> {:error, {:sign_in_link_live, until}}
      true -> :ok
    end
  end

  defp fresh_disable?(%{archived_reason: @disabled_reason, archived_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) < @undo_window_seconds

  defp fresh_disable?(_user), do: false

  # -- shared ---------------------------------------------------------------

  defp authorize(actor) do
    cond do
      not Config.enabled?() -> {:error, :not_found}
      true -> Access.authorize_install(actor)
    end
  end

  defp not_self(%{id: actor_id}, user_id) when actor_id == user_id, do: {:error, :self}
  defp not_self(_actor, _user_id), do: :ok

  # The static API user is pocket-id's synthetic admin for the API key, not a
  # person: a Suite row that somehow carries its id is never actionable.
  defp fetch_user(user_id) do
    static = PocketId.static_api_user_id()

    case Accounts.get_user(user_id) do
      nil -> {:error, :user_not_found}
      %{oidc_sub: ^static} -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp not_archived(%{archived_at: nil}), do: :ok
  defp not_archived(_user), do: {:error, :archived}

  defp identity_of(user) do
    case PocketId.get_user(user.oidc_sub) do
      {:ok, identity} -> {:ok, identity}
      {:error, :not_found} -> {:error, :no_identity}
      {:error, _} = error -> error
    end
  end

  defp not_disabled(%PocketId.User{disabled: true}), do: {:error, :disabled}
  defp not_disabled(_identity), do: :ok

  # Fail closed: a link whose expiry could not be recorded is never returned,
  # because Enable could then not wait for it.
  defp mint_link(user, pocket_id_user_id) do
    with {:ok, %PocketId.Token{value: token}} <- PocketId.one_time_token(pocket_id_user_id) do
      # Not truncated (task 01a11503): `note_sign_in_link_expiry/2` rounds
      # UP, which only works on the raw sub-second value.
      expires_at = DateTime.add(DateTime.utc_now(), @link_ttl_seconds, :second)

      case Accounts.note_sign_in_link_expiry(user, expires_at) do
        {:ok, user} ->
          link = %Link{
            url: Config.public_base() <> "/lc/" <> token <> @link_redirect,
            code: token,
            expires_at: expires_at
          }

          {:ok, link, user}

        {:error, _} ->
          Logger.warning("sign_in_admin.link_expiry_not_recorded suite_user_id=#{user.id}")
          {:error, :link_failed}
      end
    end
  end

  defp reachable({:ok, _} = ok), do: ok
  defp reachable({:error, _}), do: {:error, :unreachable}

  defp suite_user_by_email(email) do
    [include_archived: true, query: email]
    |> Accounts.list_users()
    |> Enum.find(&(is_binary(&1.email) and String.downcase(&1.email) == email))
  end

  defp normalize_invite(attrs) do
    email = attrs |> fetch(:email) |> normalize_email()
    role = attrs |> fetch(:role) |> normalize_role()

    cond do
      is_nil(email) -> {:error, :invalid_email}
      is_nil(role) -> {:error, :invalid_role}
      true -> {:ok, email, invite_name(fetch(attrs, :name), email), role}
    end
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalize_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" ->
        nil

      normalized ->
        if String.contains?(normalized, "@"), do: normalized, else: nil
    end
  end

  defp normalize_email(_), do: nil

  defp normalize_role(role) when role in [:member, "member"], do: :member
  defp normalize_role(role) when role in [:admin, "admin"], do: :admin
  defp normalize_role(_), do: nil

  # `find_or_create_from_oidc/1` requires a binary name, and the users row
  # requires a non-blank one.
  defp invite_name(name, email) when is_binary(name) do
    case String.trim(name) do
      "" -> email |> String.split("@", parts: 2) |> hd()
      trimmed -> trimmed
    end
  end

  defp invite_name(_name, email), do: invite_name("", email)
end
