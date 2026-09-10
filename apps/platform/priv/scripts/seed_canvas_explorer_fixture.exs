# Seed fixture for the canvas explorer (task 01a0740d, FE-6).
#
# A five-item explorer proves nothing this ticket is about. The explorer exists
# because a real database holds hundreds of canvases across a dozen-odd spaces,
# and every claim the feature makes — bounded groups, a header count that
# exceeds the rows shown, paging that lands in the same place twice, clone
# lineage that survives a deleted parent — is unfalsifiable against nine rows.
# So this builds the corpus the feature is for.
#
# What it creates:
#
#   ~400 canvases over 16 spaces, UNEVENLY distributed. One space holds 58
#   (that is the paging subject: it is the group whose header must be able to
#   read 58 while the group shows 20). Three hold fewer than 5, so the
#   "one short group" rendering has a fixture too. A corpus with 25 canvases in
#   every space would let a per-space cap that is really a global cap look
#   correct.
#
#   A NEAR-DUPLICATE TITLE CLUSTER of five canvases in one space, all by the
#   SAME author, with distinct `updated_at` values minutes / hours / days
#   apart:
#
#     Approval flow          9 days ago
#     Approval flow v2       3 days ago      cloned_from: Approval flow
#     Approval flow v3      26 hours ago     cloned_from: Approval flow v2
#     Approval flow (3)      4 hours ago     cloned_from: Approval flow v3
#     Approval flow — final 12 minutes ago
#
#   Same author and near-identical titles on purpose: "which of these five is
#   the one I want" is the question the explorer has to answer, and it cannot
#   be answered by author or by title. It has to be answered by the timestamp
#   and by the lineage, which is why both are seeded with real spread rather
#   than five rows written in the same second.
#
#   A SIXTH canvas cloned from a parent that is then SOFT-DELETED, so the
#   "cloned from a deleted canvas" branch of `Chat.canvas_parent_titles/1` has
#   a fixture. Without it that branch is only ever exercised by unit tests and
#   nobody ever sees what it renders.
#
#   An EXECUTION SPACE whose `metadata["task_id"]` names a real task — that is
#   how `Platform.Orchestration.ExecutionSpace.find_by_task_id/1` resolves it,
#   so the reverse lookup is just `space.metadata["task_id"]` — carrying THREE
#   task canvas attachments, one of which points at a soft-deleted canvas. A
#   stale attachment row is the normal state of the world (`canvas_id` is a
#   soft reference with no FK; see `Platform.Tasks.CanvasAttachment`), so the
#   pinned group has to render correctly with one.
#
#   A LIVE MEETING in that same execution space, so
#   `Platform.Meetings.get_live_meeting_for_space/1` returns it. This is what
#   makes the pinned groups unconditional: without a live meeting the meeting
#   group is absent and a screenshot proves nothing about it either way.
#
# Idempotent. Every fixture canvas carries `metadata["fixture"] = <tag>` and
# prior runs' canvases are SOFT-DELETED rather than reused or hard-deleted,
# the same way `seed_canvas_search_snippet_fixture.exs` retires its canvas:
# every explorer read filters `is_nil(deleted_at)`, so the live corpus is the
# same size however many times this has run, and no row in
# `chat_canvas_search`, the versions table or `task_canvas_attachments` has to
# be unpicked. Spaces, the task and the meeting are keyed on deterministic
# slugs/titles and REUSED, so re-running does not accumulate spaces.
#
# Timestamp note for later stages: `inserted_at` / `updated_at` across the bulk
# corpus are spread backwards over a few months by one statement below, so the
# explorer is not looking at 400 rows that all claim to have been written in
# the same second. The cluster's five timestamps are set explicitly AFTER that
# spread and therefore win.
#
# Run from apps/platform:
#   mix run priv/scripts/seed_canvas_explorer_fixture.exs
#
# Prints SPACE_SLUGS, EXECUTION_SPACE_SLUG, TASK_ID and CLUSTER_SPACE_SLUG on
# the last lines for the caller to capture.

