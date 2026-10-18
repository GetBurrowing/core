# Seed fixture for the prototype fullscreen touch spec
# (e2e/tests/prototype_fullscreen_touch.spec.ts, task 01a1389f stage 1).
#
# What it builds, and why each piece is there:
#
#   two users     `protofs-a` (the spec logs in as this one) and `protofs-b`
#                 (a second member, for a remote LiveView patch in a later
#                 stage). Created through `Accounts.find_or_create_from_oidc/1`
#                 with the exact `dev-<slug>` sub that `/dev/login?as=<slug>`
#                 uses, so the login lands on THESE rows and each user gets
#                 the root-org membership the prototype serve route checks.
#   a channel     `protofs-fixture`, in the root org, with both as members.
#   a prototype   published by `protofs-a`. Its single page is a full-viewport
#                 layout with a large `<button id="hold">`, so a held press can
#                 land inside the iframe on an element whose position the spec
#                 can compute from the parent page.
#   a canvas      a chat canvas message whose document ROOT is a `prototype`
#                 node, i.e. the PrototypeFrame renders directly inside
#                 `.message-row-inner` (chat_message.ex), the ancestor whose
#                 `active:scale-[0.99]` this fixture exists to exercise.
#   later text    enough plain messages AFTER the canvas that rows sit below
#                 it: a trapped overlay then visibly loses to chat content at
#                 its bottom corners, not merely to the composer.
#
# Prototype publishing is off by default on an install, so this script turns
# it on in the settings singleton. DEV ONLY: never run it under MIX_ENV=test
# (a `mix run` there escapes the Ecto sandbox and pollutes the test DB).
#
# Idempotent: a second run reuses the users, the space and the canvas row it
# finds, so the spec can re-seed freely.
#
# Run from apps/platform (in the dev container on the dev-server rig):
#   mix run priv/scripts/seed_prototype_fullscreen_fixture.exs
#
# Prints SPACE_ID=, SPACE_SLUG=, USER_SLUG= and SECOND_SLUG= lines.

import Ecto.Query

alias Platform.Accounts
alias Platform.Chat
alias Platform.Prototypes
alias Platform.Prototypes.Settings
alias Platform.Repo
alias Platform.Tenancy

if Mix.env() != :dev do
  raise "seed_prototype_fullscreen_fixture.exs is dev-only (MIX_ENV=#{Mix.env()})"
end

user_slug = "protofs-a"
second_slug = "protofs-b"
space_slug = "protofs-fixture"
canvas_title = "Prototype fullscreen fixture"

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

user = user_for.(user_slug)
second = user_for.(second_slug)

{:ok, _settings} =
  Settings.get()
  |> Settings.changeset(%{enabled: true, who_may_publish: "members"})
  |> Repo.update()

space =
  case Chat.get_space_by_slug(space_slug) do
    nil ->
      {:ok, s} =
        Chat.create_space(%{
          name: "Prototype fullscreen fixture",
          slug: space_slug,
          kind: "channel",
          org_id: org.id
        })

      s

    existing ->
      existing
  end

participant_for = fn u ->
  case Repo.one(
         from(p in Chat.Participant,
           where:
             p.space_id == ^space.id and p.participant_type == "user" and
               p.participant_id == ^u.id,
           limit: 1
         )
       ) do
    nil ->
      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: u.id,
          display_name: u.name,
          joined_at: DateTime.utc_now()
        })

      p

    p ->
      p
  end
end

author = participant_for.(user)
_second_participant = participant_for.(second)

# A full-viewport page: the button is most of the screen, so the centre of the
# fullscreen viewport is always on it. `pressed` counts presses so a reader of
# a screenshot can tell the press reached the frame.
index_html = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body { margin: 0; height: 100%; }
  body { display: flex; align-items: center; justify-content: center;
         background: #1e3a8a; font-family: sans-serif; }
  #hold { width: 80vw; height: 60vh; font-size: 28px; border: 0;
          border-radius: 24px; background: #fbbf24; color: #111; }
  #hold:active { background: #f59e0b; }
</style>
</head>
<body>
<button id="hold" type="button">Hold me <span id="pressed">0</span></button>
<script>
  var n = 0;
  document.getElementById("hold").addEventListener("click", function () {
    n += 1;
    document.getElementById("pressed").textContent = String(n);
  });
</script>
</body>
</html>
"""

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
      {:ok, %{prototype: prototype}} =
        Prototypes.publish(
          %{kind: :user, user: user},
          %{org_id: org.id, space_id: space.id, name: "Hold button"},
          {:files, %{"index.html" => %{"content" => index_html}}}
        )

      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "proto",
          "type" => "prototype",
          "props" => %{"prototype_id" => prototype.id, "width" => 390, "height" => 400}
        }
      }

      {:ok, canvas, _message} =
        Chat.create_canvas_with_message(space.id, author.id, %{
          "title" => canvas_title,
          "document" => document
        })

      for i <- 1..8 do
        {:ok, _} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: author.id,
            content_type: "text",
            content: "Later message #{i}: a chat row that sits below the prototype canvas."
          })
      end

      canvas

    c ->
      c
  end

IO.puts("CANVAS_ID=#{canvas.id}")
IO.puts("SPACE_ID=#{space.id}")
IO.puts("SPACE_SLUG=#{space.slug}")
IO.puts("USER_SLUG=#{user_slug}")
IO.puts("SECOND_SLUG=#{second_slug}")
