# Seed fixture for the scripted embed history spec
# (e2e/tests/scripted_embed_history.spec.ts, task 01a18834 stage 3).
#
# What it builds, and why each piece is there:
#
#   two users     `embedhist-editor` (a space member: the spec's editor, in
#                 two browser contexts at once) and `embedhist-viewer` (a
#                 root-org member who is NOT a participant of the space, so a
#                 non-editor: the version list shows and Pin is hidden).
#                 Created through `Accounts.find_or_create_from_oidc/1` with
#                 the exact `dev-<slug>` sub `/dev/login?as=<slug>` uses.
#   a channel     `embedhist-fixture`, in the root org, editor as member.
#   a prototype   "Retention fixture", an ordinary (not canvas-owned)
#                 prototype with v1 and v2. v1 is then REMOVED the way
#                 `Platform.Prototypes.Purger` removes one: `removed_at` set
#                 and every manifest key deleted from storage, so the serve
#                 route answers 404 for it and no bytes remain.
#   a canvas      a chat canvas whose root stack holds:
#                   `plain`  an embed with no scripts (srcdoc, sandbox="");
#                   `se`     a `scripts: true` embed whose HTML has a
#                            `<button id="bump">` that calls
#                            `window.suite.state.increment("count")` and paints
#                            the room's `count`, plus a visible `VERSION=N`;
#                   `plive`  a `prototype` node following the retention
#                            prototype's latest (v2), so the fullscreen case
#                            has a live prototype frame;
#                   `pgone`  a `prototype` node pinned to the removed v1.
#                 It is written three times: revision 1 carries VERSION=1,
#                 revisions 2 and 3 patch `se`'s srcdoc to VERSION=2 and 3,
#                 which publishes canvas-owned prototype v2 and v3.
#
# Idempotent: a re-run reuses the users, the space, both prototypes and the
# canvas row it finds. If an interrupted spec left `se` pinned to an older
# version, the re-run patches the VERSION=3 HTML back in; `publish_embed`
# reuses v3 by its sha, so no version is ever added by a re-run.
#
# EMBEDHIST_SUFFIX (optional) appends to the space slug and canvas title, so
# an anti-vacuity run can build a separate, deliberately broken fixture
# without disturbing the normal one.
#
# Prototype publishing is off by default on an install, so this script turns
# it on in the settings singleton. DEV ONLY: never run it under MIX_ENV=test
# (a `mix run` there escapes the Ecto sandbox and pollutes the test DB).
#
# Run from apps/platform (in the dev container on the dev-server rig):
#   mix run priv/scripts/seed_scripted_embed_history_fixture.exs
#
# Prints KEY=value lines (CANVAS_ID, SPACE_ID, SPACE_SLUG, EDITOR_SLUG,
# VIEWER_SLUG, EMBED_PROTOTYPE_ID, RETENTION_PROTOTYPE_ID, REMOVED_VERSION,
# REV_V1, REV_V2, REV_V3, CURRENT_REVISION); the spec reads them as
# FIXTURE_<KEY> environment variables.

import Ecto.Query

alias Platform.Accounts
alias Platform.Chat
alias Platform.Prototypes
alias Platform.Prototypes.Prototype
alias Platform.Prototypes.Settings
alias Platform.Prototypes.Storage
alias Platform.Prototypes.Version
alias Platform.Repo
alias Platform.Tenancy

if Mix.env() != :dev do
  raise "seed_scripted_embed_history_fixture.exs is dev-only (MIX_ENV=#{Mix.env()})"
end

suffix = System.get_env("EMBEDHIST_SUFFIX", "")
editor_slug = "embedhist-editor"
viewer_slug = "embedhist-viewer"
space_slug = "embedhist-fixture#{suffix}"
canvas_title = "Scripted embed history fixture#{suffix}"
retention_name = "Retention fixture#{suffix}"

org = Tenancy.get_root_org() || raise("no root org in this database")

user_for = fn slug ->
  {:ok, user} =
    Accounts.find_or_create_from_oidc(%{
      sub: "dev-#{slug}",
      email: "#{slug}@localhost",
      name: "Dev #{String.capitalize(slug)}"
    })

  user
end

editor = user_for.(editor_slug)
viewer = user_for.(viewer_slug)

{:ok, _settings} =
  Settings.get()
  |> Settings.changeset(%{enabled: true, who_may_publish: "members"})
  |> Repo.update()

space =
  case Chat.get_space_by_slug(space_slug) do
    nil ->
      {:ok, s} =
        Chat.create_space(%{
          name: "Scripted embed history fixture",
          slug: space_slug,
          kind: "channel",
          org_id: org.id
        })

      s

    existing ->
      existing
  end

