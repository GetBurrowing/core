defmodule Platform.Access.Live do
  @moduledoc """
  Per-user invalidation for the grant snapshot held by connected LiveViews.

  The message carries only a change id. Each socket reloads its own user and
  builds a fresh scope after the grant transaction commits.
  """

  import Ecto.Query

  alias Platform.Access.Change
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @spec topic(binary()) :: binary()
  def topic(user_id) when is_binary(user_id), do: "access:user:" <> user_id

  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, topic(user_id))

  @doc "Notify affected users once per committed change, never per grant row."
  @spec broadcast_changed(Change.t()) :: :ok
  def broadcast_changed(%Change{} = change) do
    rows = change.before ++ change.after

    (user_ids(rows) ++ role_user_ids(rows))
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        topic(user_id),
        {:access_changed, change.id}
      )
    end)

    :ok
  end

  defp user_ids(rows) do
    for %{"principal_type" => "user", "principal_id" => id} <- rows,
        is_binary(id),
        do: id
  end

  defp role_user_ids(rows) do
    keys =
      for %{
            "principal_type" => "role",
            "principal_role_key" => key,
            "org_id" => org_id
          } <- rows,
          is_binary(key) and is_binary(org_id),
          uniq: true,
          do: {org_id, key}

    case keys do
      [] ->
        []

      _ ->
        condition =
          Enum.reduce(keys, dynamic(false), fn {org_id, key}, acc ->
            dynamic([m], ^acc or (m.org_id == ^org_id and m.access_role_key == ^key))
          end)

        Repo.all(from(m in OrgMembership, where: ^condition, select: m.user_id))
    end
  end
end
