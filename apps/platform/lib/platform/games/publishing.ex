defmodule Platform.Games.Publishing do
  @moduledoc "Root-admin publication without a host restart. Release versions are immutable."
  import Ecto.Query
  alias Platform.{Chat, Games, Repo, Tenancy}
  alias Platform.Games.Publication

  def list(actor) do
    if authorized?(actor),
      do: Repo.all(from(p in Publication, order_by: p.slug)),
      else: []
  end

  def publish_release(actor, attrs) do
    with true <- authorized?(actor),
         true <- Platform.UUID.valid?(attrs["attachment_id"]),
         %Platform.Chat.Attachment{state: "ready"} = attachment <-
           Repo.get(Platform.Chat.Attachment, attrs["attachment_id"]),
         %Tenancy.Org{archived_at: nil} <- Tenancy.get_org(attrs["org_id"]),
         # The file the player starts from this release's root, pinned with it.
         launch_path = blank_to_nil(attrs["launch_path"]),
         true <- is_nil(launch_path) or Games.launch_path?(launch_path) do
      stored = Repo.get(Publication, attrs["slug"])
      previous = if stored, do: stored.manifest, else: configured(attrs["slug"])

      release =
        %{
          "version" => attrs["version"],
          "attachment_id" => attachment.id,
          "sha256" => attachment.content_hash,
          "byte_size" => attachment.byte_size
        }
        |> put_launch_path(launch_path)

      releases = if previous, do: previous["releases"], else: []

      case with_release(releases, release) do
        nil ->
          {:error, :immutable_release}

        releases ->
          manifest =
            Map.merge(previous || %{}, %{
              "slug" => attrs["slug"],
              "org_id" => attrs["org_id"],
              "title" => attrs["title"],
              "summary" => attrs["summary"] || "",
              "published" => attrs["published"] == "true",
              "current_version" => attrs["version"],
              "releases" => releases,
              "image_path" =>
                (previous && previous["image_path"]) ||
                  if(attrs["slug"] == "voltron", do: "/images/voltron-game.png", else: nil),
              "multiplayer_note" =>
                attrs["multiplayer_note"] || (previous && previous["multiplayer_note"]) ||
                  "Single player is ready. Multiplayer needs a matching server release and your crew’s room code."
            })

          save(actor, manifest)
      end
    else
      _ -> {:error, :invalid_publication}
    end
  end

  def save(actor, manifest) do
    if authorized?(actor) and is_map(manifest) and Games.valid?(manifest) do
      Repo.transaction(fn ->
        # Serialise even first publication of a slug, including community creation.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [to_string(manifest["slug"])])
        old = Repo.get(Publication, manifest["slug"])
        previous = if old, do: old.manifest, else: configured(manifest["slug"])

        with true <- Games.valid?(manifest),
             true <- is_nil(previous) or previous["org_id"] == manifest["org_id"],
             true <- immutable?(previous, manifest),
             true <-
               Enum.all?(
                 manifest["releases"],
                 &match?({:ok, _}, Games.artifact(manifest, &1["version"]))
               ),
             {:ok, manifest} <- community(actor, previous, manifest) do
          (old || %Publication{slug: manifest["slug"]})
          |> Ecto.Changeset.change(manifest: manifest)
          |> Repo.insert_or_update!()
        else
          _ -> Repo.rollback(:invalid_publication)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Pins `launch_path` on an already published release that names none, for
  manifests written before launchers were pinned per release. The release's
  bytes, the current version and everything else stay as they are; a release
  that already names a different launcher is refused as immutable.
  """
  def pin_launch_path(actor, slug, version, launch_path) do
    with true <- authorized?(actor),
         true <- is_binary(slug),
         %Publication{manifest: manifest} = publication <- Repo.get(Publication, slug),
         %{} = release <- Games.release(manifest, version),
         true <- Games.launch_path?(launch_path) do
      case release["launch_path"] do
        ^launch_path ->
          {:ok, publication}

        nil ->
          releases =
            Enum.map(manifest["releases"], fn
              %{"version" => ^version} = release -> Map.put(release, "launch_path", launch_path)
              release -> release
            end)

          save(actor, Map.put(manifest, "releases", releases))

        _other ->
          {:error, :immutable_release}
      end
    else
      _ -> {:error, :invalid_publication}
    end
  end

  @release_bytes ~w(version attachment_id sha256 byte_size)

  # A new version is appended. Republishing an existing version (a rollback)
  # must name the same bytes; it may pin a launcher the release never named,
  # but never change one it did. nil means the release would change.
  defp with_release(releases, release) do
    case Enum.find(releases, &(&1["version"] == release["version"])) do
      nil ->
        releases ++ [release]

      existing ->
        if Map.take(existing, @release_bytes) == Map.take(release, @release_bytes) and
             (is_nil(release["launch_path"]) or
                existing["launch_path"] in [nil, release["launch_path"]]) do
          Enum.map(releases, fn
            ^existing ->
              put_launch_path(existing, existing["launch_path"] || release["launch_path"])

            other ->
              other
          end)
        end
    end
  end

  defp put_launch_path(release, nil), do: release
  defp put_launch_path(release, path), do: Map.put(release, "launch_path", path)

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  # Anything else that is not a string is kept, so validation refuses it.
  defp blank_to_nil(value), do: value

  defp authorized?(actor),
    do: Tenancy.root_admin?(actor) and not is_nil(Games.user(actor.id))

  defp configured(slug),
    do:
      Enum.find(
        List.wrap(Application.get_env(:platform, :game_publications, [])),
        &(&1["slug"] == slug)
      )

  defp immutable?(nil, _), do: true

  defp immutable?(previous, manifest) do
    # A release's bytes never change. Its launcher may be pinned once where it
    # named none (older manifests), and never changed after that.
    Enum.all?(previous["releases"], fn release ->
      case Games.release(manifest, release["version"]) do
        %{} = next ->
          Map.delete(next, "launch_path") == Map.delete(release, "launch_path") and
            release["launch_path"] in [nil, next["launch_path"]]

        nil ->
          false
      end
    end)
  end

  defp community(actor, previous, manifest) do
    id = manifest["community_space_id"] || (previous && previous["community_space_id"])

    if id do
      manifest = Map.put(manifest, "community_space_id", id)
      if Games.community(manifest, actor), do: {:ok, manifest}, else: {:error, :invalid_community}
    else
      with %Tenancy.Org{archived_at: nil} <- Tenancy.get_org(manifest["org_id"]),
           {:ok, room} <-
             Chat.create_channel(%{
               name: manifest["title"] <> " players",
               org_id: manifest["org_id"],
               slug:
                 "game-" <>
                   manifest["slug"] <>
                   "-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
               metadata: %{"public_game_slug" => manifest["slug"]}
             }),
           {:ok, _} <-
             Chat.add_participant(room.id, %{
               participant_id: actor.id,
               participant_type: "user",
               role: "admin",
               joined_at: DateTime.utc_now(),
               display_name: Games.player_display_name(actor)
             }) do
        {:ok, Map.put(manifest, "community_space_id", room.id)}
      else
        _ -> {:error, :invalid_community}
      end
    end
  end
end
