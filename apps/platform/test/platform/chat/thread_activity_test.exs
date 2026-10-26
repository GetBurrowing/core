defmodule Platform.Chat.ThreadActivityTest do
  @moduledoc """
  The per-thread read cursor and the thread-activity rule (task 01a174f5
  stage 1): `Chat.mark_thread_read/3`, `Chat.thread_activity_for/2` and
  `Chat.thread_activity_entry/2`.

  Every exclusion is paired with an inclusion from the same fixture, so a
  query that returned nothing could not pass. Each named mutation in the
  stage spec (M-own, M-dup, M-order, M-monotonic, M-removed, M-baseline) has
  a test below that fails under it.
  """

  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures,
    only: [external_world: 0, channel!: 0, create_user!: 0, post!: 3]

  alias Platform.Chat
  alias Platform.Chat.{ExternalScope, Message, Participant, ThreadRead}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  defp hour_ago, do: DateTime.add(DateTime.utc_now(), -3600, :second)

  defp member!(space_id, label, attrs \\ %{}) do
    {:ok, p} =
      Chat.add_participant(
        space_id,
        Map.merge(
          %{
            participant_type: "user",
            participant_id: create_user!().id,
            display_name: label,
            joined_at: hour_ago()
          },
          attrs
        )
      )

    p
  end

  defp world do
    space = channel!()
    viewer = member!(space.id, "Viewer")
    second = member!(space.id, "Second")
    %{space: space, viewer: viewer, second: second}
  end

  defp thread!(space_id, participant_id, content \\ "parent") do
    parent = post!(space_id, participant_id, content)
    {:ok, thread} = Chat.create_thread_for_message(space_id, parent.id)
    {parent, thread}
  end

  defp reply!(thread, participant_id, content \\ "reply") do
    {:ok, msg} = Chat.reply_to_thread(thread.id, participant_id, %{content: content})
    msg
  end

  defp delete!(message) do
    message |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
  end

  # A UUIDv7 in the given wall-clock millisecond, for replies "from the past".
  defp uuid_at(%DateTime{} = at) do
    ms = DateTime.to_unix(at, :millisecond)
    rand = :crypto.strong_rand_bytes(10)
    <<ra::12, _::4, rb::62, _::2>> = rand
    Ecto.UUID.load!(<<ms::48, 7::4, ra::12, 2::2, rb::62>>)
  end

  defp insert_reply!(thread, participant_id, attrs) do
    Repo.insert!(
      struct(
        %Message{
          space_id: thread.space_id,
          thread_id: thread.id,
          participant_id: participant_id,
          content_type: "text",
          content: "reply"
        },
        attrs
      )
    )
  end

  defp cursor(participant, thread) do
    Repo.one(
      from(tr in ThreadRead,
        where: tr.participant_id == ^participant.id and tr.thread_id == ^thread.id,
        select: tr.last_read_message_id
      )
    )
  end

  describe "thread_activity_for/2" do
    # M-own
    test "your own replies never create an entry; someone else's do" do
      %{viewer: viewer, second: second, space: space} = world()
      {_parent, thread} = thread!(space.id, second.id)
      reply!(thread, viewer.id)
      reply!(thread, viewer.id)

      assert Chat.thread_activity_for(viewer) == []

      # Control: the same thread with one reply from someone else.
      reply!(thread, second.id)
      assert [%{thread_id: id, new_count: 1}] = Chat.thread_activity_for(viewer)
      assert id == thread.id
    end

    # M-dup
    test "two replies in one thread are one entry with new_count 2" do
      %{viewer: viewer, second: second, space: space} = world()
      {parent, thread} = thread!(space.id, viewer.id)
      _r1 = reply!(thread, second.id)
      r2 = reply!(thread, second.id)

      assert [entry] = Chat.thread_activity_for(viewer)
      assert entry.thread_id == thread.id
      assert entry.parent_message_id == parent.id
      assert entry.new_count == 2
      assert entry.latest_reply_id == r2.id
      assert entry.latest_participant_id == second.id
    end

    # M-order
    test "ordered by latest unseen reply, newest last: T1, T2, T1 gives [T2, T1]" do
      %{viewer: viewer, second: second, space: space} = world()
      {_p1, t1} = thread!(space.id, viewer.id, "first parent")
      {_p2, t2} = thread!(space.id, viewer.id, "second parent")
      reply!(t1, second.id)
      reply!(t2, second.id)
      reply!(t1, second.id)

      assert [a, b] = Chat.thread_activity_for(viewer)
      assert [a.thread_id, b.thread_id] == [t2.id, t1.id]
      assert b.new_count == 2
    end

    # M-baseline
    test "replies from before the viewer joined do not count; later ones do" do
      space = channel!()
      second = member!(space.id, "Second")
      joined_at = hour_ago()
      viewer = member!(space.id, "Viewer", %{joined_at: joined_at})
      {_parent, thread} = thread!(space.id, second.id)

      before_join = DateTime.add(joined_at, -600, :second)
      insert_reply!(thread, second.id, id: uuid_at(before_join), inserted_at: before_join)
      insert_reply!(thread, second.id, id: uuid_at(before_join), inserted_at: before_join)

      assert Chat.thread_activity_for(viewer) == []

      reply!(thread, second.id)
      assert [%{new_count: 1}] = Chat.thread_activity_for(viewer)
    end

    test "a deleted reply does not count, and a deleted parent drops the thread" do
      %{viewer: viewer, second: second, space: space} = world()
      {parent, thread} = thread!(space.id, viewer.id)
      {_kept_parent, kept} = thread!(space.id, viewer.id, "kept parent")
      reply!(thread, second.id)
      gone = reply!(thread, second.id)
      reply!(kept, second.id)
      delete!(gone)

      assert [%{thread_id: t1, new_count: 1}, %{thread_id: t2}] =
               Chat.thread_activity_for(viewer)

      assert [t1, t2] == [thread.id, kept.id]

      delete!(Repo.get!(Message, parent.id))
      assert [%{thread_id: only}] = Chat.thread_activity_for(viewer)
      assert only == kept.id
    end

    test "history_visible_from bounds what counts" do
      space = channel!()
      second = member!(space.id, "Second")
      visible_from = DateTime.add(DateTime.utc_now(), -60, :second)
      viewer = member!(space.id, "Viewer", %{history_visible_from: visible_from})
      {_parent, thread} = thread!(space.id, second.id)

      # Ids are fresh, so only the history bound can exclude this one.
      insert_reply!(thread, second.id, inserted_at: DateTime.add(visible_from, -30, :second))
      assert Chat.thread_activity_for(viewer) == []

      insert_reply!(thread, second.id, inserted_at: DateTime.utc_now())
      assert [%{new_count: 1}] = Chat.thread_activity_for(viewer)
    end

    test "only the viewer's own space" do
      %{viewer: viewer, second: second, space: space} = world()
      other = channel!()
      other_second = member!(other.id, "Second")
      {_p, elsewhere} = thread!(other.id, other_second.id)
      reply!(elsewhere, other_second.id)

      assert Chat.thread_activity_for(viewer) == []

      {_p, here} = thread!(space.id, viewer.id)
      reply!(here, second.id)
      assert [%{thread_id: id}] = Chat.thread_activity_for(viewer)
      assert id == here.id
    end

    test "an external scope sees activity only in spaces it belongs to" do
      w = external_world()
      {_pa, ta} = thread!(w.a.id, w.p_a_int.id)
      {_pb, tb} = thread!(w.b.id, w.p_b.id)
      reply!(ta, w.p_a_int.id)
      second_b = member!(w.b.id, "Second")
      reply!(tb, second_b.id)
      scope = ExternalScope.for_user(w.ext)

      viewer_a = Repo.get!(Participant, w.p_a_ext.id)
      assert [%{thread_id: id}] = Chat.thread_activity_for(viewer_a, scope: scope)
      assert id == ta.id

      viewer_b = Repo.get!(Participant, w.p_b.id)
      assert Chat.thread_activity_for(viewer_b, scope: scope) == []
      # Positive control: unscoped, b's thread is active for its member.
      assert [%{thread_id: tb_id}] = Chat.thread_activity_for(viewer_b)
      assert tb_id == tb.id
    end
  end

  describe "mark_thread_read/3" do
    # M-removed
    test "marking the latest reply removes the entry; the next reply brings it back at 1" do
      %{viewer: viewer, second: second, space: space} = world()
      {_parent, thread} = thread!(space.id, viewer.id)
      reply!(thread, second.id)
      latest = reply!(thread, second.id)
      assert [%{new_count: 2}] = Chat.thread_activity_for(viewer)

      assert :ok = Chat.mark_thread_read(viewer.id, thread.id, latest.id)
      assert Chat.thread_activity_for(viewer) == []
      assert Chat.thread_activity_entry(viewer, thread.id) == nil

      reply!(thread, second.id)
      assert [%{thread_id: id, new_count: 1}] = Chat.thread_activity_for(viewer)
      assert id == thread.id
      assert %{new_count: 1} = Chat.thread_activity_entry(viewer, thread.id)
    end

    # M-monotonic
    test "only advances: marking an older id after a newer one keeps the newer" do
      %{viewer: viewer, second: second, space: space} = world()
      {_parent, thread} = thread!(space.id, viewer.id)
      older = reply!(thread, second.id)
      newer = reply!(thread, second.id)

      assert :ok = Chat.mark_thread_read(viewer.id, thread.id, newer.id)
      assert :ok = Chat.mark_thread_read(viewer.id, thread.id, older.id)
      assert cursor(viewer, thread) == newer.id
      assert Chat.thread_activity_for(viewer) == []
    end

    test "broadcasts on the participant's own topic only, and only when it advanced" do
      %{viewer: viewer, second: second, space: space} = world()
      {_parent, thread} = thread!(space.id, viewer.id)
      older = reply!(thread, second.id)
      newer = reply!(thread, second.id)

      :ok = ChatPubSub.subscribe_thread_reads(viewer.id)
      :ok = ChatPubSub.subscribe(space.id)

      Chat.mark_thread_read(second.id, thread.id, newer.id)
      refute_receive {:thread_read, _}, 50

      Chat.mark_thread_read(viewer.id, thread.id, newer.id)
      assert_receive {:thread_read, payload}

      assert payload == %{
               participant_id: viewer.id,
               thread_id: thread.id,
               last_read_message_id: newer.id
             }

      # The no-op write (older id) broadcasts nothing.
      Chat.mark_thread_read(viewer.id, thread.id, older.id)
      refute_receive {:thread_read, _}, 50
    end

    test "rejects ids that are not UUIDs" do
      assert {:error, :invalid_id} =
               Chat.mark_thread_read("nope", Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "thread_activity_entry/2" do
    test "the single-thread rule, nil for an inactive thread" do
      %{viewer: viewer, second: second, space: space} = world()
      {parent, active} = thread!(space.id, viewer.id)
      {_p, quiet} = thread!(space.id, viewer.id, "quiet parent")
      reply!(active, second.id)
      reply!(quiet, viewer.id)

      assert %{thread_id: id, parent_message_id: pid, new_count: 1} =
               Chat.thread_activity_entry(viewer, active.id)

      assert {id, pid} == {active.id, parent.id}
      assert Chat.thread_activity_entry(viewer, quiet.id) == nil
      assert Chat.thread_activity_entry(viewer, "not-a-uuid") == nil
    end
  end
end
