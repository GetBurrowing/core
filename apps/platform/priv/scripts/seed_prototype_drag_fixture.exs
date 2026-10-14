# Seed fixture for the prototype fullscreen DRAG spec
# (e2e/tests/prototype_fullscreen_drag.spec.ts, task 01a1389f v2 stage 1).
#
# Mirrors seed_prototype_fullscreen_fixture.exs (left untouched) with its own
# user, channel and prototype, so the two specs never share state.
#
# What it builds, and why each piece is there:
#
#   a user        `protodrag-a`, created through
#                 `Accounts.find_or_create_from_oidc/1` with the exact
#                 `dev-<slug>` sub that `/dev/login?as=<slug>` uses, so the
#                 login lands on THIS row and it gets the root-org membership
#                 the prototype serve route checks.
#   a channel     `protodrag-fixture`, in the root org, with the user a member.
#   a prototype   published by `protodrag-a`. Its page is split in two:
#                   #drag  a pointer-driven draggable with `touch-action: none`
#                          (the shape of a slider, a canvas, a map);
#                   #pan   a plain touchmove/pointermove tracker with NO
#                          preventDefault and the default touch-action, so the
#                          browser stays free to treat the gesture as its own.
#                 Both count every move they receive, per input type, in
#                 `window.__moves` (and on screen), so the spec can prove a
#                 drag actually reached the prototype: a drag that never
#                 arrives cannot be evidence that a drag does not exit.
#   a canvas      a chat canvas message whose document ROOT is a `prototype`
#                 node, so the PrototypeFrame renders directly in the chat row.
#   later text    a few plain messages after the canvas, so the chat scroller
#                 has something to scroll (the spec records scrollTop).
#
# Prototype publishing is off by default on an install, so this script turns
# it on in the settings singleton. DEV ONLY: never run it under MIX_ENV=test
# (a `mix run` there escapes the Ecto sandbox and pollutes the test DB).
#
# Idempotent: a second run reuses the user, the space and the canvas row it
# finds, and re-publishes the page as a new version of the same prototype so
# the frame always serves the HTML in this file.
#
# Run from apps/platform (in the dev container on the moon rig):
#   mix run priv/scripts/seed_prototype_drag_fixture.exs
#
# Prints CANVAS_ID=, SPACE_ID=, SPACE_SLUG= and USER_SLUG= lines.

import Ecto.Query

alias Platform.Accounts
alias Platform.Chat
alias Platform.Prototypes
alias Platform.Prototypes.Settings
alias Platform.Repo
alias Platform.Tenancy

if Mix.env() != :dev do
  raise "seed_prototype_drag_fixture.exs is dev-only (MIX_ENV=#{Mix.env()})"
end

user_slug = "protodrag-a"
space_slug = "protodrag-fixture"
canvas_title = "Prototype fullscreen drag fixture"

org = Tenancy.get_root_org() || raise("no root org in this database")

{:ok, user} =
  Accounts.find_or_create_from_oidc(%{
    sub: "dev-#{user_slug}",
    email: "#{user_slug}@localhost",
    name: "Dev #{String.capitalize(user_slug)}"
  })

{:ok, _settings} =
  Settings.get()
  |> Settings.changeset(%{enabled: true, who_may_publish: "members"})
  |> Repo.update()

space =
  case Chat.get_space_by_slug(space_slug) do
    nil ->
      {:ok, s} =
        Chat.create_space(%{
          name: "Prototype fullscreen drag fixture",
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
               p.participant_id == ^user.id,
           limit: 1
         )
       ) do
    nil ->
      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      p

    p ->
      p
  end

