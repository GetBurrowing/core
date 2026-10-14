defmodule Platform.Accounts do
  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy

  @doc """
  Fetch a user by id with `:org_memberships` (and the nested `:org`)
  preloaded so the hot authentication path (RequireAuth plug → LV
  on_mount → admin nav gate) gets the user + their membership without
  follow-up DB calls downstream.

  Total: returns `nil` for ANY input that is not an existing user id, and
  never raises. That explicitly includes malformed ids — `"system"`,
  `"system:auto"`, agent slugs, `""`, non-binaries. Those are the majority
  of actor values at agent boundaries (a plan's `approved_by` is routinely
  the literal string `"system:auto"`), so a caller doing the obvious thing —
  "look the actor up; `nil` means not a human" — hits them on the common
  path, not an edge case.

  Before this guard, `Repo.get(User, "system")` raised `Ecto.Query.CastError`:
  `User`'s `@primary_key` is `Platform.Types.UUIDv7`, whose `cast/1` rejects
  any non-36-character binary. See `Platform.UUID` for why the check is a
  length test and not a bare `Ecto.UUID.cast/1`.

  There is deliberately no `get_user!/1`. All 28 call sites on main already
  `case`/`with`/`&&`-match on `nil`; none wants raise-on-malformed.

  See `Platform.Tenancy.load_membership/1` for the pure-function reader
  that consumes the preloaded shape.
  """
  @spec get_user(term()) :: User.t() | nil
  def get_user(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      case Repo.get(User, id) do
        nil -> nil
        user -> Repo.preload(user, org_memberships: :org)
      end
    else
      nil
    end
  end

  def get_user(_), do: nil

  @doc """
  Whether the given user is a root-org user (gates the Admin slot in the icon-rail
  and the Admin section in the More sheet).

  Stub: returns `true` for every user today. Multi-tenant org membership lives
  on a downstream stack (see TODO below); until that ships, all current Suite
  users are root-org admins per product decision (Marlowe, 2026-05-18).
  """
  # TODO(MT/RBAC stack 019e3c49-6983-755a-8550-d76ccd680c2c): replace with Platform.Tenancy.root_admin?/1
  # All current users are root-org admins (Marlowe 2026-05-18); stub returns true until MT/RBAC ships.
  def root_user?(_user), do: true

  @doc """
  Return a map of user id => user for the given ids.

  Defaults to `include_archived: false` — archived users (`archived_at`
  IS NOT NULL, task 019f671f Stage 1) are silently dropped from the map.
  Historical-attribution call sites (memory-entry author resolution,
  past-message participant labels) opt in with `include_archived: true`;
  those overrides are enumerated in Stage 2 of the archival plan.
  """
  @spec get_users_map([binary()], keyword()) :: %{binary() => User.t()}
  def get_users_map(ids, opts \\ []) when is_list(ids) do
    include_archived = Keyword.get(opts, :include_archived, false)
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      base = from(u in User, where: u.id in ^ids)

      base =
        if include_archived do
          base
        else
          where(base, [u], is_nil(u.archived_at))
        end

      base
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  List all users, optionally filtered by a search query (name or email).

  Defaults to `include_archived: false` — archived users are excluded so
  active-user pickers (task assignee, DM/group new-conversation, add-participant
  sheet) drop them with no explicit filter. The admin surface
  (`UserAccessLive`, task 019f671f Stage 6) opts in with
  `include_archived: true`.

  `:ids` narrows the list to those user ids (task 01a111bb). It is how
  `Platform.Chat.dm_candidates/3` asks the SAME query about a known set of
  people (recent collaborators, call invitees) instead of a search. The ids
  must already be valid UUIDs; callers guard them.
  """
  @spec list_users(keyword()) :: [User.t()]
  def list_users(opts \\ []) do
    query = Keyword.get(opts, :query)
    include_archived = Keyword.get(opts, :include_archived, false)

    base = from(u in User, order_by: [asc: u.name])

    base =
      case Keyword.get(opts, :ids) do
        ids when is_list(ids) -> where(base, [u], u.id in ^ids)
        _ -> base
      end

    base =
      if include_archived do
        base
      else
        where(base, [u], is_nil(u.archived_at))
      end

    base =
      if query && String.trim(query) != "" do
        pattern = "%#{String.trim(query)}%"
        where(base, [u], ilike(u.name, ^pattern) or ilike(u.email, ^pattern))
      else
        base
      end

    Repo.all(base)
  end

  # ── Soft-archive (task 019f671f Stage 1) ───────────────────────────────
  #
  # Users are never hard-deleted. Archive flips `archived_at` (+ optional
  # actor + reason), which flows through every read path that defaults to
  # `include_archived: false`. Historical attribution (past-authored
  # messages, task `reported_by`, memory-entry authorship) still resolves
  # because the row stays resident and callers can opt in.
  #
  # Auth boundaries close in Stage 5; participant + mention filtering
  # closes in Stage 3. This stage only wires the columns and the API.
  #
  # `get_user/1` is deliberately UNCHANGED — the auth plugs need to look
  # up an archived user to detect and bounce them (Stage 5).

  @doc """
  Soft-archive a user. Idempotent-ish: repeated calls re-stamp
  `archived_at` and (if provided) `archived_by_user_id` / `archived_reason`.

  ## Options

    * `:actor`  — `%User{}` performing the archive; stamped as
      `archived_by_user_id`. Nil (or absent) leaves the FK nil.
    * `:reason` — free-text note surfaced in the admin UI. Optional.

  Returns `{:ok, %User{}}` or `{:error, changeset}`.
  """
  @spec archive_user(User.t(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def archive_user(%User{} = user, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    reason = Keyword.get(opts, :reason)

    attrs = %{
      archived_at: DateTime.utc_now(),
      archived_by_user_id: actor && actor.id,
      archived_reason: reason
    }

    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Reverse an archive by clearing all three archive columns. Mirrors
  `Platform.Chat.unarchive_space/2`.
  """
  @spec unarchive_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_user(%User{} = user) do
    user
    |> User.changeset(%{
      archived_at: nil,
      archived_by_user_id: nil,
      archived_reason: nil
    })
    |> Repo.update()
  end

  @doc """
  Give an ARCHIVED user a new OIDC identity and unarchive them, in one row
  write: `oidc_sub` becomes `new_sub` and all three archive columns are
  cleared.

  Why it exists: re-inviting a person who was removed from the sign-in
  service (task 01a113ea, `Platform.SignInAdmin`) creates a NEW identity at
  the identity provider, with a new `sub`. Sign-in links a login to a user by
  `oidc_sub` only (`find_or_create_from_oidc/1`), so without this the
  returning person would land on a fresh row and lose the attribution of
  everything they authored. Relinking keeps their Suite user id, so their
  messages, tasks and files stay theirs.

  Refuses a user that is not archived with `{:error, :not_archived}` and
  writes nothing: moving a live identity is not what this is for. A `new_sub`
  already held by another user returns `{:error, changeset}` (the unique
  `oidc_sub` constraint) and leaves the row unchanged.
  """
  @spec relink_oidc_identity(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_archived} | {:error, Ecto.Changeset.t()}
  def relink_oidc_identity(%User{archived_at: %DateTime{}} = user, new_sub)
      when is_binary(new_sub) do
    user
    |> User.changeset(%{
      oidc_sub: new_sub,
      archived_at: nil,
      archived_by_user_id: nil,
      archived_reason: nil
    })
    |> Repo.update()
  end

  def relink_oidc_identity(%User{}, new_sub) when is_binary(new_sub),
    do: {:error, :not_archived}

  @doc """
  Record that a sign-in link valid until `expires_at` was minted for `user`
  (task 01a114c1, `Platform.SignInAdmin`). Stores the LATER of the user's
  current `sign_in_link_expires_at` and `expires_at`, so a second, shorter
  link never shortens the window of a longer one still live.

  The stored value is `expires_at` rounded UP to the next whole second, plus
  a 5-second margin (task 01a11503): pocket-id keeps the token alive to a
  later instant than Suite's own sample, so a truncated or exact copy could
  let Enable through while the token still works.

  `Platform.SignInAdmin.enable/2` refuses while that value is in the future:
  pocket-id has no route to revoke a one-time token, and it restores a token
  a disabled user tried to redeem, so a link minted before a Disable would
  work again the moment the user is enabled. Only the expiry is stored, never
  the link or its code.

  The comparison runs in the database (`GREATEST`, which skips a NULL), so
  a stale `user` struct cannot move the value backwards. Returns
  `{:error, :not_found}` when the row no longer exists.
  """
  # Task 01a11503 (evidence canvas 01a11502-9e61-7001-8992-1be3e31eb59d):
  # a refused redeem restores pocket-id's token to a whole second that can sit
  # after Suite's truncated copy, so Enable went through while the pre-Disable
  # link still worked. Rounding up closes the sub-second gap; the margin also
  # absorbs clock skew between the Suite and pocket-id hosts.
  @sign_in_link_expiry_margin_seconds 5

  @spec note_sign_in_link_expiry(User.t(), DateTime.t()) ::
          {:ok, User.t()} | {:error, :not_found}
  def note_sign_in_link_expiry(
        %User{id: id},
        %DateTime{utc_offset: 0, std_offset: 0} = expires_at
      ) do
    # `users.sign_in_link_expires_at` is a UTC `timestamp` column: compare as
    # naive UTC so no session time zone is involved.
    expires_at =
      expires_at
      |> ceil_to_second()
      |> DateTime.add(@sign_in_link_expiry_margin_seconds, :second)
      |> DateTime.to_naive()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()

    query =
      from(u in User,
        where: u.id == ^id,
        select: u,
        update: [
          set: [
            sign_in_link_expires_at:
              fragment("GREATEST(?, ?::timestamp)", u.sign_in_link_expires_at, ^expires_at),
            updated_at: ^now
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [user]} -> {:ok, user}
      {0, _} -> {:error, :not_found}
    end
  end

  # Whole-second ceiling: a value already on the second is left alone.
  defp ceil_to_second(%DateTime{microsecond: {0, _}} = at), do: DateTime.truncate(at, :second)

  defp ceil_to_second(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.add(1, :second)

  @doc """
  Find a user by OIDC `sub`, creating one if missing, or refreshing
  email/name/avatar from the OIDC payload.

  ## Self-healing admin rule (Stage 2) + manual-override overlay (Stage 3)

  Wrapped in `Ecto.Multi` so the user write and the root-org membership
  upsert are atomic:

    * **INSERT**: every new user gets an `org_memberships` row in the
      root org with role derived from
      `Platform.Tenancy.derive_role_from_email/1` (`:admin` for the
      configured `:root_org_admin_email_domain`, `:member` otherwise, and
      `:member` for everyone when no domain is set — except the very
      first membership on an empty root org, which is force-admined; see
      `apply_derived_role/1`'s bootstrap-admin fallback). No lock exists
      yet for a fresh user, so the rule always applies on first INSERT.
    * **UPDATE with email change**: if the email changes AND the new
      email derives `:admin`, promote the user in the root org — UNLESS
      the root-org membership row has `roles_locked_at` set, in which case the
      manual grant wins and the row is left untouched. **No auto-revoke**
      — an admin-domain email changing to another domain leaves the existing role
      untouched. Offboarding is explicitly out of scope (plan Stage 2).
    * **UPDATE without email change**: pure idempotent refresh of
      name/avatar; no membership write.

  Both paths go through `Platform.Tenancy.apply_derived_role/1`, which
  is the lock-aware entry point for the rule.

  See `Platform.Tenancy.derive_role_from_email/1` for the rule and the
  WARNING about alias domains. See `Platform.Tenancy.promote_to_admin/2`
  / `revoke_admin/2` for the manual-override ops API.
  """
  def find_or_create_from_oidc(%{sub: sub, email: email, name: name} = oidc_user)
      when is_binary(sub) and is_binary(email) and is_binary(name) do
    attrs = build_oidc_user_attrs(oidc_user)

    case Repo.get_by(User, oidc_sub: sub) do
      %User{archived_at: %DateTime{}} ->
        # Stage 5: archived users are refused at the OIDC seam. No attrs
        # refresh, no membership sync — the auth boundary decides here
        # so downstream telemetry (`[:platform, :auth, :access_blocked]`)
        # fires from the controller without a stale-but-refreshed row.
        {:error, :user_archived}

      %User{} = existing ->
        update_user_with_membership_sync(existing, attrs)

      nil ->
        insert_user_with_membership(attrs)
    end
  end

  def find_or_create_from_oidc(_attrs), do: {:error, :invalid_oidc_user}

  # INSERT path: write the user, then upsert a root-org membership at the
  # derived role. Both writes share one transaction.
  defp insert_user_with_membership(attrs) do
    changeset = User.changeset(%User{}, attrs)

    Multi.new()
    |> Multi.insert(:user, changeset)
    |> Multi.run(:membership, fn _repo, %{user: user} ->
      # Fresh user → no row exists yet → no lock to honor. Going through
      # `apply_derived_role/1` (rather than `set_membership_role/3`
      # directly) keeps INSERT and UPDATE paths consistent: both ask the
      # tenancy module for the lock-aware decision.
      Tenancy.apply_derived_role(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :membership, reason, _changes} -> {:error, reason}
    end
  end

  # UPDATE path: refresh user fields. If the email actually changed AND
  # the new email derives :admin, promote in the root org. Never auto-revoke.
  defp update_user_with_membership_sync(%User{} = user, attrs) do
    refreshed = refresh_oidc_user_attrs(user, attrs)
    changeset = User.changeset(user, refreshed)

    Multi.new()
    |> Multi.update(:user, changeset)
    |> Multi.run(:membership, fn _repo, %{user: updated} ->
      maybe_promote_on_email_change(user, updated)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: updated}} -> {:ok, updated}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :membership, reason, _changes} -> {:error, reason}
    end
  end

  # Promote only — no auto-revoke. If the email changed and the new
  # email derives :admin, set the root-org membership to :admin VIA the
  # lock-aware `apply_derived_role/1` — which is a no-op if the row is
  # manually locked (Stage 3). Otherwise leave the existing membership
  # row (if any) untouched. Returning `{:ok, :noop}` is harmless inside
  # `Multi.run/3`.
  defp maybe_promote_on_email_change(%User{email: old_email}, %User{email: new_email})
       when old_email == new_email,
       do: {:ok, :noop}

  defp maybe_promote_on_email_change(%User{}, %User{email: new_email} = updated) do
    case Tenancy.derive_role_from_email(new_email) do
      :admin -> Tenancy.apply_derived_role(updated)
      :member -> {:ok, :noop}
    end
  end

  defp build_oidc_user_attrs(attrs) do
    avatar_url =
      attrs
      |> get_attr(:avatar_url)
      |> case do
        nil -> get_attr(attrs, :picture)
        value -> value
      end
      |> normalize_optional_string()

    %{
      oidc_sub: get_attr(attrs, :sub),
      email: get_attr(attrs, :email),
      name: get_attr(attrs, :name),
      avatar_url: avatar_url,
      avatar_source: if(avatar_url, do: :oidc, else: :generated)
    }
  end

  defp refresh_oidc_user_attrs(%User{avatar_source: :local, avatar_url: avatar_url}, attrs) do
    attrs
    |> Map.put(:avatar_url, avatar_url)
    |> Map.put(:avatar_source, :local)
  end

  defp refresh_oidc_user_attrs(%User{} = user, %{avatar_url: nil} = attrs) do
    attrs
    |> Map.put(:avatar_url, user.avatar_url)
    |> Map.put(:avatar_source, user.avatar_source || :generated)
  end

  defp refresh_oidc_user_attrs(%User{}, attrs), do: attrs

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  # ── User preferences (chat plan v2 Stage 3) ────────────────────────────
  #
  # `users.preferences` is a single JSONB column holding lightweight UI prefs
  # keyed by string. Today's only consumer is the chat rail's
  # `chat_section_order` (drag-reorder of sub-org sections); future stages
  # can share the same column without another migration.
  #
  # `update_user_preference/3` is upsert-semantics: it merges the new key
  # into the existing map and persists. Returns `{:ok, user}` on success;
  # `{:error, :not_found}` when the user_id isn't a real row (anonymous
  # sessions in chat use a generated UUID — Stage 3 callers no-op those).

  @doc """
  Get a user's full preferences map. Returns `%{}` for unknown users so
  callers don't have to nil-guard.
  """
  @spec get_user_preferences(binary()) :: map()
  def get_user_preferences(user_id) when is_binary(user_id) do
    case get_user(user_id) do
      %User{preferences: prefs} when is_map(prefs) -> prefs
      %User{} -> %{}
      nil -> %{}
    end
  end

  def get_user_preferences(_), do: %{}

  @doc """
  Upsert a single preference key on the user. Merges into the existing
  preferences map and persists atomically.

  Accepts the key as atom or string; both round-trip through JSONB as
  string. Callers should pick one convention and stick to it (Stage 3
  uses `:chat_section_order`).

  Returns `{:ok, %User{}}` on success or `{:error, :not_found}` when no
  user with that id exists (anonymous chat sessions use a generated UUID
  that doesn't match any row — Stage 3's `handle_event` no-ops on that).
  """
  @spec update_user_preference(binary(), atom() | String.t(), any()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_user_preference(user_id, key, value) when is_binary(user_id) do
    string_key = to_string(key)

    case get_user(user_id) do
      %User{} = user ->
        next_prefs = Map.put(user.preferences || %{}, string_key, value)

        user
        |> User.changeset(%{preferences: next_prefs})
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  # ── Hidden channels (chat sidebar v3 Stage 1) ──────────────────────────
  #
  # Stored as `preferences["hidden_channel_ids"] = ["<uuid>", ...]`. The
  # render path reads via `get_hidden_channel_ids/1` which wraps the list
  # in a `MapSet` for O(1) row-level lookups in `chat_live`'s section
  # render. Stale ids (channel deleted while still hidden by some user)
  # are tolerated at read time — see `Platform.Chat.HiddenChannels.filter/2`.

  @hidden_channels_key "hidden_channel_ids"

  @doc """
  Returns the user's hidden-channel ids as a `MapSet`. Empty MapSet for
  unknown users or users with no hidden channels.

  MapSet (not List) is intentional so the per-row filter in the sidebar
  render path is O(1) instead of O(n) per section.
  """
  @spec get_hidden_channel_ids(binary() | nil) :: MapSet.t(String.t())
  def get_hidden_channel_ids(user_id) when is_binary(user_id) do
    user_id
    |> get_user_preferences()
    |> Map.get(@hidden_channels_key, [])
    |> List.wrap()
    |> MapSet.new()
  end

  def get_hidden_channel_ids(_), do: MapSet.new()

  @doc """
  Add a channel id to the user's hidden-channel set. Idempotent on
  double-hide (set semantics dedupe).

  Returns `{:ok, %User{}}`, or `{:error, :not_found}` when the user_id
  doesn't match a real row — anonymous chat sessions use a generated UUID,
  callers should treat the not-found case as a silent no-op.
  """
  @spec hide_channel(binary(), binary()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def hide_channel(user_id, space_id) when is_binary(user_id) and is_binary(space_id) do
    next =
      user_id
      |> get_hidden_channel_ids()
      |> MapSet.put(space_id)
      |> MapSet.to_list()

    update_user_preference(user_id, @hidden_channels_key, next)
  end

  def hide_channel(_, _), do: {:error, :not_found}

  @doc """
  Remove a channel id from the user's hidden-channel set. Idempotent on
  unhide of a never-hidden id (set semantics dedupe).

  Same return shape as `hide_channel/2`.
  """
  @spec unhide_channel(binary(), binary()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def unhide_channel(user_id, space_id) when is_binary(user_id) and is_binary(space_id) do
    next =
      user_id
      |> get_hidden_channel_ids()
      |> MapSet.delete(space_id)
      |> MapSet.to_list()

    update_user_preference(user_id, @hidden_channels_key, next)
  end

  def unhide_channel(_, _), do: {:error, :not_found}

  # ── Closed DMs (DM Close action) ───────────────────────────────────────
  #
  # Stored as `preferences["closed_dm_at"] = %{"<space_uuid>" => "<ISO8601>"}`
  # in the same JSONB column as `hidden_channel_ids` and `chat_section_order`.
  #
  # A DM row leaves the rail when its newest activity is not newer than the
  # stored timestamp, and returns on its own the moment a new message lands.
  # That is what removes the need for an undo surface or a hidden-DM list. The
  # comparison lives in `Platform.Chat.ClosedDms.filter/2`.
  #
  # Reads FAIL OPEN. A value that will not parse back into a `DateTime` is
  # dropped, which leaves that conversation visible. Both writers rebuild the
  # stored map from the parsed one, so anything unparsable is also cleaned up
  # on the next write rather than lingering.
  #
  # This is deliberately NOT the hidden-channel store. Hide and Close are two
  # actions with two honest meanings: a channel is a place you may want gone
  # even while it is busy, and a DM is a person.

  @closed_dms_key "closed_dm_at"

  @doc """
  Returns the user's closed DMs as `%{space_id => DateTime}`. Empty map for
  unknown users, users who have closed nothing, and stored values of an
  unexpected shape.

  Entries whose stored timestamp will not parse are dropped, so a corrupted
  value can only ever make a DM visible.
  """
  @spec get_closed_dm_at(binary() | nil) :: %{optional(String.t()) => DateTime.t()}
  def get_closed_dm_at(user_id) when is_binary(user_id) do
    user_id
    |> get_user_preferences()
    |> Map.get(@closed_dms_key)
    |> parse_closed_dm_at()
  end

  def get_closed_dm_at(_), do: %{}

  @doc """
  Record `space_id` as closed for this user, stamped `DateTime.utc_now()`.
  Closing an already-closed DM re-stamps it.

  Returns `{:ok, %User{}}`, or `{:error, :not_found}` when the user_id doesn't
  match a real row. Anonymous chat sessions use a generated UUID, so callers
  should treat the not-found case as a silent no-op.
  """
  @spec close_dm(binary(), binary()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def close_dm(user_id, space_id) when is_binary(user_id) and is_binary(space_id) do
    next =
      user_id
      |> get_closed_dm_at()
      |> Map.put(space_id, DateTime.utc_now())
      |> dump_closed_dm_at()

    update_user_preference(user_id, @closed_dms_key, next)
  end

  def close_dm(_, _), do: {:error, :not_found}

  @doc """
  Drop `space_id` from the user's closed DMs, so the row is visible again
  regardless of activity. Idempotent on a never-closed id.

  Same return shape as `close_dm/2`.
  """
  @spec reopen_dm(binary(), binary()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reopen_dm(user_id, space_id) when is_binary(user_id) and is_binary(space_id) do
    next =
      user_id
      |> get_closed_dm_at()
      |> Map.delete(space_id)
      |> dump_closed_dm_at()

    update_user_preference(user_id, @closed_dms_key, next)
  end

  def reopen_dm(_, _), do: {:error, :not_found}

  defp parse_closed_dm_at(stored) when is_map(stored) do
    Enum.reduce(stored, %{}, fn {space_id, value}, acc ->
      case parse_closed_at(value) do
        {:ok, at} -> Map.put(acc, space_id, at)
        :error -> acc
      end
    end)
  end

  defp parse_closed_dm_at(_), do: %{}

  defp parse_closed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _utc_offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp parse_closed_at(_), do: :error

  defp dump_closed_dm_at(parsed) do
    Map.new(parsed, fn {space_id, %DateTime{} = at} -> {space_id, DateTime.to_iso8601(at)} end)
  end

  # ── Notification-banner dismissal (task 019ffb7b stage 5) ──────────────
  #
  # Stored as `preferences["notification_banner_dismissed"] = true`. Same
  # column, same read/write helpers as `hidden_channel_ids` above — no new
  # table and no migration: `users.preferences` has been a JSONB column
  # since `20260519134626_add_preferences_to_users`.
  #
  # PERSISTENT, not session-scoped. See the rationale on
  # `PlatformWeb.ChatLive.Partials.notification_banner/1`: one of the two
  # reasons a user dismisses ("I don't want notifications") is permanent, and
  # a per-session flag would re-nag exactly that user on every visit.
  #
  # There is no un-dismiss writer, and that is deliberate rather than
  # unfinished. The banner is a contextual offer; the durable control lives on
  # `/inbox` (`PlatformWeb.Components.NotificationState`), which always renders
  # and never consults this key. A user who changes their mind goes there.

  @notification_banner_dismissed_key "notification_banner_dismissed"

  @doc """
  Whether the user has dismissed the chat notification opt-in banner.

  `false` for unknown users — anonymous chat sessions use a generated UUID
  that matches no row, so they see the offer and their dismissal is a no-op
  for the length of that LiveView.
  """
  @spec notification_banner_dismissed?(binary() | nil) :: boolean()
  def notification_banner_dismissed?(user_id) when is_binary(user_id) do
    user_id
    |> get_user_preferences()
    |> Map.get(@notification_banner_dismissed_key, false) == true
  end

  def notification_banner_dismissed?(_), do: false

  @doc """
  Record that the user dismissed the chat notification opt-in banner.
  Idempotent.

  Returns `{:ok, %User{}}`, or `{:error, :not_found}` when the user_id doesn't
  match a real row — same anonymous-session contract as `hide_channel/2`, and
  callers should treat not-found as a silent no-op.
  """
  @spec dismiss_notification_banner(binary()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def dismiss_notification_banner(user_id) when is_binary(user_id) do
    update_user_preference(user_id, @notification_banner_dismissed_key, true)
  end

  def dismiss_notification_banner(_), do: {:error, :not_found}
end