import Ecto.Query

alias Platform.Chat
alias Platform.Chat.Canvas
alias Platform.Meetings
alias Platform.Meetings.Meeting
alias Platform.Orchestration.ExecutionSpace
alias Platform.Repo
alias Platform.Tasks
alias Platform.Tasks.CanvasAttachment
alias Platform.Tasks.CanvasAttachments

tag = System.get_env("FIXTURE_TAG") || "canvas-explorer-fixture"
now = DateTime.utc_now()

# ── the corpus shape ────────────────────────────────────────────────────────
#
# `{name, slug_suffix, canvas_count}`. Counts are deliberately lumpy and the
# names deliberately do not sort in the order they are listed, so a group
# ordering that echoes the caller's input sequence is visible rather than
# invisible.
bulk_spaces = [
  {"Platform engineering", "platform-engineering", 58},
  {"Design system", "design-system", 47},
  {"Customer research", "customer-research", 43},
  {"Growth experiments", "growth-experiments", 39},
  {"Billing and invoicing", "billing-invoicing", 36},
  {"Onboarding", "onboarding", 34},
  {"Data and reporting", "data-reporting", 31},
  {"Security review", "security-review", 28},
  {"Mobile app", "mobile-app", 26},
  {"Support escalations", "support-escalations", 23},
  {"Hiring", "hiring", 21},
  {"Legal", "legal", 4},
  {"Office ops", "office-ops", 3},
  {"Archive attic", "archive-attic", 2}
]

cluster_space_spec = {"Approvals workstream", "approvals-workstream"}
execution_space_slug = "#{tag}-execution"

# Per-space title vocabularies, so the corpus does not read as "Doc 1..58".
# Titles are unique within a space; two spaces reusing a noun is realistic and
# harmless (the explorer groups by space).
nouns = ~w(
  runbook rollout retro spec brief audit checklist migration teardown
  postmortem proposal dashboard onboarding handoff rubric inventory
  scorecard playbook charter walkthrough
)

qualifiers = ~w(
  Q1 Q2 Q3 Q4 draft final internal external v2 v3 revised legacy
  2025 2026 north-star interim archived pilot
)

document_for = fn title ->
  %{
    "version" => 1,
    "revision" => 1,
    "root" => %{
      "id" => "root",
      "type" => "stack",
      "props" => %{"gap" => 12},
      "children" => [
        %{
          "id" => "t1",
          "type" => "text",
          "props" => %{
            "value" =>
              "#{title}. Seeded by seed_canvas_explorer_fixture.exs for the canvas " <>
                "explorer. The body is deliberately non-trivial so that a listing " <>
                "which selects `document` pays for it: the explorer renders titles, " <>
                "and `Chat.list_canvas_groups/2` must not load this node tree to do it."
          },
          "children" => []
        }
      ]
    },
    "theme" => %{},
    "bindings" => %{},
    "meta" => %{"fixture" => tag}
  }
end

# ── retire prior runs ───────────────────────────────────────────────────────
#
# One statement, not 400 updates. Soft delete only: see the header.
{retired, _} =
  Repo.update_all(
    from(c in Canvas,
      where: fragment("?->>'fixture' = ?", c.metadata, ^tag) and is_nil(c.deleted_at)
    ),
    set: [deleted_at: now]
  )

IO.puts("retired #{retired} canvas(es) from earlier runs")

# ── spaces ──────────────────────────────────────────────────────────────────

ensure_space = fn name, slug, kind, metadata ->
  case Chat.get_space_by_slug(slug) do
    nil ->
      {:ok, space} =
        Chat.create_space(%{
          "name" => name,
          "slug" => slug,
          "kind" => kind,
          "metadata" => metadata
        })

      space

    existing ->
      # Re-assert metadata: an earlier run may have created the execution space
      # before the task existed, and a space whose `task_id` is stale resolves
      # to the wrong task rather than failing loudly.
      {:ok, space} =
        existing
        |> Ecto.Changeset.change(%{metadata: Map.merge(existing.metadata || %{}, metadata)})
        |> Repo.update()

      space
  end
