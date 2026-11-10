defmodule Platform.Games.Publishing do
  @moduledoc "Root-admin publication without a host restart. Release versions are immutable."
  import Ecto.Query
  alias Platform.{Chat, Games, Repo, Tenancy}
  alias Platform.Games.Publication

  def list(actor) do
    if Tenancy.root_admin?(actor),
      do: Repo.all(from(p in Publication, order_by: p.slug)),
      else: []
  end

  def publish_release(actor, attrs) do
    with true <- Tenancy.root_admin?(actor),
         true <- Platform.UUID.valid?(attrs["attachment_id"]),
         %Platform.Chat.Attachment{state: "ready"} = attachment <-
           Repo.get(Platform.Chat.Attachment, attrs["attachment_id"]),
         %Tenancy.Org{archived_at: nil} <- Tenancy.get_org(attrs["org_id"]) do
      stored = Repo.get(Publication, attrs["slug"])
      previous = if stored, do: stored.manifest, else: configured(attrs["slug"])

      release = %{
        "version" => attrs["version"],
        "attachment_id" => attachment.id,
        "sha256" => attachment.content_hash,
        "byte_size" => attachment.byte_size
      }

      releases = if previous, do: previous["releases"], else: []

      releases =
        if Enum.any?(releases, &(&1["version"] == release["version"])),
          do: releases,
          else: releases ++ [release]

      if Enum.find(releases, &(&1["version"] == release["version"])) == release do
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
      else
        {:error, :immutable_release}
      end
    else
      _ -> {:error, :invalid_publication}
    end
  end

  def save(actor, manifest) do
    if Tenancy.root_admin?(actor) and is_map(manifest) and Games.valid?(manifest) do
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

  defp configured(slug),
    do:
      Enum.find(
        List.wrap(Application.get_env(:platform, :game_publications, [])),
        &(&1["slug"] == slug)
      )

  defp immutable?(nil, _), do: true

  defp immutable?(previous, manifest) do
    Enum.all?(previous["releases"], fn release ->
      Games.release(manifest, release["version"]) == release
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
               display_name: Games.player_display_name(actor)
             }) do
        {:ok, Map.put(manifest, "community_space_id", room.id)}
      else
        _ -> {:error, :invalid_community}
      end
    end
  end
end
