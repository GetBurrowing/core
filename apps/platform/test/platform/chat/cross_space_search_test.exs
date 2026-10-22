defmodule Platform.Chat.CrossSpaceSearchTest do
  @moduledoc """
  `Platform.Chat.search_messages_in_spaces/3` and
  `Platform.Chat.last_message_excerpts/2`, the two backend reads the Chat
  conversation list renders (task 01a1557a-8562 stage 1).

  Every absence below is preceded, on the same fixture, by its positive
  control: the row exists and a read that is allowed to see it does.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp unique_slug, do: "xspace-#{System.unique_integer([:positive])}"

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Ada",
      joined_at: DateTime.utc_now()
    }

    {:ok, p} = Chat.add_participant(space_id, Map.merge(default, attrs))
    p
  end

  defp post!(space_id, participant_id, content, attrs \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space_id,
            participant_id: participant_id,
            content_type: "text",
            content: content
          },
          attrs
        )
      )

    msg
  end

  # Message ids are UUIDv7 and the newest-message query orders by id, so two
  # posts in the same millisecond would have no defined order between them.
  defp tick!, do: Process.sleep(2)

  defp reply!(space_id, parent, content) do
    {:ok, thread} = Chat.create_thread_for_message(space_id, parent.id)
    post!(space_id, parent.participant_id, content, %{thread_id: thread.id})
  end

  defp seated_space do
    space = create_space()
    {space, create_participant(space.id)}
  end

  # ── search_messages_in_spaces/3 ─────────────────────────────────────────────

  describe "search_messages_in_spaces/3" do
    test "returns ranked hits from several spaces, with headline and space_id" do
      {a, pa} = seated_space()
      {b, pb} = seated_space()

      strong = post!(a.id, pa.id, "Orchard orchard planning for the orchard")
      weak = post!(b.id, pb.id, "One orchard note")
      _miss = post!(b.id, pb.id, "Nothing relevant here")

      hits = Chat.search_messages_in_spaces([a.id, b.id], "orchard")

      assert Enum.map(hits, & &1.id) == [strong.id, weak.id]
      assert Enum.map(hits, & &1.space_id) == [a.id, b.id]
      assert Enum.all?(hits, &(is_float(&1.search_rank) and &1.search_rank > 0.0))
      assert hd(hits).search_headline =~ "<mark>"
      assert hd(hits).author_display_name == "Ada"
    end

    test "a space not in space_ids is never returned, even when it holds the term" do
      {a, pa} = seated_space()
      {outside, po} = seated_space()

      inside = post!(a.id, pa.id, "lighthouse keeper")
      elsewhere = post!(outside.id, po.id, "lighthouse beam")

      # Positive control: the outside message is searchable when named.
      assert [%{id: eid}] = Chat.search_messages_in_spaces([outside.id], "lighthouse")
      assert eid == elsewhere.id

      assert [%{id: iid}] = Chat.search_messages_in_spaces([a.id], "lighthouse")
      assert iid == inside.id
    end

    test "a deleted message is not returned" do
      {a, pa} = seated_space()
      kept = post!(a.id, pa.id, "glacier survey kept")
      gone = post!(a.id, pa.id, "glacier survey gone")

      # Positive control: both match before the delete.
      assert length(Chat.search_messages_in_spaces([a.id], "glacier")) == 2

      {:ok, _} = Chat.delete_message(gone)

      assert [%{id: id}] = Chat.search_messages_in_spaces([a.id], "glacier")
      assert id == kept.id
    end

    test "empty space ids, a blank query and a punctuation-only query return []" do
      {a, pa} = seated_space()
      _ = post!(a.id, pa.id, "anything at all")

      assert Chat.search_messages_in_spaces([], "anything") == []
      assert Chat.search_messages_in_spaces([a.id], "") == []
      assert Chat.search_messages_in_spaces([a.id], "   ") == []
      assert Chat.search_messages_in_spaces([a.id], "--- ??? !!!") == []
      assert Chat.search_messages_in_spaces([a.id], nil) == []
    end

    test "the limit holds and defaults to 20" do
      {a, pa} = seated_space()
      for n <- 1..22, do: post!(a.id, pa.id, "meadow entry #{n}")

      assert length(Chat.search_messages_in_spaces([a.id], "meadow", limit: 3)) == 3
      assert length(Chat.search_messages_in_spaces([a.id], "meadow")) == 20
    end

    test "a thread reply is returned, carrying its space_id and thread_id" do
      {a, pa} = seated_space()
      parent = post!(a.id, pa.id, "parent message")
      reply = reply!(a.id, parent, "canyon reply inside a thread")

      assert [hit] = Chat.search_messages_in_spaces([a.id], "canyon")
      assert hit.id == reply.id
      assert hit.space_id == a.id
      assert hit.thread_id == reply.thread_id
      refute is_nil(hit.thread_id)
    end
  end

  # ── last_message_excerpts/2 ─────────────────────────────────────────────────

  describe "last_message_excerpts/2" do
    test "the newest top-level message wins over an older one, per space" do
      {a, pa} = seated_space()
      {b, pb} = seated_space()

      _old = post!(a.id, pa.id, "older in a")
      tick!()
      newest_a = post!(a.id, pa.id, "newer in a")
      tick!()
      newest_b = post!(b.id, pb.id, "only in b")

      excerpts = Chat.last_message_excerpts([a.id, b.id])

      assert %{content: "newer in a", author_name: "Ada", inserted_at: at} = excerpts[a.id]
      assert at == newest_a.inserted_at
      assert %DateTime{} = at
      assert excerpts[b.id].content == "only in b"
      assert excerpts[b.id].inserted_at == newest_b.inserted_at
    end

    test "a newer thread reply does NOT replace the top-level headline" do
      {a, pa} = seated_space()
      parent = post!(a.id, pa.id, "the channel headline")
      tick!()
      reply = reply!(a.id, parent, "a reply buried in the thread")

      # Positive control: the reply really is the newest row in the space.
      assert reply.id > parent.id

      assert Chat.last_message_excerpts([a.id])[a.id].content == "the channel headline"
    end

    test "a deleted newest message falls back to the previous one" do
      {a, pa} = seated_space()
      _ = post!(a.id, pa.id, "the survivor")
      tick!()
      newest = post!(a.id, pa.id, "about to be deleted")

      # Positive control: before the delete, the newest one is the headline.
      assert Chat.last_message_excerpts([a.id])[a.id].content == "about to be deleted"

      {:ok, _} = Chat.delete_message(newest)

      assert Chat.last_message_excerpts([a.id])[a.id].content == "the survivor"
    end

    test "a space with no messages is absent, and [] gives %{}" do
      {a, pa} = seated_space()
      {empty, _} = seated_space()
      _ = post!(a.id, pa.id, "present")

      excerpts = Chat.last_message_excerpts([a.id, empty.id])

      assert Map.has_key?(excerpts, a.id)
      refute Map.has_key?(excerpts, empty.id)
      assert Chat.last_message_excerpts([]) == %{}
    end

    test "content collapses whitespace and is truncated to 140 graphemes" do
      {a, pa} = seated_space()
      _ = post!(a.id, pa.id, "first line\n\n  second\tline  ")

      assert Chat.last_message_excerpts([a.id])[a.id].content == "first line second line"

      {b, pb} = seated_space()
      # Multi-codepoint graphemes, so a byte or codepoint slice would differ.
      long = String.duplicate("é", 100) <> String.duplicate("x", 100)
      _ = post!(b.id, pb.id, long)

      content = Chat.last_message_excerpts([b.id])[b.id].content
      assert String.length(content) == 140
      assert content == String.slice(long, 0, 140)
    end
  end
end
