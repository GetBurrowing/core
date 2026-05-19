defmodule Platform.Accounts do
  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Repo

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

  def find_or_create_from_oidc(%{sub: sub, email: email, name: name} = oidc_user)
      when is_binary(sub) and is_binary(email) and is_binary(name) do
    attrs = build_oidc_user_attrs(oidc_user)

    case Repo.get_by(User, oidc_sub: sub) do
      %User{} = user ->
        user
        |> User.changeset(refresh_oidc_user_attrs(user, attrs))
        |> Repo.update()

      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert()
    end
  end

  def find_or_create_from_oidc(_attrs), do: {:error, :invalid_oidc_user}

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