end

# `chat_canvases.created_by` is an FK onto `chat_participants(id)`, NOT onto
# `users(id)` — the trap both sibling seed scripts record.
ensure_participant = fn space_id, display_name ->
  Repo.one(
    from(p in Chat.Participant,
      where: p.space_id == ^space_id,
      order_by: [asc: p.joined_at],
      limit: 1
    )
  ) ||
    (fn ->
       {:ok, p} =
         Chat.add_participant(space_id, %{
           participant_type: "agent",
           participant_id: Ecto.UUID.generate(),
           display_name: display_name,
           joined_at: DateTime.utc_now()
         })

       p
     end).()
end

create_canvas = fn space_id, participant_id, author_name, title, extra ->
  attrs =
    Map.merge(
      %{
        "space_id" => space_id,
        "created_by" => participant_id,
        "created_by_display_name" => author_name,
        "created_by_participant_type" => "agent",
        "title" => title,
        "document" => document_for.(title),
        "metadata" => %{"fixture" => tag}
      },
      extra
    )

  {:ok, canvas} = Chat.create_canvas(attrs)
  canvas
end

IO.puts("seeding #{length(bulk_spaces)} bulk spaces …")

bulk_results =
  Enum.map(bulk_spaces, fn {name, slug_suffix, count} ->
    space = ensure_space.(name, "#{tag}-#{slug_suffix}", "channel", %{"fixture" => tag})
    participant = ensure_participant.(space.id, "#{name} Bot")

    # Titles are generated so that ALPHABETICAL order differs from insertion
    # order. `Enum.at` on the two vocabularies with different strides walks
    # them out of phase, and the numeric suffix is not zero-padded in a way
    # that matches the insertion counter, so a listing that forgot to sort is
    # visibly wrong rather than accidentally right.
    titles =
      for i <- 1..count do
        noun = Enum.at(nouns, rem(i * 7, length(nouns)))
        qualifier = Enum.at(qualifiers, rem(i * 3, length(qualifiers)))
        "#{String.capitalize(noun)} #{qualifier} #{count - i + 1}"
      end
      |> Enum.uniq()

    canvases =
      Enum.map(titles, fn title ->
        create_canvas.(space.id, participant.id, "#{name} Bot", title, %{})
      end)

    IO.puts("  #{space.slug}: #{length(canvases)} canvases")
    {space, canvases}
  end)

# ── the near-duplicate cluster ──────────────────────────────────────────────

{cluster_name, cluster_slug_suffix} = cluster_space_spec
cluster_space =
  ensure_space.(cluster_name, "#{tag}-#{cluster_slug_suffix}", "channel", %{"fixture" => tag})
cluster_author = ensure_participant.(cluster_space.id, "Priya Raman")
cluster_author_name = "Priya Raman"

cluster_canvas = fn title, parent ->
  extra = if parent, do: %{"cloned_from" => parent.id}, else: %{}
  create_canvas.(cluster_space.id, cluster_author.id, cluster_author_name, title, extra)
end

# Chain: v2 ← "Approval flow", v3 ← v2, "(3)" ← v3. "— final" is deliberately
# NOT a clone: a cluster in which every member is a clone of its predecessor
# would let a lineage renderer that assumes a chain look correct.
approval_flow = cluster_canvas.("Approval flow", nil)
approval_v2 = cluster_canvas.("Approval flow v2", approval_flow)
approval_v3 = cluster_canvas.("Approval flow v3", approval_v2)
approval_3 = cluster_canvas.("Approval flow (3)", approval_v3)
approval_final = cluster_canvas.("Approval flow — final", nil)

