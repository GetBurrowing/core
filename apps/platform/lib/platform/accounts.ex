defmodule Platform.Accounts do
  alias Platform.Accounts.User
  alias Platform.Repo

  def get_user(id), do: Repo.get(User, id)

  def find_or_create_from_oidc(%{sub: sub, email: email, name: name})
      when is_binary(sub) and is_binary(email) and is_binary(name) do
    attrs = %{oidc_sub: sub, email: email, name: name}

    case Repo.get_by(User, oidc_sub: sub) do
      %User{} = user ->
        user
        |> User.changeset(attrs)
        |> Repo.update()

      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert(
          on_conflict: [set: [email: email, name: name, updated_at: DateTime.utc_now(:second)]],
          conflict_target: [:oidc_sub],
          returning: true
        )
    end
  end

  def find_or_create_from_oidc(_attrs), do: {:error, :invalid_oidc_user}
end
