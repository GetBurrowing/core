defmodule Platform.Sharing.UsageEventsTest do
  @moduledoc """
  Task 01a1b678 stage 2: anonymous usage counts.

    * the pin: `UsageEvents.events/0` equals a literal list written here, so
      adding an event without updating this file (and the docs) goes red;
    * the scrubber: a sentinel name and email injected into a batch never
      reach the broker stub, and a body carrying them is refused;
    * the off switch: no request reaches the stub;
    * the positive control: with the switch on, the stub records one
      `/usage` request whose counts came from real `:telemetry` emits.

  async: false: the collector table and its flag are VM-wide, and the batcher
  runs in its own process (shared sandbox, `Req.Test.allow/3`).
  """
  use Platform.DataCase, async: false

  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Meetings
  alias Platform.Sharing
  alias Platform.Sharing.UsageBatcher
  alias Platform.Sharing.UsageEvents

  @sentinel_name "Sentinel Personname"
  @sentinel_email "sentinel@example.test"

  @pinned [
    "message.posted",
    "message.edited",
    "message.deleted",
    "thread.created",
    "reaction.added",
    "pin.added",
    "canvas.created",
    "space.created",
    "meeting.started",
    "meeting.transcription_failed",
    "access.blocked"
  ]

  setup do
    test_pid = self()

    Req.Test.stub(Broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:broker_request, conn.method, conn.request_path, raw})
      Req.Test.json(Plug.Conn.put_status(conn, 202), %{"accepted" => 1})
    end)

    pid = start_supervised!({UsageBatcher, interval_ms: :manual})
    Req.Test.allow(Broker, test_pid, pid)
    # handle_continue has run once this call returns.
    :sys.get_state(pid)
    :ok
  end

  defp switch(on?) do
    {:ok, _} = Sharing.set(:usage_counts, on?, :system)
    :ok
  end

  # The collector's own handler, called as `:telemetry` calls it. Firing the
  # real event with made-up metadata would reach every OTHER handler on it
  # (ContextPlane, AttentionRouter) and a raise there detaches them VM-wide
  # for the rest of the run. The real emit path is covered by the meeting
  # test below, which goes through `Meetings.start_meeting/2`.
  defp emit(event), do: UsageEvents.handle_event(event, %{system_time: 0}, %{}, nil)

  defp emit_pinned(name) do
    {^name, event} = Enum.find(UsageEvents.telemetry_events(), &(elem(&1, 0) == name))
    emit(event)
  end

  describe "the pinned list" do
    test "is exactly the documented list, in order" do
      assert UsageEvents.events() == @pinned
    end

    test "every pinned name maps to exactly one telemetry event, and names are unique" do
      events = UsageEvents.telemetry_events()
      assert Enum.map(events, &elem(&1, 0)) == @pinned
      assert length(Enum.uniq_by(events, &elem(&1, 1))) == length(events)
    end

    test "is written verbatim in the decision note's 'Exactly what is sent'" do
      note =
        File.read!(
          Path.expand(
            "../../../../../docs/decisions/0060-sharing-with-burrow-on-by-default-for-new-installs.md",
            __DIR__
          )
        )

      [_, section] = String.split(note, "## Exactly what is sent", parts: 2)
      for name <- @pinned, do: assert(section =~ "`#{name}`", "#{name} missing from the note")
    end
  end

  describe "positive control: switch on" do
    test "collected events are counted and one /usage request reaches the stub" do
      switch(true)

      emit_pinned("message.posted")
      emit_pinned("message.posted")
      emit_pinned("reaction.added")
      # Not pinned: never counted.
      emit([:platform, :chat, :participant_added])

      assert {:sent, _body} = UsageBatcher.flush()

      assert_receive {:broker_request, "POST", "/usage", raw}
      body = Jason.decode!(raw)

      assert Map.keys(body) |> Enum.sort() == ["counts", "sharing_install_id", "window"]
      assert body["sharing_install_id"] == to_string(Sharing.get().sharing_install_id)
      assert body["counts"] == %{"message.posted" => 2, "reaction.added" => 1}
      assert %{"start" => start, "seconds" => seconds} = body["window"]
      assert is_integer(start) and is_integer(seconds) and seconds >= 0

      # What was sent is subtracted; a second flush has nothing to send.
      assert UsageEvents.pending() == %{}
      assert UsageBatcher.flush() == :empty
      refute_receive {:broker_request, _, _, _}
    end

    test "starting a meeting emits the interaction event the count reads" do
      switch(true)

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Usage Counts #{System.unique_integer([:positive])}",
          org_id: Platform.TenancyFixtures.acme_org_id()
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Standup #{System.unique_integer([:positive])}"
        })

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert UsageEvents.pending()["meeting.started"] == 1
    end

    test "a failed POST keeps the counts for the next flush" do
      switch(true)

      Req.Test.stub(Broker, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      emit_pinned("pin.added")
      assert {:error, :publisher_unavailable} = UsageBatcher.flush()
      assert UsageEvents.pending() == %{"pin.added" => 1}
    end
  end

  describe "off switch" do
    test "nothing is counted and no request reaches the stub" do
      switch(false)

      emit_pinned("message.posted")
      emit_pinned("meeting.started")

      assert UsageEvents.pending() == %{}
      assert UsageBatcher.flush() == :off
      refute_receive {:broker_request, _, _, _}
    end

    test "turning the switch off drops what was pending; nothing is sent" do
      switch(true)
      emit_pinned("thread.created")
      assert UsageEvents.pending() == %{"thread.created" => 1}

      switch(false)
      assert UsageEvents.pending() == %{}
      assert UsageBatcher.flush() == :off
      refute_receive {:broker_request, _, _, _}
    end
  end

  describe "scrubber" do
    test "a sentinel name and email injected into a batch never reach the stub" do
      switch(true)
      emit_pinned("canvas.created")

      result =
        UsageBatcher.flush(UsageBatcher,
          inject_counts: %{
            @sentinel_name => 3,
            @sentinel_email => 1,
            "space.created" => @sentinel_email,
            "pin.added" => -4,
            "message.edited" => 2.5
          }
        )

      assert {:sent, _} = result
      assert_receive {:broker_request, "POST", "/usage", raw}
      refute raw =~ "Sentinel"
      refute raw =~ "sentinel"
      refute raw =~ "@"
      assert Jason.decode!(raw)["counts"] == %{"canvas.created" => 1}
    end

    test "scrub_counts keeps only pinned names with non-negative integer values" do
      assert UsageEvents.scrub_counts(%{
               "message.posted" => 4,
               "message.deleted" => 0,
               @sentinel_name => 1,
               "space.created" => @sentinel_email,
               "pin.added" => -1
             }) == %{"message.posted" => 4, "message.deleted" => 0}

      assert UsageEvents.scrub_counts("not a map") == %{}
    end

    test "refusal/1 refuses a body carrying a sentinel anywhere, and passes a clean one" do
      id = Ecto.UUID.generate()
      clean = UsageEvents.build_body(id, DateTime.utc_now(), 60, %{"message.posted" => 1})
      assert UsageEvents.refusal(clean) == nil

      assert UsageEvents.refusal(put_in(clean, ["counts", @sentinel_name], 1)) == :unknown_string
      # Redaction runs first and already matches an email; either way it is refused.
      assert UsageEvents.refusal(Map.put(clean, "who", @sentinel_email)) in [
               :redaction_hit,
               :email_sentinel
             ]

      assert UsageEvents.refusal(Map.put(clean, "sharing_install_id", @sentinel_email)) in [
               :redaction_hit,
               :email_sentinel
             ]

      assert UsageEvents.refusal(Map.put(clean, "note", @sentinel_name)) == :unknown_string

      assert UsageEvents.refusal(Map.put(clean, "token", "ghp_" <> String.duplicate("a1B2", 10))) ==
               :redaction_hit
    end
  end

  describe "the collector never raises" do
    test "returns :ok for any input and stays attached" do
      assert UsageEvents.handle_event(:not_an_event, nil, nil, nil) == :ok
      assert UsageEvents.handle_event([:platform, :chat, :message_posted], nil, nil, nil) == :ok

      handlers = :telemetry.list_handlers([:platform, :chat, :message_posted])
      assert Enum.any?(handlers, &(&1.id == UsageEvents.handler_id()))
    end
  end
end
