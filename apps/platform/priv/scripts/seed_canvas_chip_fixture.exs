# Seed fixture for the linked-canvas chip geometry guard (task 01a002bd).
#
# Creates one task carrying four attached canvases whose titles exercise the
# cases the guard cares about:
#
#   long          a real design-direction title that wraps at the panel width
#   short         a one-line title, the positive control
#   pathological  several sentences, for the two-line clamp
#   deleted       a soft-deleted canvas, for the strip's second render branch
#
# The `deleted` fixture carries a long title AND a `deleted_at`. The title is
# seeded even though the panel does not render it (see below) so the fixture
# describes the intent rather than the current plumbing: a reader comparing
# this script against the rendered chip can see at a glance that the title is
# dropped on the way out, not missing on the way in.
#
# Idempotent: re-running reuses the task with the same title tag rather than
# stacking duplicates, so the spec can seed and re-seed freely.
#
# Run from apps/platform:
#   mix run priv/scripts/seed_canvas_chip_fixture.exs
#
# Prints `TASK_ID=<uuid>` on the last line for the caller to capture.

import Ecto.Query

alias Platform.Chat
alias Platform.Repo
alias Platform.Tasks
alias Platform.Tasks.CanvasAttachment

tag = System.get_env("FIXTURE_TAG") || "canvas-chip-fixture"

space =
  Chat.get_space_by_slug("general") ||
    raise("no `general` space in this database — seed it before running this script")

user =
  Repo.one(from(u in Platform.Accounts.User, order_by: [asc: u.inserted_at], limit: 1)) ||
    raise("no users in this database")

# `chat_canvases.created_by` is a FK onto `chat_participants(id)`, NOT onto
# `users(id)` — passing a user id raises chat_canvases_created_by_fkey.
participant =
  Repo.one(
    from(p in Platform.Chat.Participant,
      where: p.space_id == ^space.id and p.participant_type == "user",
      order_by: [asc: p.joined_at],
      limit: 1
    )
  ) || raise("no user participants in the `general` space")

project =
  Repo.one(from(p in Platform.Tasks.Project, order_by: [asc: p.inserted_at], limit: 1)) ||
    raise("no projects in this database")

task =
  case Repo.one(from(t in Tasks.Task, where: t.title == ^tag, limit: 1)) do
    nil ->
      {:ok, t} =
        Tasks.create_task(%{
          project_id: project.id,
          title: tag,
          description: "Fixture for the canvas-chip geometry guard. Safe to delete.",
          status: "backlog"
        })

      t

    existing ->
      existing
  end

# The four titles. `long` and `pathological` are the cases that break today;
# `short` is the control that must NOT change; `deleted` covers the strip's
# OTHER render branch, which was broken identically and which a live-only
# fixture leaves unpinned.
titles = [
  {"long", "Design direction — the ruling belongs on the document, not in a queue", false},
  {"short", "Sprint notes", false},
  {"pathological",
   "Design direction — an extremely long title that keeps going well past any " <>
     "reasonable width, so far past it that no two-line clamp could hold it, " <>
     "which is exactly the case the ellipsis exists to absorb rather than let " <>
     "one chip take over the whole strip", false},
  {"deleted",
   "Superseded evidence sheet — the upstream canvas was removed after the " <>
     "ruling landed, so this row is now a detach affordance", true}
]

for {kind, title, soft_delete?} <- titles do
  canvas =
    case Repo.one(from(c in Chat.Canvas, where: c.title == ^title, limit: 1)) do
      nil ->
        {:ok, c} =
          Chat.create_canvas(%{space_id: space.id, created_by: participant.id, title: title})

        c

      existing ->
        existing
    end

  # Soft-delete AFTER creation, and re-apply on every run: `create_canvas`
  # has no way to be born deleted, and the lookup above may have found a row
  # a previous run left live. `delete_changeset/2` casts only `deleted_at`,
  # so this cannot disturb the stored document.
  #
  # Soft deletion is what makes `CanvasAttachments.canvas_envelope/1` collapse
  # the row to `nil`, which is what makes `entry.canvas_present` false, which
  # is what selects the `<span data-role="linked-canvas-chip-deleted">`
  # branch in the strip. The attachment row itself stays untouched — the
  # canvas reference is soft (no FK), so the join row survives its target.
  canvas =
    if soft_delete? do
      {:ok, c} =
        canvas
        |> Chat.Canvas.delete_changeset(%{deleted_at: DateTime.utc_now()})
        |> Repo.update()

      c
    else
      canvas
    end

  # Insert the join row directly rather than through
  # `CanvasAttachments.attach_canvas/4`. That function gates on
  # `ensure_task_touchable/3`, which rejects a nil actor with
  # `:task_forbidden` — correct for the MCP surface, but this is a fixture
  # with no acting principal and modelling one would test the seed, not the
  # chip. The read path (`list_task_canvases/1`) takes no actor, so what the
  # panel renders is identical either way.
  {:ok, _} =
    %CanvasAttachment{}
    |> CanvasAttachment.changeset(%{
      task_id: task.id,
      canvas_id: canvas.id,
      attached_by_kind: "user",
      attached_by_id: user.id
    })
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:task_id, :canvas_id]
    )

  IO.puts("attached #{kind}: #{canvas.id}")
end

IO.puts("USER_SLUG=#{user.oidc_sub |> to_string() |> String.replace_prefix("dev-", "")}")
IO.puts("TASK_ID=#{task.id}")