# The sixth: its parent is soft-deleted below, so this is the fixture for
# `canvas_parent_titles/1` returning `:deleted`.
retired_original = cluster_canvas.("Approval flow (retired original)", nil)
approval_orphan = cluster_canvas.("Approval flow (orphaned clone)", retired_original)

# ── timestamp spread ────────────────────────────────────────────────────────
#
# One statement for the whole corpus. Runs BEFORE the cluster's explicit
# timestamps so those win. `row_number()` over `id` (UUIDv7, so creation-
# ordered) makes the spread deterministic across runs rather than random.
{:ok, _} =
  Repo.query(
    """
    UPDATE chat_canvases AS c
       SET inserted_at = (now() AT TIME ZONE 'UTC')
                       - (n.rn::int * interval '2 hours 37 minutes'),
           updated_at  = (now() AT TIME ZONE 'UTC')
                       - (n.rn::int * interval '2 hours 37 minutes')
                       + ((n.rn % 9)::int * interval '17 minutes')
      FROM (
            SELECT id, row_number() OVER (ORDER BY id) AS rn
              FROM chat_canvases
             WHERE metadata->>'fixture' = $1
               AND deleted_at IS NULL
           ) AS n
     WHERE c.id = n.id
    """,
    [tag]
  )

# Explicit, spread across minutes / hours / days, as the ticket requires. Set
# with `update_all` rather than a changeset so Ecto's `updated_at` autogenerate
# cannot quietly overwrite the value being seeded.
cluster_stamps = [
  {approval_flow.id, DateTime.add(now, -9 * 86_400, :second)},
  {approval_v2.id, DateTime.add(now, -3 * 86_400, :second)},
  {approval_v3.id, DateTime.add(now, -26 * 3600, :second)},
  {approval_3.id, DateTime.add(now, -4 * 3600, :second)},
  {approval_final.id, DateTime.add(now, -12 * 60, :second)},
  {retired_original.id, DateTime.add(now, -11 * 86_400, :second)},
  {approval_orphan.id, DateTime.add(now, -40 * 60, :second)}
]

for {id, stamp} <- cluster_stamps do
  {1, _} = Repo.update_all(from(c in Canvas, where: c.id == ^id), set: [updated_at: stamp])
end

# Soft-delete the orphan's parent LAST, so the clone was created against a live
# parent exactly as a real clone would have been.
{:ok, _} =
  retired_original
  |> Canvas.delete_changeset(%{deleted_at: now})
  |> Repo.update()

IO.puts(
  "  #{cluster_space.slug}: 7 canvases (5-title cluster + retired original + orphan)"
)

# ── the execution space, its task, its attachments and its meeting ──────────

project =
  Repo.one(
    from(p in Tasks.Project,
      where: is_nil(p.archived_at),
      order_by: [asc: p.inserted_at],
      limit: 1
    )
  ) ||
    raise("no unarchived project in this database — the fixture task and meeting need one")

task_title = "#{tag}: canvas explorer pinned-group fixture"

task =
  case Repo.one(from(t in Tasks.Task, where: t.title == ^task_title, limit: 1)) do
    nil ->
      # No assignee. A task created with an agent assignee is forced into
      # `planning` and DISPATCHED — a fixture must not start the engine.
      {:ok, t} =
        Tasks.create_task(%{
          project_id: project.id,
          title: task_title,
          description:
            "Fixture task for the canvas explorer's pinned task group. Safe to delete.",
          status: "backlog"
        })

      t

    existing ->
      existing
  end

execution_space =
  ensure_space.(
    "Execution: canvas explorer fixture",
    execution_space_slug,
    "execution",
    %{"fixture" => tag, "task_id" => task.id}
  )

execution_participant = ensure_participant.(execution_space.id, "Execution Fixture Bot")

exec_canvases =
  for title <- ["Stage 1 evidence", "Stage 2 evidence", "Stage 3 evidence (superseded)"] do
    create_canvas.(
      execution_space.id,
      execution_participant.id,
      "Execution Fixture Bot",
      title,
      %{}
    )
  end