author =
  case Repo.one(
         from(p in Chat.Participant,
           where:
             p.space_id == ^space.id and p.participant_type == "user" and
               p.participant_id == ^editor.id,
           limit: 1
         )
       ) do
    nil ->
      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: editor.id,
          display_name: editor.name,
          joined_at: DateTime.utc_now()
        })

      p

    p ->
      p
  end

# The viewer must stay a NON-participant. Opening the channel in /chat as the
# viewer joins them to it (ChatLive adds a participant row for an org member
# browsing a public channel), and a participant is a canvas writer
# (`CanvasAccess.fetch_for_writer/2`), so Pin would then be real for them.
# Measured while building this fixture. A re-run removes any such row, so the
# viewer reaches the canvas only through the org-reader grant on
# /canvases/<id>. Never open /chat/<SPACE_SLUG> as the viewer.
Repo.all(
  from(p in Chat.Participant,
    where:
      p.space_id == ^space.id and p.participant_type == "user" and
        p.participant_id == ^viewer.id
  )
)
|> Enum.each(fn p -> {:ok, _} = Chat.remove_participant(p) end)

# The scripted embed's page. `#bump` writes to the canvas room through the
# bridge (priv/prototype/suite.js); `#count` paints the room's value on every
# snapshot and diff, so a second window shows a click made in the first.
# `#conn` reads `connected` / `offline`: a frame with no room (a history
# preview) never gets a snapshot and settles on `offline`.
scripted_html = fn n ->
  colour = Enum.at(["#0e7490", "#7c3aed", "#b45309"], n - 1)

  """
  <!doctype html>
  <html>
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body { margin: 0; height: 100%; }
    body { display: flex; flex-direction: column; align-items: center;
           justify-content: center; gap: 14px; background: #{colour};
           color: #fff; font-family: sans-serif; }
    #ver { font-size: 48px; font-weight: 700; }
    #bump { font-size: 24px; padding: 14px 40px; border: 0;
            border-radius: 14px; background: #fde68a; color: #111; }
    #state { font-size: 20px; }
  </style>
  </head>
  <body>
  <div id="ver">VERSION=#{n}</div>
  <button id="bump" type="button">Bump</button>
  <div id="state">count=<span id="count">0</span> · <span id="conn">connecting</span></div>
  <script>
    (function () {
      function room() { return window.suite }
      function paint() {
        var s = room()
        if (!s) return
        var v = s.state.get("count")
        document.getElementById("count").textContent = String(v == null ? 0 : v)
        document.getElementById("conn").textContent = s.connected ? "connected" : "offline"
      }
      function start() {
        var s = room()
        if (!s) { document.getElementById("conn").textContent = "no bridge"; return }
        s.on("change", paint)
        s.ready.then(paint)
        document.getElementById("bump").addEventListener("click", function () {
          s.state.increment("count", 1).then(paint, function (e) {
            document.getElementById("conn").textContent = "error " + e.message
          })
        })
      }
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start)
      else start()
    })()
  </script>
  </body>
  </html>
  """
end

retention_html = fn n ->
  """
  <!doctype html>
  <html>
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
  <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#14532d;color:#fff;font-family:sans-serif">
  <div style="font-size:40px;font-weight:700">RETENTION v#{n}</div>
  </body>
  </html>
  """
end

# ── The retention prototype: v1 removed the purger's way, v2 live ─────────

retention =
  case Repo.one(
         from(p in Prototype,
           where: p.space_id == ^space.id and p.name == ^retention_name and is_nil(p.canvas_id),
           limit: 1
         )
       ) do
    nil ->
      publisher = %{kind: :user, user: editor}

      {:ok, %{prototype: p}} =
        Prototypes.publish(
          publisher,
          %{org_id: org.id, space_id: space.id, name: retention_name},
          {:files, %{"index.html" => %{"content" => retention_html.(1)}}}
        )

      {:ok, %{prototype: p}} =
        Prototypes.publish(
          publisher,
          %{prototype: p},
          {:files, %{"index.html" => %{"content" => retention_html.(2)}}}
        )

      p

    p ->
      p
  end

removed_version = 1

case Repo.one(
       from(v in Version,
         where: v.prototype_id == ^retention.id and v.version == ^removed_version
       )
     ) do
  %Version{removed_at: nil} = v ->
    {1, _} =
      Repo.update_all(from(x in Version, where: x.id == ^v.id and is_nil(x.removed_at)),
        set: [removed_at: DateTime.utc_now()]
      )

    Enum.each(v.manifest, fn %{"storage_key" => key} -> :ok = Storage.delete(key) end)

  _ ->
    :ok
