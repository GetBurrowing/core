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
  """
  @spec get_users_map([binary()]) :: %{binary() => User.t()}
  def get_users_map(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(u in User, where: u.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  List all users, optionally filtered by a search query (name or email).
  """
  @spec list_users(keyword()) :: [User.t()]
  def list_users(opts \\ []) do
    query = Keyword.get(opts, :query)

    base = from(u in User, order_by: [asc: u.name])

    base =
      if query && String.trim(query) != "" do
        pattern = "%#{String.trim(query)}%"
        where(base, [u], ilike(u.name, ^pattern) or ilike(u.email, ^pattern))
      else
        base
      end

    Repo.all(base)
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
end