# Prior runs' attachments point at canvases this run soft-deleted, so they are
# cleared: the fixture promises exactly THREE attachments of which exactly ONE
# is stale, and accumulating a stale row per run would make that count drift.
{cleared_attachments, _} =
  Repo.delete_all(from(a in CanvasAttachment, where: a.task_id == ^task.id))

attacher =
  case Repo.one(from(u in Platform.Accounts.User, order_by: [asc: u.inserted_at], limit: 1)) do
    nil -> %{kind: "agent", id: Ecto.UUID.generate()}
    user -> %{kind: "user", id: user.id}
  end

for canvas <- exec_canvases do
  {:ok, _attachment} =
    CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
      attached_by: attacher,
      note: "Seeded by seed_canvas_explorer_fixture.exs"
    )
end

# One stale attachment: the row survives, the canvas does not. `canvas_id` has
# no FK, which is exactly why this state is reachable in production.
stale_canvas = List.last(exec_canvases)

{:ok, _} =
  stale_canvas
  |> Canvas.delete_changeset(%{deleted_at: now})
  |> Repo.update()

IO.puts(
  "  #{execution_space.slug}: 3 canvases attached to the task, 1 soft-deleted " <>
    "(cleared #{cleared_attachments} attachment row(s) from earlier runs)"
)

# A live meeting in the SAME execution space, so
# `Meetings.get_live_meeting_for_space/1` returns it. Written directly rather
# than through `Meetings.create_meeting/1` because that function mints its own
# backing chat space, and this meeting has to be bound to the execution space.
meeting_slug = "#{tag}-live"

meeting_attrs = %{
  project_id: project.id,
  chat_space_id: execution_space.id,
  slug: meeting_slug,
  name: "Canvas explorer fixture standup",
  status: "live",
  livekit_room_name: "meeting-#{tag}",
  started_at: DateTime.add(now, -18 * 60, :second)
}

meeting =
  case Repo.one(from(m in Meeting, where: m.slug == ^meeting_slug, limit: 1)) do
    nil ->
      {:ok, m} = %Meeting{} |> Meeting.changeset(meeting_attrs) |> Repo.insert()
      m

    existing ->
      # `Meeting.status_changeset/3` validates transitions and would reject
      # `ended -> live`; a fixture is allowed to reset its own row, so this goes
      # through the plain changeset.
      {:ok, m} = existing |> Meeting.changeset(meeting_attrs) |> Repo.update()
      m
  end

# ── verify through the READ PATHS, not the rows written ─────────────────────
#
# A fixture that wrote rows nobody's query can see is worse than no fixture:
# the stage that consumes it fails on a missing selector and the failure reads
# as a product defect.

all_spaces =
  Enum.map(bulk_results, fn {space, _} -> space end) ++ [cluster_space, execution_space]

space_ids = Enum.map(all_spaces, & &1.id)

groups = Chat.list_canvas_groups(space_ids, limit: 20)

if length(groups) != length(all_spaces) do
  raise """
  list_canvas_groups/2 returned #{length(groups)} groups for #{length(all_spaces)} spaces.
  """
end

paging_group =
  Enum.max_by(groups, & &1.total_count)

unless paging_group.total_count >= 40 do
  raise """
  No group holds 40+ live canvases — the paging subject is missing, and every
  downstream claim about a header count exceeding the rows shown is unfalsifiable.
  Largest group was #{paging_group.space_name} at #{paging_group.total_count}.
  """
end

unless length(paging_group.rows) == 20 do
  raise """
  The paging group returned #{length(paging_group.rows)} rows at limit: 20 — the
  per-space cap is not being applied.
  """
end

if Enum.any?(groups, fn g -> Enum.any?(g.rows, &Map.has_key?(&1, :document)) end) do
  raise "explorer rows carry a :document key — the listing is loading node trees"
end