# Two full-width bands. `#drag` takes pointer capture and moves a knob with
# the pointer (touch-action: none, so the browser hands it every move);
# `#pan` only listens (no preventDefault, default touch-action). Every move
# event the document sees is counted by type and by band in window.__moves;
# `pressed` counts only moves made with a finger or button down.
index_html = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body { margin: 0; height: 100%; font-family: sans-serif; }
  body { display: flex; flex-direction: column; }
  #drag { flex: 1 1 50%; position: relative; touch-action: none;
          background: #1e3a8a; color: #fff; user-select: none; }
  #knob { position: absolute; left: 20px; top: 20px; width: 64px; height: 64px;
          border-radius: 32px; background: #fbbf24; }
  #pan { flex: 1 1 50%; background: #065f46; color: #fff; user-select: none; }
  .label { position: absolute; right: 12px; bottom: 12px; font-size: 18px; }
  #pan .label { position: static; padding: 12px; display: block; }
</style>
</head>
<body>
<div id="drag"><div id="knob"></div><span class="label">drag <span id="drag-n">0</span></span></div>
<div id="pan"><span class="label">pan <span id="pan-n">0</span></span></div>
<script>
  var m = window.__moves = {
    total: 0, pressed: 0, pointermove: 0, touchmove: 0, mousemove: 0,
    drag: 0, pan: 0, down: 0, up: 0, cancel: 0, touchcancel: 0, keydown: 0
  };
  function band(t) {
    return t && t.closest ? (t.closest("#drag") ? "drag" : t.closest("#pan") ? "pan" : null) : null;
  }
  function onMove(e) {
    m.total += 1;
    m[e.type] += 1;
    // A move with a finger or button down: hover moves never count as drag.
    if (e.type === "touchmove" || e.buttons > 0) m.pressed += 1;
    var t = e.type === "touchmove" && e.touches && e.touches[0]
      ? document.elementFromPoint(e.touches[0].clientX, e.touches[0].clientY) || e.target
      : e.target;
    var b = band(t);
    if (b) m[b] += 1;
    document.getElementById("drag-n").textContent = String(m.drag);
    document.getElementById("pan-n").textContent = String(m.pan);
  }
  ["pointermove", "touchmove", "mousemove"].forEach(function (type) {
    document.addEventListener(type, onMove, { capture: true, passive: true });
  });
  document.addEventListener("pointerdown", function () { m.down += 1; }, true);
  document.addEventListener("pointerup", function () { m.up += 1; }, true);
  document.addEventListener("pointercancel", function () { m.cancel += 1; }, true);
  document.addEventListener("touchcancel", function () { m.touchcancel += 1; }, true);
  // Keys that land in the frame (focus inside it) never reach the parent.
  document.addEventListener("keydown", function () { m.keydown += 1; }, true);

  var drag = document.getElementById("drag");
  var knob = document.getElementById("knob");
  var dragging = false;
  drag.addEventListener("pointerdown", function (e) {
    dragging = true;
    try { drag.setPointerCapture(e.pointerId); } catch (_) {}
  });
  drag.addEventListener("pointermove", function (e) {
    if (!dragging) return;
    var r = drag.getBoundingClientRect();
    knob.style.left = (e.clientX - r.left - 32) + "px";
    knob.style.top = (e.clientY - r.top - 32) + "px";
  });
  drag.addEventListener("pointerup", function () { dragging = false; });
  drag.addEventListener("pointercancel", function () { dragging = false; });
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
          %{org_id: org.id, space_id: space.id, name: "Drag and pan"},
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
            content: "Later message #{i}: a chat row below the drag prototype."
          })
      end

      canvas

    c ->
      # Re-publish the page as a new version of the same prototype, so an
      # edit to the HTML above takes effect on a re-seed. The canvas node
      # pins no version, so the frame follows the latest one.
      prototype = Prototypes.get_prototype(c.document["root"]["props"]["prototype_id"])

      {:ok, _} =
        Prototypes.publish(
          %{kind: :user, user: user},
          %{prototype: prototype},
          {:files, %{"index.html" => %{"content" => index_html}}}
        )

      c
  end

IO.puts("CANVAS_ID=#{canvas.id}")
IO.puts("SPACE_ID=#{space.id}")
IO.puts("SPACE_SLUG=#{space.slug}")
IO.puts("USER_SLUG=#{user_slug}")
