# Seeds the three Burrow Play games: Voltron (featured, first) and two clearly
# labelled placeholder games, each as a complete game record set.
#
# Run with:
#   cd apps/platform && mix run priv/repo/seeds/play_games.exs
#
# Needs a writable CHAT_ATTACHMENTS_ROOT for the build zips, a root admin user
# (visit /dev/login once on a fresh dev DB) and the root
# org. Everything goes through context functions:
#
#   * Create project      Platform.Tasks.create_project/1, slug "game-<slug>",
#                         with one epic and a few unassigned backlog tasks
#   * development space   Platform.Chat.create_channel/1, slug "game-<slug>-dev",
#                         metadata %{"game_slug", "project_id", "goal_project_id"}
#                         (goal_project_id scopes the channel to the project in
#                         Create); separate from the players room
#   * release build       Platform.Chat.AttachmentStorage.persist_binary_upload/3
#                         and Platform.Chat.create_attachment/1, a small zip
#   * publication         Platform.Games.Publishing.publish_release/2, which
#                         also creates the tagged players room (community_space_id)
#   * presentation        Platform.Games.Publishing.save/2 adds image_path,
#                         image_alt, portrait_path, project_id, development_space_id,
#                         position, featured and placeholder to the manifest
#
# Re-running adds nothing: projects, spaces and epics are found by slug or
# name, tasks by (project, title), and a release version that is already
# published is never re-uploaded. When a game already has a publication (an
# install where the real Voltron build is published), its releases are kept
# and only the missing records and presentation fields are filled in.
#
# The builds are tiny zips (README plus a minimal HTML5 page). Placeholder
# builds say TEST BUILD in the file name, README and page. Nothing here holds a
# room code, server address or credential, and no player or online counts are
# recorded.

import Ecto.Query

alias Platform.{Chat, Repo, Tasks, Tenancy}
alias Platform.Chat.AttachmentStorage
alias Platform.Games.{Publication, Publishing}
alias Platform.Tasks.{Epic, Project, Task}

games = [
  %{
    slug: "voltron",
    title: "Voltron",
    summary: "Pilot a lion, form Voltron, and smash things with your crew.",
    position: 0,
    featured: true,
    placeholder: false,
    version: "dev-stub",
    image_path: "/images/voltron-game.png",
    image_alt: "Voltron gameplay",
    portrait_path: "/images/play/voltron-portrait.png",
    build_label: "DEV STUB",
    tasks: [
      "Playtest the current Windows release with the crew",
      "Match server pack for the published release",
      "Capture store screenshots from a real session"
    ]
  },
  %{
    slug: "sky-haulers",
    title: "Placeholder: Sky Haulers",
    summary:
      "Placeholder test build: a cargo-hauling co-op between floating islands, used to test downloads and player rooms. Not a real game.",
    position: 1,
    featured: false,
    placeholder: true,
    version: "0.1.0-test",
    image_path: "/images/play/sky-haulers-cover.png",
    image_alt: "Placeholder cover: floating islands and kites",
    portrait_path: "/images/play/sky-haulers-portrait.png",
    build_label: "TEST BUILD",
    tasks: [
      "Download the test build from the game page and check its SHA-256",
      "Join the players room from the game page",
      "Publish a second test version and confirm the update path"
    ]
  },
  %{
    slug: "tiny-tactics",
    title: "Placeholder: Tiny Tactics",
    summary:
      "Placeholder test build: a tiny turn-based hex skirmish, used to test releases, updates and Create projects. Not a real game.",
    position: 2,
    featured: false,
    placeholder: true,
    version: "0.1.0-test",
    image_path: "/images/play/tiny-tactics-cover.png",
    image_alt: "Placeholder cover: a hex board with a star",
    portrait_path: "/images/play/tiny-tactics-portrait.png",
    build_label: "TEST BUILD",
    tasks: [
      "Download the test build from the game page and check its SHA-256",
      "Join the players room from the game page",
      "Unpublish and republish to check the store page hides and returns"
    ]
  }
]

org =
  Tenancy.get_root_org() ||
    raise "play_games.exs: no root org. Run `mix ecto.migrate` first."

actor =
  Repo.all(
    from(m in Tenancy.OrgMembership,
      join: u in Platform.Accounts.User,
      on: u.id == m.user_id,
      where:
        m.org_id == ^org.id and m.role == "admin" and m.external == false and
          is_nil(u.archived_at),
      order_by: u.inserted_at,
      select: u
    )
  )
  |> List.first() ||
    raise "play_games.exs: no root admin user. Visit /dev/login once, then re-run."

ok! = fn
  {:ok, value}, _what -> value
  other, what -> raise "play_games.exs: #{what} failed: #{inspect(other)}"
end

build_zip = fn game ->
  label = game.build_label
  name = String.replace_prefix(game.title, "Placeholder: ", "")

  readme = """
  #{name} (#{label}, version #{game.version})

  #{if game.placeholder, do: "This is a PLACEHOLDER game: a test fixture for Burrow Play.\nIt is not a real game and has no gameplay.\n", else: "Development stub for a local Burrow Play database. It is not the real release.\n"}
  Open index.html in a browser to see the test page.
  """

  page = """
  <!doctype html>
  <html lang="en">
  <head><meta charset="utf-8"><title>#{name}: #{label}</title></head>
  <body style="font-family:sans-serif;background:#111;color:#eee;padding:2rem">
  <h1>#{name}</h1>
  <p><strong>#{label}</strong> · version #{game.version}</p>
  <p>#{if game.placeholder, do: "Placeholder game for testing Burrow Play. Nothing to play here.", else: "Development stub. Not the real release."}</p>
  </body>
  </html>
  """

  # The Windows player currently launches "Play Voltron.bat" from every
  # release root (GamePageController.updates/2), so each build carries it.
  launcher =
    "@echo off\r\nrem #{name} #{label}: opens the test page.\r\nstart \"\" \"%~dp0index.html\"\r\n"

  files = [
    {~c"README.txt", readme},
    {~c"index.html", page},
    {~c"Play Voltron.bat", launcher}
  ]

  {:ok, {_, bytes}} = :zip.create(~c"build.zip", files, [:memory])
  bytes
