defmodule Platform.Meetings.PushToTalkTargetTest do
  @moduledoc """
  Agent attachment end to end: a spoken name inside a press window
  attaches that agent; an unnamed utterance inside a window takes the
  configured default; the same words outside a window do neither
  (task 01a03f4e stage 4).

  ## The fixture holds THREE agents, all attachable, all different

    * `default_agent` — assigned to `meeting_default_target`
    * `named_agent`   — the one actually spoken
    * `role_agent`    — assigned to `designer`, the role the stubbed
      classifier always returns

  That separation is what makes the assertions discriminating. "The
  named agent attached" is only meaningful if a DIFFERENT agent would
  have attached otherwise, and "the name outside a window does not
  attach" is only meaningful if something else non-nil attaches instead
  — otherwise it is a comparison of nil against nil and every
  implementation passes it.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressCard
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.SpokenTarget
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"

  setup do
    meeting_id = Ecto.UUID.generate()
    room_id = Ecto.UUID.generate()
    identity = "user:#{Ecto.UUID.generate()}"

    classifier_agent = create_agent!("classifier")
    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    default_agent = create_agent!("aaa-default")
    named_agent = create_agent!("zzz-named")
    role_agent = create_agent!("mmm-role")

    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", role_agent.id)
    :ok = Roles.clear_override(SpokenTarget.default_responsibility_key())

    on_exit(fn ->
      IntentQueue.stop(meeting_id)
      PressWindow.clear_meeting(meeting_id)
    end)

    %{
      meeting_id: meeting_id,
      room_id: room_id,
      identity: identity,
      default_agent: default_agent,
      named_agent: named_agent,
      role_agent: role_agent
    }
  end

  defp assign_default!(agent) do
    :ok = Roles.clear_override(SpokenTarget.default_responsibility_key())
    {:ok, _} = Roles.set_override(SpokenTarget.default_responsibility_key(), agent.id)
    :ok
  end

  # ── Inside a window ──────────────────────────────────────────────────────

  test "a spoken name inside a window attaches THAT agent, not the default and not the role",
       ctx do
    %{meeting_id: m, room_id: r, identity: i} = ctx
    assign_default!(ctx.default_agent)

    {pid, _} = start_classifier!()
    plant_ok_stub(pid)

    {:ok, _} = PressCard.open(m, i, speaker: "alice", room_id: r)

    :ok = MeetingsPubSub.subscribe_intents(m)
    chunk(m, r, i, "#{ctx.named_agent.slug} rotate the staging secrets")
    assert_receive {:intent_classified, _}, 2_000

    row = classified_row(m)

    # A real, seeded id — never nil, which is this field's default and
    # would prove nothing.
    assert row.target_agent_id == ctx.named_agent.id
    assert row.target_agent_slug == ctx.named_agent.slug

    # And all three would have been legal answers, so this is the name
    # winning rather than the only candidate being returned.
    refute row.target_agent_id == ctx.default_agent.id
    refute row.target_agent_id == ctx.role_agent.id
  end

  test "an unnamed utterance inside a window attaches the CONFIGURED default", ctx do
    %{meeting_id: m, room_id: r, identity: i} = ctx
    assign_default!(ctx.default_agent)

    {pid, _} = start_classifier!()
    plant_ok_stub(pid)

    {:ok, _} = PressCard.open(m, i, speaker: "alice", room_id: r)

    :ok = MeetingsPubSub.subscribe_intents(m)
    chunk(m, r, i, "rotate the staging secrets before friday")
    assert_receive {:intent_classified, _}, 2_000

    row = classified_row(m)

    assert row.target_agent_id == ctx.default_agent.id

    # NOT the role agent: holding the key means the operator's default
    # decides, not whichever role the model guessed. The stub always
    # answers `designer`, and `designer` is assigned, so a fallback
    # chain that let the role win would show up right here.
    refute row.target_agent_id == ctx.role_agent.id
  end

  # ── Outside a window ─────────────────────────────────────────────────────

  test "the SAME name spoken outside a window does not attach that agent", ctx do
    %{meeting_id: m, room_id: r, identity: i} = ctx
    assign_default!(ctx.default_agent)

    {pid, _} = start_classifier!()
    plant_ok_stub(pid)

    # No press. No window.
    assert PressWindow.list(m) == []

    :ok = MeetingsPubSub.subscribe_intents(m)
    chunk(m, r, i, "#{ctx.named_agent.slug} rotate the staging secrets")
    assert_receive {:intent_classified, _}, 2_000

    row = classified_row(m)

    # Attribution went down the ORDINARY path — the role the classifier
    # inferred — so the assertion below is "a different agent attached",
    # not "nothing attached". A nil-vs-nil comparison here would pass
    # against an implementation that had simply stopped working.
    assert row.source == nil
    assert row.target_agent_id == ctx.role_agent.id

    refute row.target_agent_id == ctx.named_agent.id
    refute row.target_agent_id == ctx.default_agent.id
  end

  # ── No assignment: loud, not quiet ───────────────────────────────────────

  test "with no default-target override the press card fails LOUDLY", ctx do
    %{meeting_id: m, identity: i} = ctx

    assert Roles.assignee_for(SpokenTarget.default_responsibility_key()) == nil

    {result, log} =
      with_log(fn -> PressCard.open(m, i, speaker: "alice", room_id: ctx.room_id) end)

    assert {:ok, _} = result

    # LOUD: a log line naming the role key that is not assigned. The
    # absence of an agent id below is NOT the assertion — a no-op
    # implementation produces that too. The log line is what only a
    # code path that looked and failed can produce.
    assert log =~ "no agent is assigned to responsibility"
    assert log =~ SpokenTarget.default_responsibility_key()

    assert [row] = IntentQueue.list(m)
    assert row.target_agent_id == nil

    # Reachability: with an assignment, the same call DOES attach, so
    # the failure above is the missing assignment.
    PressWindow.clear_meeting(m)
    IntentQueue.stop(m)
    assign_default!(ctx.default_agent)

    assert {:ok, _} = PressCard.open(m, i, speaker: "alice", room_id: ctx.room_id)
    assert [retry] = IntentQueue.list(m)
    assert retry.target_agent_id == ctx.default_agent.id
  end

  test "with no assignment an unnamed in-window utterance fails LOUDLY too", ctx do
    %{meeting_id: m, room_id: r, identity: i} = ctx

    {pid, _} = start_classifier!()
    plant_ok_stub(pid)

    {:ok, _} = PressCard.open(m, i, speaker: "alice", room_id: r)
    :ok = MeetingsPubSub.subscribe_intents(m)

    log =
      capture_log(fn ->
        chunk(m, r, i, "rotate the staging secrets before friday")
        assert_receive {:intent_classified, _}, 2_000
      end)

    assert log =~ "push-to-talk utterance has no target"
    assert log =~ SpokenTarget.default_responsibility_key()

    row = classified_row(m)
    assert row.target_agent_id == nil

    # And emphatically NOT the role agent — failing loudly must not
    # quietly fall through to the ordinary routing either.
    refute row.target_agent_id == ctx.role_agent.id
  end

  # ── The press card carries its destination before a word is said ─────────

  test "the press card is stamped with the default at press time", ctx do
    %{meeting_id: m, identity: i} = ctx
    assign_default!(ctx.default_agent)

    assert {:ok, _} = PressCard.open(m, i, speaker: "alice", room_id: ctx.room_id)

    assert [row] = IntentQueue.list(m)
    assert row.target_agent_id == ctx.default_agent.id
    assert row.target_agent_slug == ctx.default_agent.slug
  end

  # ── Per-agent hold-to-talk: the PRESSED agent is authoritative ───────────

  test "a PRESSED agent wins over a spoken name AND the configured default", ctx do
    %{meeting_id: m, room_id: r, identity: i} = ctx
    assign_default!(ctx.default_agent)

    {pid, _} = start_classifier!()
    plant_ok_stub(pid)

    # The human held `named_agent`'s row.
    {:ok, _} =
      PressCard.open(m, i, speaker: "alice", room_id: r, target_agent_id: ctx.named_agent.id)

    :ok = MeetingsPubSub.subscribe_intents(m)
    # …but then said a DIFFERENT agent's name inside the window. The
    # press decides, not the words: pressing is the address.
    chunk(m, r, i, "#{ctx.role_agent.slug} rotate the staging secrets")
    assert_receive {:intent_classified, _}, 2_000

    row = classified_row(m)

    # The agent that was PRESSED, through classification.
    assert row.target_agent_id == ctx.named_agent.id
    assert row.target_agent_slug == ctx.named_agent.slug

    # And all three rivals would otherwise have been legal answers — the
    # spoken name (`role_agent`), the configured default, the inferred
    # role — so this is the press winning, not the only candidate.
    refute row.target_agent_id == ctx.role_agent.id
    refute row.target_agent_id == ctx.default_agent.id
  end

  test "the press card is stamped with the PRESSED agent at press time, over the default",
       ctx do
    %{meeting_id: m, identity: i} = ctx
    assign_default!(ctx.default_agent)

    assert {:ok, _} =
             PressCard.open(m, i,
               speaker: "alice",
               room_id: ctx.room_id,
               target_agent_id: ctx.named_agent.id
             )

    assert [row] = IntentQueue.list(m)
    # The pressed agent, from the instant the key goes down — NOT the
    # configured default, which is what an untargeted press would take.
    assert row.target_agent_id == ctx.named_agent.id
    assert row.target_agent_slug == ctx.named_agent.slug
    refute row.target_agent_id == ctx.default_agent.id

    # And the window carries it too, so it survives to classification.
    assert %{target_agent_id: agent_id, target_agent_slug: slug} = PressWindow.get(m, i)
    assert agent_id == ctx.named_agent.id
    assert slug == ctx.named_agent.slug
  end

  test "an unknown pressed agent id is refused and falls back to the default", ctx do
    %{meeting_id: m, identity: i} = ctx
    assign_default!(ctx.default_agent)

    # A well-formed but unassigned/absent id — a crafted phx-value- or a
    # departed agent — must not byline the card to a stranger.
    assert {:ok, _} =
             PressCard.open(m, i,
               speaker: "alice",
               room_id: ctx.room_id,
               target_agent_id: Ecto.UUID.generate()
             )

    assert [row] = IntentQueue.list(m)
    assert row.target_agent_id == ctx.default_agent.id
    assert %{target_agent_id: nil} = PressWindow.get(m, i)
  end

  test "a MALFORMED pressed id falls back to the default and does NOT raise", ctx do
    %{meeting_id: m, identity: i} = ctx
    assign_default!(ctx.default_agent)

    # The pressed id comes off the `push_to_talk_press` payload, which is
    # user-controlled. A non-UUID string must be treated exactly like an
    # absent agent — `Repo.get(Agent, "not-a-uuid")` would otherwise RAISE
    # `Ecto.Query.CastError` from inside `PressCard.open/3` on key-down.
    # The well-formed-but-absent test above never exercises this path.
    assert {:ok, _} =
             PressCard.open(m, i,
               speaker: "alice",
               room_id: ctx.room_id,
               target_agent_id: "not-a-uuid"
             )

    assert [row] = IntentQueue.list(m)
    assert row.target_agent_id == ctx.default_agent.id
    assert %{target_agent_id: nil} = PressWindow.get(m, i)
  end

  # ── Harness ──────────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # The row the CLASSIFIER wrote — the one carrying a classification.
  # The press placeholder is also in the queue and picking it by
  # position would make these assertions depend on insertion order.
  defp classified_row(meeting_id) do
    meeting_id
    |> IntentQueue.list()
    |> Enum.find(&(&1.classified_intent != nil))
    |> case do
      nil -> flunk("no classified row in the queue for #{meeting_id}")
      row -> row
    end
  end

  defp start_classifier! do
    name = :"ptt_target_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({IntentClassifier, provider_module: StubProvider, name: name})
    {pid, name}
  end

  defp plant_ok_stub(pid) do
    ref = make_ref()

    fun = fn _creds, messages, _opts ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => "visual_adjust",
             "target_role" => "designer",
             "confidence" => 0.91,
             "evidence_quote" => echo_quote(messages)
           })
       }}
    end

    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      case message do
        %{role: "user", content: content} when is_binary(content) -> content
        %{"role" => "user", "content" => content} when is_binary(content) -> content
        _ -> nil
      end
    end)
  end

  defp chunk(meeting_id, room_id, identity, text) do
    :ok =
      MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
        room_id: room_id,
        transcript_id: Ecto.UUID.generate(),
        meeting_id: meeting_id,
        segment: %{
          id: Ecto.UUID.generate(),
          text: text,
          participant_identity: identity,
          speaker_name: "alice"
        }
      })
  end

  defp create_agent!(prefix) do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "#{prefix}-#{n}", name: "Agent #{n}", status: "active"})
    |> Repo.insert!()
  end
end