end

# ── The canvas ───────────────────────────────────────────────────────────

wait_for_revision = fn canvas_id, revision ->
  Enum.reduce_while(1..50, nil, fn _, _ ->
    case Chat.get_canvas(canvas_id) do
      %{document: %{"revision" => r}} = c when r >= revision ->
        {:halt, c}

      _ ->
        Process.sleep(100)
        {:cont, nil}
    end
  end) || raise("canvas #{canvas_id} never reached revision #{revision}")
end

scripted_ref = fn canvas ->
  canvas.document["root"]["children"]
  |> Enum.find(&(&1["id"] == "se"))
  |> get_in(["props", "prototype_ref"])
end

existing_canvas =
  Repo.one(
    from(c in Chat.Canvas,
      where: c.space_id == ^space.id and c.title == ^canvas_title and is_nil(c.deleted_at),
      limit: 1
    )
  )

canvas =
  case existing_canvas do
    nil ->
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{
              "id" => "title",
              "type" => "heading",
              "props" => %{"value" => "Scripted embed history", "level" => 2}
            },
            %{
              "id" => "plain",
              "type" => "embed",
              "props" => %{
                "srcdoc" =>
                  "<p style=\"font-family:sans-serif;margin:12px\">Plain embed, no scripts</p>",
                "height" => 100,
                "width" => 600
              }
            },
            %{
              "id" => "se",
              "type" => "embed",
              "props" => %{
                "srcdoc" => scripted_html.(1),
                "scripts" => true,
                "height" => 360,
                "width" => 600
              }
            },
            %{
              "id" => "plive",
              "type" => "prototype",
              "props" => %{"prototype_id" => retention.id, "height" => 300, "width" => 600}
            },
            %{
              "id" => "pgone",
              "type" => "prototype",
              "props" => %{
                "prototype_id" => retention.id,
                "version" => removed_version,
                "height" => 300,
                "width" => 600
              }
            }
          ]
        }
      }

      {:ok, c, _message} =
        Chat.create_canvas_with_message(space.id, author.id, %{
          "title" => canvas_title,
          "document" => document
        })

      for n <- [2, 3] do
        # Distinct written_at per revision, and each write lands before the next.
        Process.sleep(300)

        {:ok, _} =
          Chat.patch_canvas({:user, editor.id}, Chat.get_canvas(c.id), [
            {:set_props, "se", %{"srcdoc" => scripted_html.(n)}}
          ])

        wait_for_revision.(c.id, n)
      end

      c

    c ->
      c
  end

canvas = Chat.get_canvas(canvas.id)

canvas =
  case scripted_ref.(canvas) do
    %{"version" => 3} ->
      canvas

    _ ->
      revision = canvas.document["revision"]

      {:ok, _} =
        Chat.patch_canvas({:user, editor.id}, canvas, [
          {:set_props, "se", %{"srcdoc" => scripted_html.(3)}}
        ])

      wait_for_revision.(canvas.id, revision + 1)
  end

ref = scripted_ref.(canvas)
3 = ref["version"]

versions =
  Repo.all(
    from(v in Chat.Canvas.Version,
      where: v.canvas_id == ^canvas.id,
      order_by: [asc: v.revision],
      select: {v.revision, v.document}
    )
  )

first_revision_with = fn n ->
  Enum.find_value(versions, fn {revision, doc} ->
    ref_version =
      doc["root"]["children"]
      |> Enum.find(&(&1["id"] == "se"))
      |> get_in(["props", "prototype_ref", "version"])

    if ref_version == n, do: revision
  end) || raise("no canvas revision holds scripted embed v#{n}")
end

IO.puts("CANVAS_ID=#{canvas.id}")
IO.puts("SPACE_ID=#{space.id}")
IO.puts("SPACE_SLUG=#{space.slug}")
IO.puts("EDITOR_SLUG=#{editor_slug}")
IO.puts("VIEWER_SLUG=#{viewer_slug}")
IO.puts("EMBED_PROTOTYPE_ID=#{ref["prototype_id"]}")
IO.puts("RETENTION_PROTOTYPE_ID=#{retention.id}")
IO.puts("REMOVED_VERSION=#{removed_version}")
IO.puts("REV_V1=#{first_revision_with.(1)}")
IO.puts("REV_V2=#{first_revision_with.(2)}")
IO.puts("REV_V3=#{first_revision_with.(3)}")
IO.puts("CURRENT_REVISION=#{canvas.document["revision"]}")