end

for game <- games do
  project =
    Repo.get_by(Project, slug: "game-" <> game.slug) ||
      ok!.(
        Tasks.create_project(%{
          name: game.title,
          slug: "game-" <> game.slug,
          org_id: org.id
        }),
        "project #{game.slug}"
      )

  dev_space =
    Repo.one(from(s in Chat.Space, where: s.slug == ^"game-#{game.slug}-dev")) ||
      ok!.(
        Chat.create_channel(%{
          name: game.title <> " dev",
          slug: "game-#{game.slug}-dev",
          org_id: org.id,
          created_by: actor.id,
          description:
            if(game.placeholder,
              do: "Development space for a placeholder test game.",
              else: "Development space for #{game.title}."
            ),
          metadata: %{
            "game_slug" => game.slug,
            "project_id" => project.id,
            "goal_project_id" => project.id
          }
        }),
        "dev space #{game.slug}"
      )

  dev_space =
    if dev_space.metadata["goal_project_id"] == project.id do
      dev_space
    else
      ok!.(
        Chat.update_space(dev_space, %{
          metadata:
            Map.merge(dev_space.metadata || %{}, %{
              "game_slug" => game.slug,
              "project_id" => project.id,
              "goal_project_id" => project.id
            })
        }),
        "dev space metadata #{game.slug}"
      )
    end

  unless Repo.exists?(
           from(p in Chat.Participant,
             where:
               p.space_id == ^dev_space.id and p.participant_type == "user" and
                 p.participant_id == ^actor.id
           )
         ) do
    ok!.(
      Chat.add_participant(dev_space.id, %{
        participant_id: actor.id,
        participant_type: "user",
        role: "admin",
        joined_at: DateTime.utc_now()
      }),
      "dev space participant #{game.slug}"
    )
  end

  epic =
    Repo.get_by(Epic, project_id: project.id, name: "Release and store page") ||
      ok!.(
        Tasks.create_epic(%{project_id: project.id, name: "Release and store page"}),
        "epic #{game.slug}"
      )

  for title <- game.tasks do
    unless Repo.exists?(from(t in Task, where: t.project_id == ^project.id and t.title == ^title)) do
      ok!.(
        Tasks.create_task(%{project_id: project.id, epic_id: epic.id, title: title}),
        "task #{game.slug}"
      )
    end
  end

  stored = Repo.get(Publication, game.slug)

  if is_nil(stored) do
    bytes = build_zip.(game)

    filename =
      "#{game.slug}-#{game.version}-#{String.downcase(String.replace(game.build_label, " ", "-"))}.zip"

    upload =
      ok!.(
        AttachmentStorage.persist_binary_upload(bytes, filename, "application/zip"),
        "build upload #{game.slug}"
      )

    attachment =
      ok!.(
        Chat.create_attachment(
          Map.merge(upload, %{
            space_id: dev_space.id,
            uploaded_by_user_id: actor.id,
            state: "ready",
            metadata: %{"origin" => "play_games_seed", "build" => game.build_label}
          })
        ),
        "build attachment #{game.slug}"
      )

    ok!.(
      Publishing.publish_release(actor, %{
        "slug" => game.slug,
        "org_id" => org.id,
        "title" => game.title,
        "summary" => game.summary,
        "version" => game.version,
        "attachment_id" => attachment.id,
        "published" => "true",
        "multiplayer_note" =>
          if(game.placeholder,
            do: "Placeholder test build. There is no multiplayer.",
            else: nil
          )
      }),
      "publish #{game.slug}"
    )
  end

  manifest = Repo.get!(Publication, game.slug).manifest

  # Placeholders own their copy; a real game's title and summary stay as published.
  copy =
    if game.placeholder,
      do: %{"title" => game.title, "summary" => game.summary},
      else: %{}

  presentation = %{
    "image_path" => manifest["image_path"] || game.image_path,
    "image_alt" => manifest["image_alt"] || game.image_alt,
    "portrait_path" => game.portrait_path,
    "project_id" => project.id,
    "development_space_id" => dev_space.id,
    "position" => game.position,
    "featured" => game.featured,
    "placeholder" => game.placeholder
  }

  presentation = Map.merge(presentation, copy)

  publication =
    if Map.take(manifest, Map.keys(presentation)) == presentation and
         not Map.has_key?(manifest, "dev_space_id") do
      Repo.get!(Publication, game.slug)
    else
      ok!.(
        Publishing.save(actor, manifest |> Map.delete("dev_space_id") |> Map.merge(presentation)),
        "presentation #{game.slug}"
      )
    end

  IO.puts(
    "#{game.slug}: project #{project.id}, dev space #{dev_space.id}, players room " <>
      "#{publication.manifest["community_space_id"]}, current #{publication.manifest["current_version"]}"
  )
end
