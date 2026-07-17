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

  Returns `nil` when no user exists with the given id.

  See `Platform.Tenancy.load_membership/1` for the pure-function reader
  that consumes the preloaded shape.
  """
  @spec get_user(binary() | nil) :: User.t() | nil
  def get_user(id) when is_binary(id) do
    case Repo.get(User, id) do
      nil -> nil
      user -> Repo.preload(user, org_memberships: :org)
    end
  end

  def get_user(_), do: nil

  @doc """
  Whether the given user is a Fabrikam admin (gates the Admin slot in the icon-rail
  and the Admin section in the More sheet).

  Stub: returns `true` for every user today. Multi-tenant org membership lives
  on a downstream stack (see TODO below); until that ships, all current Suite
  users are Fabrikam admins per product decision (Marlowe, 2026-05-18).
  """
  # TODO(MT/RBAC stack 019e3c49-6983-755a-8550-d76ccd680c2c): replace with Platform.Orgs.fabrikam_admin?/1
  # All current users are Fabrikam admins (Marlowe 2026-05-18); stub returns true until MT/RBAC ships.
  def is_fabrikam_user?(_user), do: true

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
  """
  @spec list_users(keyword()) :: [User.t()]
  def list_users(opts \\ []) do
    query = Keyword.get(opts, :query)
    include_archived = Keyword.get(opts, :include_archived, false)

    base = from(u in User, order_by: [asc: u.name])

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
  Find a user by OIDC `sub`, creating one if missing, or refreshing
  email/name/avatar from the OIDC payload.

  ## Self-healing admin rule (Stage 2) + manual-override overlay (Stage 3)

  Wrapped in `Ecto.Multi` so the user write and the Fabrikam-membership
  upsert are atomic:

    * **INSERT**: every new user gets an `org_memberships` row in Fabrikam
      with role derived from `Platform.Tenancy.derive_role_from_email/1`
      (`:admin` for `@example.com`, `:member` otherwise). No lock exists
      yet for a fresh user, so the rule always applies on first INSERT.
    * **UPDATE with email change**: if the email changes AND the new
      email derives `:admin`, promote the user in Fabrikam — UNLESS the
      Fabrikam membership row has `roles_locked_at` set, in which case the
      manual grant wins and the row is left untouched. **No auto-revoke**
      — a Fabrikam email changing to non-Fabrikam leaves the existing role
      untouched. Offboarding is explicitly out of scope (plan Stage 2).
    * **UPDATE without email change**: pure idempotent refresh of
      name/avatar; no membership write.

  Both paths go through `Platform.Tenancy.apply_derived_role/1`, which
  is the lock-aware entry point for the rule.

  See `Platform.Tenancy.derive_role_from_email/1` for the rule and the
  WARNING about Fabrikam alias domains. See `Platform.Tenancy.promote_to_admin/2`
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

  # INSERT path: write the user, then upsert a Fabrikam membership at the
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
  # the new email derives :admin, promote in Fabrikam. Never auto-revoke.
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
  # email derives :admin, set the Fabrikam membership to :admin VIA the
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
end
