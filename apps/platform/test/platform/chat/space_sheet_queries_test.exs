defmodule Platform.Chat.SpaceSheetQueriesTest do
  @moduledoc """
  The reads behind the phone space sheet's pages (task 01a1557a-8a6d):
  `Chat.list_pins_with_messages/2` and `Chat.list_thread_summaries/2`
  (stage 2), and `Chat.list_space_attachments/2` and `Chat.list_space_links/2`
  (stage 4).

  Every exclusion is shown beside an inclusion from the same fixture, so a
  query that returned nothing could not pass.
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures,
    only: [external_world: 0, channel!: 0, create_user!: 0, post!: 3]

  alias Platform.Chat
  alias Platform.Chat.{ExternalScope, Message, Pin}
  alias Platform.Repo

  defp pin!(space_id, message_id, at) do
    Repo.insert!(%Pin{space_id: space_id, message_id: message_id, inserted_at: at})
  end

  defp delete!(message) do
    message |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
  end

  defp reply!(space_id, thread_id, participant_id, content, at) do
    Repo.insert!(%Message{
      space_id: space_id,
      thread_id: thread_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      inserted_at: at
    })
  end

  defp at(seconds), do: DateTime.add(~U[2026-10-01 12:00:00.000000Z], seconds)

  defp world do
    space = channel!()
    user = create_user!()

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Pin Author #{System.unique_integer([:positive])}",
        joined_at: DateTime.utc_now()
      })

    %{space: space, p: p}
  end

  describe "list_pins_with_messages/2" do
    test "joins each pin to its message, newest pin first, with the author" do
      %{space: space, p: p} = world()
      older = post!(space.id, p.id, "first pinned line")
      newer = post!(space.id, p.id, "second pinned line")
      pin!(space.id, older.id, at(0))
      pin!(space.id, newer.id, at(60))

      assert [first, second] = Chat.list_pins_with_messages(space.id)
      assert first.message_id == newer.id
      assert first.content == "second pinned line"
      assert is_binary(first.author)
      assert first.author == p.display_name
      assert second.message_id == older.id
    end

    test "leaves out a pin whose message is deleted" do
      %{space: space, p: p} = world()
      kept = post!(space.id, p.id, "still here")
      gone = post!(space.id, p.id, "deleted later")
      pin!(space.id, kept.id, at(0))
      pin!(space.id, gone.id, at(10))
      delete!(gone)

      assert [%{message_id: id}] = Chat.list_pins_with_messages(space.id)
      assert id == kept.id
    end

    test "only the asked-for space's pins" do
      %{space: space, p: p} = world()
      %{space: other, p: q} = world()
      mine = post!(space.id, p.id, "mine")
      theirs = post!(other.id, q.id, "theirs")
      pin!(space.id, mine.id, at(0))
      pin!(other.id, theirs.id, at(0))

      assert [%{message_id: id}] = Chat.list_pins_with_messages(space.id)
      assert id == mine.id
    end

    test "an external scope sees pins only in spaces it belongs to" do
      w = external_world()
      in_a = post!(w.a.id, w.p_a_int.id, "in a")
      in_b = post!(w.b.id, w.p_b.id, "in b")
      pin!(w.a.id, in_a.id, at(0))
      pin!(w.b.id, in_b.id, at(0))
      scope = ExternalScope.for_user(w.ext)

      assert [%{message_id: id}] = Chat.list_pins_with_messages(w.a.id, scope: scope)
      assert id == in_a.id
      assert Chat.list_pins_with_messages(w.b.id, scope: scope) == []
      # Positive control: unscoped, b's pin is there.
      assert [%{message_id: b_id}] = Chat.list_pins_with_messages(w.b.id)
      assert b_id == in_b.id
    end
  end

  describe "list_thread_summaries/2" do
    test "lists threads with replies, latest reply first, counting live replies only" do
      %{space: space, p: p} = world()
      early = post!(space.id, p.id, "early parent")
      late = post!(space.id, p.id, "late parent")
      quiet = post!(space.id, p.id, "no replies here")
      {:ok, t_early} = Chat.create_thread(space.id, %{parent_message_id: early.id})
      {:ok, t_late} = Chat.create_thread(space.id, %{parent_message_id: late.id})
      {:ok, _t_quiet} = Chat.create_thread(space.id, %{parent_message_id: quiet.id})

      reply!(space.id, t_early.id, p.id, "e1", at(0))
      reply!(space.id, t_early.id, p.id, "e2", at(10))
      reply!(space.id, t_early.id, p.id, "e3 deleted", at(20)) |> delete!()
      reply!(space.id, t_late.id, p.id, "l1", at(100))

      assert [first, second] = Chat.list_thread_summaries(space.id)
      assert first.thread_id == t_late.id
      assert first.parent_message_id == late.id
      assert first.excerpt == "late parent"
      assert first.author == p.display_name
      assert first.reply_count == 1

      assert second.thread_id == t_early.id
      assert second.reply_count == 2
      assert second.last_reply_at == at(10)
    end

    test "a thread whose only replies are deleted is left out" do
      %{space: space, p: p} = world()
      parent = post!(space.id, p.id, "parent")
      live = post!(space.id, p.id, "live parent")
      {:ok, t} = Chat.create_thread(space.id, %{parent_message_id: parent.id})
      {:ok, t_live} = Chat.create_thread(space.id, %{parent_message_id: live.id})
      reply!(space.id, t.id, p.id, "gone", at(0)) |> delete!()
      reply!(space.id, t_live.id, p.id, "here", at(0))

      assert [%{thread_id: id}] = Chat.list_thread_summaries(space.id)
      assert id == t_live.id
    end

    test "a deleted parent keeps the thread but shows no text" do
      %{space: space, p: p} = world()
      parent = post!(space.id, p.id, "secret parent text")
      {:ok, t} = Chat.create_thread(space.id, %{parent_message_id: parent.id})
      reply!(space.id, t.id, p.id, "reply", at(0))
      delete!(parent)

      assert [%{thread_id: id, excerpt: nil, author: nil}] = Chat.list_thread_summaries(space.id)
      assert id == t.id
    end

    test "only the asked-for space, and an external scope sees only its spaces" do
      w = external_world()
      pa = post!(w.a.id, w.p_a_int.id, "a parent")
      pb = post!(w.b.id, w.p_b.id, "b parent")
      {:ok, ta} = Chat.create_thread(w.a.id, %{parent_message_id: pa.id})
      {:ok, tb} = Chat.create_thread(w.b.id, %{parent_message_id: pb.id})
      reply!(w.a.id, ta.id, w.p_a_int.id, "a reply", at(0))
      reply!(w.b.id, tb.id, w.p_b.id, "b reply", at(0))
      scope = ExternalScope.for_user(w.ext)

      assert [%{thread_id: id}] = Chat.list_thread_summaries(w.a.id, scope: scope)
      assert id == ta.id
      assert Chat.list_thread_summaries(w.b.id, scope: scope) == []
      # Positive control: unscoped, b's thread is there.
      assert [%{thread_id: tb_id}] = Chat.list_thread_summaries(w.b.id)
      assert tb_id == tb.id
    end
  end

  # ── stage 4 ───────────────────────────────────────────────────────────

  defp attach!(space_id, message_id, filename, extra \\ %{}) do
    {:ok, att} =
      Chat.create_attachment(
        Map.merge(
          %{
            space_id: space_id,
            message_id: message_id,
            filename: filename,
            content_type: "application/pdf",
            byte_size: 10,
            storage_key: "sheet-q-#{System.unique_integer([:positive])}"
          },
          extra
        )
      )

    att
  end

  describe "list_space_attachments/2" do
    test "ready attachments on live messages in this space, newest first" do
      %{space: space, p: p} = world()
      %{space: other, p: q} = world()
      m1 = post!(space.id, p.id, "first file")
      m2 = post!(space.id, p.id, "second file")
      gone = post!(space.id, p.id, "deleted later")
      older = attach!(space.id, m1.id, "older.pdf")
      newer = attach!(space.id, m2.id, "newer.mp4", %{content_type: "video/mp4"})
      _pending = attach!(space.id, m2.id, "pending.pdf", %{state: "pending"})
      _on_deleted = attach!(space.id, gone.id, "on-deleted.pdf")
      delete!(gone)
      _elsewhere = attach!(other.id, post!(other.id, q.id, "x").id, "elsewhere.pdf")

      older |> Ecto.Changeset.change(inserted_at: at(0)) |> Repo.update!()
      newer |> Ecto.Changeset.change(inserted_at: at(60)) |> Repo.update!()

      assert [first, second] = Chat.list_space_attachments(space.id)
      assert first.id == newer.id
      assert first.content_type == "video/mp4"
      assert first.author == p.display_name
      assert second.id == older.id
    end

    test "an external scope sees attachments only in spaces it belongs to" do
      w = external_world()
      in_a = attach!(w.a.id, post!(w.a.id, w.p_a_int.id, "a").id, "a.pdf")
      in_b = attach!(w.b.id, post!(w.b.id, w.p_b.id, "b").id, "b.pdf")
      scope = ExternalScope.for_user(w.ext)

      assert [%{id: a_id}] = Chat.list_space_attachments(w.a.id, scope: scope)
      assert a_id == in_a.id
      assert Chat.list_space_attachments(w.b.id, scope: scope) == []
      assert [%{id: b_id}] = Chat.list_space_attachments(w.b.id)
      assert b_id == in_b.id
    end
  end

  describe "list_space_links/2" do
    test "extracts http(s) links, dedupes keeping the newest, classifies video hosts" do
      %{space: space, p: p} = world()

      old =
        reply_like!(space.id, p.id, "first mention https://example.org/guide and more", at(0))

      _ = reply_like!(space.id, p.id, "watch https://youtu.be/abc123 later", at(10))
      newest = reply_like!(space.id, p.id, "again: https://example.org/guide", at(20))
      _ = reply_like!(space.id, p.id, "docs at [the docs](https://docs.example.com/a)", at(30))

      links = Chat.list_space_links(space.id)
      urls = Enum.map(links, & &1.url)

      assert urls == [
               "https://docs.example.com/a",
               "https://example.org/guide",
               "https://youtu.be/abc123"
             ]

      guide = Enum.find(links, &(&1.url == "https://example.org/guide"))
      assert guide.message_id == newest.id
      refute guide.message_id == old.id
      assert guide.host == "example.org"
      assert guide.kind == :site
      assert guide.author == p.display_name

      assert Enum.find(links, &(&1.url == "https://youtu.be/abc123")).kind == :video
      assert Enum.find(links, &(&1.url == "https://docs.example.com/a")).kind == :site
    end

    test "video hosts include subdomains; lookalike hosts do not" do
      %{space: space, p: p} = world()
      _ = reply_like!(space.id, p.id, "https://www.youtube.com/watch?v=x1", at(0))
      _ = reply_like!(space.id, p.id, "https://player.vimeo.com/video/1", at(1))
      _ = reply_like!(space.id, p.id, "https://www.loom.com/share/abc", at(2))
      _ = reply_like!(space.id, p.id, "https://notyoutube.com/watch", at(3))

      kinds = Map.new(Chat.list_space_links(space.id), &{&1.host, &1.kind})

      assert kinds == %{
               "www.youtube.com" => :video,
               "player.vimeo.com" => :video,
               "www.loom.com" => :video,
               "notyoutube.com" => :site
             }
    end

    test "ignores deleted messages and other spaces" do
      %{space: space, p: p} = world()
      %{space: other, p: q} = world()
      _ = reply_like!(space.id, p.id, "kept https://example.org/kept", at(0))
      gone = reply_like!(space.id, p.id, "gone https://example.org/gone", at(1))
      delete!(gone)
      _ = reply_like!(other.id, q.id, "other https://example.org/other", at(2))

      assert Enum.map(Chat.list_space_links(space.id), & &1.url) == ["https://example.org/kept"]
    end

    test "reads only the 300 most recent messages" do
      %{space: space, p: p} = world()
      _ = reply_like!(space.id, p.id, "oldest https://example.org/outside", at(0))

      for i <- 1..300, do: reply_like!(space.id, p.id, "filler #{i}", at(i))
      assert Chat.list_space_links(space.id) == []

      # Positive control: one more recent link IS found.
      _ = reply_like!(space.id, p.id, "newest https://example.org/inside", at(1000))
      assert Enum.map(Chat.list_space_links(space.id), & &1.url) == ["https://example.org/inside"]
    end

    test "an external scope sees links only in spaces it belongs to" do
      w = external_world()
      _ = reply_like!(w.a.id, w.p_a_int.id, "https://example.org/in-a", at(0))
      _ = reply_like!(w.b.id, w.p_b.id, "https://example.org/in-b", at(0))
      scope = ExternalScope.for_user(w.ext)

      assert Enum.map(Chat.list_space_links(w.a.id, scope: scope), & &1.url) ==
               ["https://example.org/in-a"]

      assert Chat.list_space_links(w.b.id, scope: scope) == []
      assert Enum.map(Chat.list_space_links(w.b.id), & &1.url) == ["https://example.org/in-b"]
    end

    # The architect's condition: the Links list and the timeline agree on
    # what is a link. The SAME text goes through the timeline's renderer
    # (read independently here, with LazyHTML) and through list_space_links;
    # both must yield the same URL set, including the cases a hand-written
    # regex gets wrong (trailing punctuation, code spans, markdown links,
    # escaped ampersands, a non-http scheme).
    test "agrees with the message renderer on the URL set" do
      %{space: space, p: p} = world()

      text = """
      See https://example.org/a. Also (https://example.com/paren) and
      [named](https://example.com/named?x=1&y=2), not `https://example.com/code`,
      not mailto:someone@example.com, and <https://example.org/angle>.
      ftp://example.org/file stays plain.
      """

      _ = reply_like!(space.id, p.id, text, at(0))

      rendered =
        text
        |> Platform.Chat.ContentRenderer.render_message()
        |> Phoenix.HTML.safe_to_string()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[href]")
        |> LazyHTML.attribute("href")
        |> Enum.filter(&String.match?(&1, ~r{\Ahttps?://}))
        |> MapSet.new()

      listed = space.id |> Chat.list_space_links() |> MapSet.new(& &1.url)

      # Anti-vacuity: the renderer really did link several of these.
      assert MapSet.size(rendered) >= 3
      assert listed == rendered
      refute MapSet.member?(listed, "https://example.com/code")
    end
  end

  # A top-level message with a fixed inserted_at (ordering is by time).
  defp reply_like!(space_id, participant_id, content, inserted_at) do
    Repo.insert!(%Message{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      inserted_at: inserted_at
    })
  end
end
