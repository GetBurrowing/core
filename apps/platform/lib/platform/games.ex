defmodule Platform.Games do
  @moduledoc """
  Explicitly published game manifests. Nothing in chat becomes public implicitly.

  Operators configure `:game_publications` with string-keyed manifests. Each
  release is pinned to an attachment and digest; changing `current_version`
  does not change older release URLs. No game-specific secret belongs here.
  """
  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Chat.Attachment
  alias Platform.Repo

  def list_published do
    stored = Repo.all(Platform.Games.Publication)
    slugs = MapSet.new(stored, & &1.slug)
    configured = List.wrap(Application.get_env(:platform, :game_publications, []))

    (Enum.map(stored, & &1.manifest) ++
       Enum.reject(configured, &MapSet.member?(slugs, &1["slug"])))
    |> Enum.filter(&(valid?(&1) and &1["published"] == true))
    |> Enum.sort_by(&{position(&1), &1["title"]})
  end

  # Optional manifest "position" (lower first); unpositioned games follow, by title.
  defp position(%{"position" => position}) when is_integer(position), do: position
  defp position(_game), do: :infinity

  def get(slug) when is_binary(slug) do
    stored = Repo.get(Platform.Games.Publication, slug)

    game =
      if stored,
        do: stored.manifest,
        else:
          Enum.find(
            List.wrap(Application.get_env(:platform, :game_publications, [])),
            &(&1["slug"] == slug)
          )

    if valid?(game) and game["published"] == true, do: game
  end

  def get(_), do: nil

  def valid?(game) when is_map(game) do
    releases = game["releases"]

    is_binary(game["slug"]) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,63}$/, game["slug"]) and
      match?({:ok, _}, Platform.UUID.cast(game["org_id"])) and
      is_binary(game["title"]) and is_binary(game["summary"]) and
      is_list(releases) and releases != [] and Enum.all?(releases, &valid_release?/1) and
      length(Enum.uniq_by(releases, & &1["version"])) == length(releases) and
      Enum.any?(releases, &(&1["version"] == game["current_version"])) and
      (is_nil(game["community_space_id"]) or
         match?({:ok, _}, Platform.UUID.cast(game["community_space_id"]))) and
      (is_nil(game["project_id"]) or Platform.UUID.valid?(game["project_id"])) and
      (is_nil(game["placeholder"]) or is_boolean(game["placeholder"])) and
      (is_nil(game["image_path"]) or
         (is_binary(game["image_path"]) and String.starts_with?(game["image_path"], "/images/") and
            not String.contains?(game["image_path"], ["..", "?", "#", "\\"])))
  end

  def valid?(_), do: false

  defp valid_release?(release) when is_map(release) do
    is_binary(release["version"]) and
      Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/, release["version"]) and
      match?({:ok, _}, Platform.UUID.cast(release["attachment_id"])) and
      is_binary(release["sha256"]) and Regex.match?(~r/^[a-f0-9]{64}$/, release["sha256"]) and
      is_integer(release["byte_size"]) and release["byte_size"] > 0
  end

  defp valid_release?(_), do: false

  def signup_url(game) do
    with url when is_binary(url) <- game["signup_url"],
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) <- URI.parse(url),
         true <- host == URI.parse(Platform.OIDC.issuer()).host do
      url
    else
      _ -> nil
    end
  end

  def release(game, version) when is_map(game) and is_binary(version) do
    Enum.find(game["releases"] || [], &(&1["version"] == version))
  end

  def release(_, _), do: nil

  def current_release(game), do: release(game, game["current_version"])

  def user(id) when is_binary(id) do
    case Platform.UUID.cast(id) do
      {:ok, id} ->
        case Accounts.get_user(id) do
          %{archived_at: nil} = user -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def user(_), do: nil

  # Publication authorizes exactly this artifact. It does not widen the
  # original chat attachment route or grant access to the attachment's space.
  def artifact(game, version) do
    with %{} = release <- release(game, version),
         {:ok, id} <- Platform.UUID.cast(release["attachment_id"]),
         %Attachment{state: "ready"} = attachment <- Repo.get(Attachment, id),
         true <- attachment.content_hash == release["sha256"],
         true <- attachment.byte_size == release["byte_size"],
         true <- attachment.content_type in ["application/zip", "application/octet-stream"] do
      {:ok, attachment}
    else
      _ -> {:error, :unavailable}
    end
  end

  def admit_oidc(game, claims) do
    Repo.transaction(fn ->
      with {:ok, user} <- Accounts.find_or_create_game_player(claims),
           :ok <- admit_player(game, user) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A game login may create only an external membership, never a full org
  # membership. Preserve existing internal identities unchanged.
  def admit_player(game, %{id: user_id}) do
    internal? =
      Repo.exists?(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^user_id and m.external == false
        )
      )

    if internal? do
      :ok
    else
      case Platform.Tenancy.mark_membership_external(%{
             user_id: user_id,
             org_id: game["org_id"],
             role: "member"
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Public game label. Account name, email and avatar are never fallbacks."
  def player_display_name(%{id: id} = user) do
    case (Map.get(user, :preferences) || %{})["player_display_name"] do
      label when is_binary(label) ->
        label = String.trim(label)
        if label != "" and String.length(label) <= 40, do: label, else: generated_handle(id)

      _ ->
        generated_handle(id)
    end
  end

  def generated_handle(id) when is_binary(id) do
    key = PlatformWeb.Endpoint.config(:secret_key_base)

    suffix =
      :crypto.mac(:hmac, :sha256, key, "public-game-player:" <> id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "pilot-" <> suffix
  end

  def community(game, user) do
    with id when is_binary(id) <- game["community_space_id"],
         true <- Platform.UUID.valid?(id),
         %Platform.Chat.Space{kind: "channel", archived_at: nil} = space <-
           Platform.Chat.get_space(id),
         true <- space.org_id == game["org_id"],
         true <- space.metadata["public_game_slug"] == game["slug"] do
      member_count =
        Repo.aggregate(
          from(p in Platform.Chat.Participant,
            join: u in Platform.Accounts.User,
            on: p.participant_id == u.id,
            where: p.space_id == ^id and p.participant_type == "user" and is_nil(u.archived_at)
          ),
          :count
        )

      joined? =
        not is_nil(user) and
          Repo.exists?(
            from(p in Platform.Chat.Participant,
              where:
                p.space_id == ^id and p.participant_type == "user" and
                  p.participant_id == ^user.id
            )
          ) and
          Platform.Access.check(Platform.Access.Scope.for_user(user), "chat.read", {:space, id}) ==
            :ok

      %{space: space, member_count: member_count, joined?: joined?}
    else
      _ -> nil
    end
  end

  def join_community(game, user) do
    with id when is_binary(id) <- game["community_space_id"],
         true <- Platform.UUID.valid?(id),
         %Platform.Chat.Space{kind: "channel", archived_at: nil} = space <-
           Platform.Chat.get_space(id),
         true <- space.org_id == game["org_id"],
         true <- space.metadata["public_game_slug"] == game["slug"] do
      Repo.transaction(fn ->
        with :ok <- admit_player(game, user),
             :ok <-
               Platform.Tenancy.ExternalGrants.add_space_participants(user, [
                 %{"space_id" => id, "role" => "member"}
               ]) do
          # Keep new author snapshots public in this player-only channel.
          from(p in Platform.Chat.Participant,
            where:
              p.space_id == ^id and p.participant_type == "user" and p.participant_id == ^user.id
          )
          |> Repo.update_all(set: [display_name: player_display_name(user), avatar_url: nil])

          id
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :unavailable}
    end
  end
end
