# Reseed for task 01a05873 ("desktop chat does not autoscroll to the latest
# message") — a dedicated channel whose fixture is wide enough to make BOTH
# the follow measurement and any width-rewrap measurable at 1440x900, with
# rows whose heights differ between pane widths (long multi-paragraph prose
# mixed with one-liners), spread across several calendar days so day labels
# render.
#
# Run inside the app container against the dev database:
#   mix run priv/measurements/01a05873-desktop-follow/reseed.exs
#
# ID DISCIPLINE (the cursor dead-end defect, recorded in
# ../01a0419a-desktop-verify/README.md): `chat_messages.id` is UUIDv7 and
# `Chat.list_messages/2` orders by `inserted_at` but paginates with
# `where: m.id < ^before_id`. Generating ids in a tight loop leaves the sort
# to the random tail, which dead-ends the cursor mid-history. We generate,
# SORT, then assign in `inserted_at` order so the two orders agree by
# construction, and assert it before returning.
#
# This script pins ITS OWN ids (space id is the task UUIDv7, message ids are
# generated here) — it does not reuse any sibling fixture's UUIDs. The two
# users are resolved (not pinned) so `/dev/login?as=reader` / `?as=sender`
# land on the same rows admission would create for them.
import Ecto.Query

space_id = "01a05873-c623-7001-97d3-e81a22073650"
sbin = Ecto.UUID.dump!(space_id)

alias Platform.{Repo, Accounts, Chat}

# Wipe and (re)create the space. Idempotent on every run so a re-seed never
# needs a fresh database. Wipes by BOTH the pinned id and the slug — the
# first ever run of this script crashed after the space insert (message-row
# zip bug, fixed) and left an orphan row holding the slug, which the
# id-only wipe then tripped over.
old_space_ids =
  Repo.all(
    from(s in "chat_spaces", where: s.slug == "follow-probe" or s.id == ^sbin, select: s.id)
  )

for sid <- old_space_ids do
  Repo.delete_all(from(p in "chat_participants", where: p.space_id == ^sid))
  Repo.delete_all(from(m in "chat_messages", where: m.space_id == ^sid))
  # Explicit (the FKs would cascade anyway): chat_canvases.space_id ->
  # chat_spaces is on_delete: :delete_all, and canvas_versions -> chat_canvases
  # likewise, but the wipe is clearer if the canvas rows go with the space by
  # name. Keeps the reseed idempotent — a re-run never orphans a canvas row
  # holding the old space id.
  Repo.delete_all(from(c in "chat_canvases", where: c.space_id == ^sid))
  Repo.delete_all(from(s in "chat_spaces", where: s.id == ^sid))
end

# The struct carries the pinned id (changesets do not cast `:id`), so the
# fixture's space UUID is stable across reseeds: the task UUIDv7 itself.
{:ok, space} =
  %Chat.Space{id: space_id}
  |> Chat.Space.changeset(%{
    name: "Follow Probe",
    slug: "follow-probe",
    kind: "channel"
  })
  |> Repo.insert!()
  |> then(&{:ok, &1})

users =
  for {sub, email, name} <- [
        {"dev-reader", "reader@localhost", "Dev Reader"},
        {"dev-sender", "sender@localhost", "Dev Sender"}
      ] do
    {:ok, user} = Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: name})

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    user
  end

{reader_user, sender_user} = List.to_tuple(users)

# `chat_messages.participant_id` is an FK to the chat_participants ROW id,
# not the user id — post as the per-space participant rows.
part_row = fn user ->
  Repo.one!(
    from(p in Chat.Participant,
      where: p.space_id == ^space.id and p.participant_id == ^user.id
    )
  )
end

reader = part_row.(reader_user)
sender = part_row.(sender_user)

# The canvases drawer toggle only renders when the space has at least one
# non-deleted canvas (`partials/conversation.ex`, header controls:
# `:if={@canvases != []}` on the `canvas_panel_toggle` button; the drawer
# itself is `canvases_drawer`, gated on `@show_canvases`). Without a
# `chat_canvases` row the toggle never renders, which blocked the drawer half
# of the gate-5 spec. Insert one; `Chat.Canvas.changeset/2` turns the empty
# document into a canonical `CanvasDocument.new()` (validate_document/1), and
# `Chat.list_canvases/2` filters `deleted_at IS NULL`, which this row leaves.
# `created_by` is the chat_participants ROW id (FK), same as message rows.
{:ok, _canvas} =
  %Chat.Canvas{}
  |> Chat.Canvas.changeset(%{
    space_id: space.id,
    created_by: reader.id,
    title: "Gate 5 probe canvas",
    document: %{},
    metadata: %{},
    created_by_display_name: reader_user.name,
    created_by_participant_type: "user"
  })
  |> Repo.insert()

long_1 =
  "This is a deliberately long paragraph of ordinary chat prose, written so it wraps onto many lines in the chat pane at every desktop width we measure, which means a width change — a squeezed sidebar mid-patch, a window resize, a rail drag — measurably changes the rendered height of the row. The words do not matter; the dense line-break opportunities do, because the rewrap delta between a wide pane and a narrow one has to be real rather than zero for the scroll measurements in this task to mean anything at all."

long_2 =
  "A second long body, again with plenty of text so the row is tall at every width. When the pane narrows this paragraph gains lines; when it widens it loses them. The fixture alternates tall bodies like this one with one-liners so the scroller's total height and the per-row deltas are realistic rather than uniform, which matters because the follow rule and the viewport observer both measure distances against a scrollHeight built from these rows."

short = [
  "shipping it",
  "sounds good",
  "the cache invalidation is the tricky part here",
  "any drift on the shadow pass?",
  "I can reshoot those twelve this afternoon"
]

bodies =
  for i <- 1..200 do
    cond do
      rem(i, 7) == 0 -> long_1
      rem(i, 5) == 0 -> long_2
      true -> Enum.at(short, rem(i, 5))
    end
  end

now = DateTime.utc_now() |> DateTime.truncate(:second)

# Sorted UUIDv7 ids assigned in time order — see the header.
ids =
  1..200
  |> Enum.map(fn _ -> Ecto.UUID.dump!(Platform.Types.UUIDv7.generate()) end)
  |> Enum.sort()

rows =
  for {{body, i}, mid} <- Enum.zip(Enum.with_index(bodies, 1), ids) do
    mine? = rem(i, 3) == 0
    part = if mine?, do: sender, else: reader

    %{
      id: mid,
      space_id: sbin,
      participant_id: Ecto.UUID.dump!(part.id),
      author_display_name: if(mine?, do: "Dev Sender", else: "Dev Reader"),
      author_participant_type: "user",
      content: "#{i}. #{body}",
      content_type: "text",
      log_only: false,
      metadata: %{},
      structured_content: %{},
      # ~45min apart → 200 rows span ~6 days, so day labels render.
      inserted_at: DateTime.add(now, -(200 - i) * 45 * 60, :second)
    }
  end

{n, _} = Repo.insert_all("chat_messages", rows)

ids_in_time_order =
  Repo.all(
    from(m in "chat_messages", where: m.space_id == ^sbin, order_by: [asc: m.inserted_at], select: m.id)
  )

%{
  inserted: n,
  id_order_matches_time_order: ids_in_time_order == Enum.sort(ids_in_time_order),
  space_id: space.id,
  slug: space.slug,
  canvases: Repo.aggregate(from(c in "chat_canvases", where: c.space_id == ^sbin), :count),
  reader: reader_user.email,
  sender: sender_user.email
}
|> IO.inspect()