small_groups = Enum.filter(groups, &(&1.total_count > 0 and &1.total_count < 5))

if length(small_groups) < 3 do
  raise """
  Only #{length(small_groups)} group(s) hold fewer than 5 canvases. The uneven
  distribution is the fixture's point; an even one lets a global cap pass as a
  per-space cap.
  """
end

parents = Chat.canvas_parent_titles([approval_v2.cloned_from, approval_orphan.cloned_from])

unless parents[approval_v2.cloned_from] == "Approval flow" do
  raise "clone chain broken: v2's parent resolved to #{inspect(parents[approval_v2.cloned_from])}"
end

unless parents[approval_orphan.cloned_from] == :deleted do
  raise """
  The orphan clone's soft-deleted parent resolved to
  #{inspect(parents[approval_orphan.cloned_from])} rather than `:deleted`, so the
  "cloned from a deleted canvas" branch has no fixture after all.
  """
end

resolved_space = ExecutionSpace.find_by_task_id(task.id)

unless resolved_space && resolved_space.id == execution_space.id do
  raise """
  ExecutionSpace.find_by_task_id/1 resolved #{inspect(resolved_space && resolved_space.slug)}
  rather than #{execution_space.slug}. The pinned task group reads the space's
  metadata["task_id"], and this is the write path for it.
  """
end

unless resolved_space.metadata["task_id"] == task.id do
  raise "execution space metadata[\"task_id\"] is #{inspect(resolved_space.metadata["task_id"])}"
end

live_meeting = Meetings.get_live_meeting_for_space(execution_space.id)

unless live_meeting && live_meeting.id == meeting.id do
  raise """
  Meetings.get_live_meeting_for_space/1 returned #{inspect(live_meeting && live_meeting.slug)}
  for the execution space. Without a live meeting the pinned meeting group is
  conditional, and a screenshot of its absence proves nothing.
  """
end

attachment_count =
  Repo.aggregate(from(a in CanvasAttachment, where: a.task_id == ^task.id), :count)

stale_count =
  Repo.one(
    from(a in CanvasAttachment,
      join: c in Canvas,
      on: c.id == a.canvas_id,
      where: a.task_id == ^task.id and not is_nil(c.deleted_at),
      select: count(a.id)
    )
  )

unless attachment_count == 3 and stale_count == 1 do
  raise """
  Expected 3 task canvas attachments with exactly 1 pointing at a soft-deleted
  canvas; found #{attachment_count} attachment(s), #{stale_count} stale.
  """
end

live_total =
  Repo.aggregate(
    from(c in Canvas,
      where: fragment("?->>'fixture' = ?", c.metadata, ^tag) and is_nil(c.deleted_at)
    ),
    :count
  )

# ── report ──────────────────────────────────────────────────────────────────

IO.puts("")
IO.puts("verified: #{length(groups)} groups, largest #{paging_group.total_count} canvases")
IO.puts("verified: clone chain resolves, orphan parent resolves to :deleted")
IO.puts("verified: find_by_task_id/1 and get_live_meeting_for_space/1 both resolve")
IO.puts("verified: 3 task canvas attachments, 1 stale")
IO.puts("")

for group <- Enum.sort_by(groups, & &1.total_count, :desc) do
  IO.puts("  #{String.pad_trailing(group.space_name, 36)} #{group.total_count}")
end

IO.puts("")
IO.puts("LIVE_CANVAS_TOTAL=#{live_total}")
IO.puts("SPACE_COUNT=#{length(all_spaces)}")
IO.puts("SPACE_SLUGS=#{Enum.map_join(all_spaces, ",", & &1.slug)}")
IO.puts("CLUSTER_SPACE_SLUG=#{cluster_space.slug}")
IO.puts("EXECUTION_SPACE_SLUG=#{execution_space.slug}")
IO.puts("TASK_ID=#{task.id}")
IO.puts("MEETING_SLUG=#{meeting.slug}")
