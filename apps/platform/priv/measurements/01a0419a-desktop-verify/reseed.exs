import Ecto.Query
space = "01a04589-8bcc-7e56-bc8f-bdb40dfaa230"
sbin = Ecto.UUID.dump!(space)
Platform.Repo.delete_all(from m in "chat_messages", where: m.space_id == ^sbin)
part = Ecto.UUID.dump!("01a04589-becc-78da-98e2-1a7f59317acf")
other = Ecto.UUID.dump!("01a045c8-c6b1-7261-b20b-ebebf7e0cbed")
short = ["render farm finished overnight, frames 400-900 are clean",
  "any drift on the shadow pass?", "slight, only where the volumetrics overlap",
  "I can reshoot those twelve this afternoon", "sounds good", "shipping it",
  "the cache invalidation is the tricky part here", "agreed"]
long1 = "The colour pipeline is doing something odd on the second pass. When the volumetrics overlap the shadow catcher the compositor picks the wrong alpha and we get a halo around the moving geometry. I traced it back to the exr channel ordering, which changed when we bumped the renderer."
long2 = "Longer note so the seeded conversation has a realistic mix of one-liners and multi-paragraph bodies, matching the fixture the DEEP_HISTORY_PX tuning note describes: median row 83px, mean 84px, tallest 132px. Without tall rows the scroller never accumulates enough height."
now = DateTime.utc_now() |> DateTime.truncate(:second)
# Ids must sort in the SAME order as inserted_at: list_messages/2 orders by
# inserted_at but cursors with `m.id < ^before_id`. Generating in a tight loop
# gives many ids the same UUIDv7 millisecond, so the random tail decides the
# order and the cursor dead-ends mid-history. Sorting the generated set and
# assigning it in time order makes the two orders agree by construction.
ids = 1..240 |> Enum.map(fn _ -> Ecto.UUID.dump!(Platform.Types.UUIDv7.generate()) end) |> Enum.sort()
rows =
  for {i, mid} <- Enum.zip(1..240, ids) do
    body =
      cond do
        rem(i, 7) == 0 -> long1
        rem(i, 5) == 0 -> long2
        true -> Enum.at(short, rem(i, 8))
      end
    %{id: mid, space_id: sbin,
      participant_id: (if rem(i, 3) == 0, do: other, else: part),
      author_display_name: (if rem(i, 3) == 0, do: "Ori Tanaka", else: "Dev User"),
      author_participant_type: "user", content: "#{i}. #{body}", content_type: "text",
      log_only: false, metadata: %{}, structured_content: %{},
      inserted_at: DateTime.add(now, -(240 - i) * 60, :second)}
  end
{n, _} = Platform.Repo.insert_all("chat_messages", rows)
ids = Platform.Repo.all(from m in "chat_messages", where: m.space_id == ^sbin, order_by: [asc: m.inserted_at], select: m.id)
%{inserted: n, id_order_matches_time_order: ids == Enum.sort(ids)}
