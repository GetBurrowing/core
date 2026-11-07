defmodule Platform.Secretary.SchedulerTest do
  @moduledoc """
  Arrivals and debounce (task 01a1b721 stage 3): five arrivals in one
  window are one batch; a post in an open channel the person is not in is
  no arrival for them; a secretary-marked message is no arrival; the
  message handler survives bad input; `Inbox.emit/1` works with the
  scheduler down.

  Mutants these name: dispatch per arrival (M16) -> "five arrivals in the
  window are one batch" goes red; count non-member channel posts as
  arrivals (M17) -> "a non-member open-channel post" goes red.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, only: [add_user!: 2, channel!: 1]
  import Platform.SecretaryFixtures

  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Inbox
  alias Platform.Secretary
  alias Platform.Secretary.Scheduler

  @event [:platform, :chat, :message_posted]
  @debounce 150

  defp start!(opts \\ []) do
    payload = SecretaryPolicy.control()

    start_supervised!(
      {Scheduler,
       Keyword.merge(
         [
           debounce_ms: @debounce,
           max_in_flight: 2,
           pass_opts: [
             eligible: eligible(),
             request: request(self()),
             payload: payload,
             install_payload: payload
           ]
         ],
         opts
       )}
    )
  end

  defp posted!(message) do
    :telemetry.execute(@event, %{system_time: System.system_time()}, %{
      space_id: message.space_id,
      message_id: message.id,
      participant_id: message.participant_id
    })
  end

  test "five arrivals in the window are one batch" do
    user = person!()
    inbox_item!(user)
    start!()

    for _ <- 1..5, do: Secretary.note_arrival(user.id)

    uid = user.id
    assert_receive {:oneshot_called, ^uid, _}, 2_000
    refute_receive {:oneshot_called, ^uid, _}, @debounce * 4
  end

  test "an arrival during a batch opens one more window after it" do
    user = person!()
    inbox_item!(user)
    test_pid = self()

    slow = fn prompt ->
      send(test_pid, {:started, self()})
      receive do: (:go -> :ok)
      {:ok, text} = Platform.AgentHost.FakeHost.oneshot_answer(prompt)
      {:ok, %{text: text, usage: %{}, model_version: "host:test:claude_code"}}
    end

    payload = SecretaryPolicy.control()

    start!(
      pass_opts: [eligible: eligible(), request: request(self(), slow), payload: payload, install_payload: payload]
    )

    uid = user.id
    Secretary.note_arrival(uid)
    assert_receive {:started, pid}, 2_000
    Secretary.note_arrival(uid)
    Secretary.note_arrival(uid)
    send(pid, :go)
    assert_receive {:started, pid2}, 2_000
    send(pid2, :go)
    assert_receive {:oneshot_called, ^uid, _}
    assert_receive {:oneshot_called, ^uid, _}
    refute_receive {:started, _}, @debounce * 3
  end

  test "a non-member open-channel post is no arrival; a member's is" do
    poster = person!("poster")
    member = person!("member")
    outsider = person!("outsider")
    for u <- [member, outsider], do: inbox_item!(u)

    open = channel!(%{})
    add_user!(open.id, member.id)
    start!()

    posted!(say!(open, poster, "news for the channel"))

    mid = member.id
    oid = outsider.id
    assert_receive {:oneshot_called, ^mid, _}, 2_000
    refute_receive {:oneshot_called, ^oid, _}, @debounce * 3
    assert Scheduler.recipients(say!(open, poster, "again").id) == [member.id]
  end

  test "a secretary-marked message is no arrival; an unmarked one in the same DM is" do
    author = person!("author")
    reader = person!("reader")
    inbox_item!(reader)
    dm = space!("dm", nil)
    add_user!(dm.id, reader.id)
    start!()

    marked = say!(dm, author, "I held it for you", metadata: %{Scheduler.nudge_marker() => true})
    assert Scheduler.recipients(marked.id) == []
    posted!(marked)

    rid = reader.id
    refute_receive {:oneshot_called, ^rid, _}, @debounce * 3

    posted!(say!(dm, author, "a real message"))
    assert_receive {:oneshot_called, ^rid, _}, 2_000
  end

  test "the message handler survives bad input and stays attached" do
    pid = start!()

    # Called directly: executing the event with bad metadata would also hit
    # (and detach) every other VM-wide handler on it.
    for metadata <- [
          %{space_id: 1, message_id: "not-a-uuid"},
          %{},
          %{message_id: Ecto.UUID.generate()},
          :not_a_map
        ] do
      assert Scheduler.handle_message_posted(@event, %{}, metadata, nil) == :ok
    end
    _ = :sys.get_state(pid)

    assert Process.alive?(pid)
    assert Enum.any?(:telemetry.list_handlers(@event), &(&1.id == "platform-secretary-arrivals"))
  end

  test "Inbox.emit succeeds with the scheduler down" do
    user = person!()
    refute Process.whereis(Scheduler)

    assert {:ok, _item} =
             Inbox.emit(%{
               user_id: user.id,
               kind: "briefing",
               source_type: "briefing",
               source_id: Ecto.UUID.generate(),
               title: "Morning",
               body: "the briefing"
             })
  end
end
