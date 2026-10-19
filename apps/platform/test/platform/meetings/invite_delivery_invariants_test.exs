defmodule Platform.Meetings.InviteDeliveryInvariantsTest do
  @moduledoc """
  The four properties task `019fb955-6577-7fb0-8c97-c70d233bba23` is
  accountable for, stated as CLAIMS rather than as incidental consequences
  of some other test's fixture.

  These properties cut across every stage of the task — the typed kind, the
  flag and the seed, the CAS and the internal carrier, the external carrier
  — so no per-carrier suite owns them and, left alone, each would be
  "tested" only by accident. This file is the one place a reader can check
  them off.

  **Every case asserts BOTH sides.** That is the whole discipline here, and
  each case below says what its second side is defending against, because a
  one-sided version of any of them passes against an implementation that is
  wrong in the obvious way.

  ## 1. An invite cannot fail for want of a `meeting_producer`

  The structural reason is that nothing in `Platform.Meetings.InviteDelivery`
  calls `Platform.Roles.assignee_for/1` or `Roles.agent_id_for_role/1` — the
  only occurrence of `Roles.` in that module is the sentence in its moduledoc
  saying so. The sender is resolved by SLUG through
  `Platform.Meetings.SenderSeed`, which is an authorship identity and not an
  assignee, and `Meetings.invite_user/3` calls delivery in-line on its own
  success path with no dispatcher in between.

  A test that merely fails to assign the role proves none of that: a fresh
  test database has an empty `role_assignments` table anyway, so the case
  would pass identically against an implementation that DID consult the
  role and got `nil`. So the fixture here proves the precondition is real
  in three steps — the role KEY exists in the catalogue (a nil answer about
  a misspelled key is vacuous), an assignment can be made and IS seen by the
  resolver, and removing it IS seen too. Only then is `nil` a fact about
  the system rather than about an empty table.

  ## 2. The flag gates SENDING, and nothing else

  Off means silence, not breakage. Both halves matter and they pull in
  opposite directions: a module that crashed when disabled would satisfy
  "nothing was sent" perfectly, and a module that quietly sent anyway would
  satisfy "nothing crashed". So the flag-off cases assert no side effect on
  ANY of the three surfaces (inbox, push, `chat_messages` row count) AND
  that `invite_user/3` still returns `{:ok, %Invite{}}` with the row
  committed. Declaring an invitee is a database fact; delivering to them is
  the part the flag owns.

  ## 3. Seeding is idempotent, PROVEN BY COUNT

  `assert {:ok, _} = SenderSeed.ensure!()` twice passes against a seeder
  that inserts a duplicate every time, which is precisely the bug the
  advisory lock exists to prevent — and it is a live risk rather than a
  theoretical one, because `agents_unique_slug` was measured to have
  `indnullsnotdistinct = false` and so does NOT dedupe rows whose
  `workspace_id` is `NULL`. The database will happily hold two. Only a row
  count can see that, so the count is the assertion.

  ## 4. The audience determines the carrier, exclusively

  This is the first invariant to decay, because both halves look correct in
  isolation: "internal users get an inbox row and a push" and "external
  users get a chat message" are each satisfied by an implementation that
  ALSO does the other thing to both of them. The exclusivity is the claim.
  One meeting, one internal invitee, one external invitee, ONE delivery
  pass, six assertions — three positives and three negatives — so the
  cross-contamination has nowhere to hide.

  An external user's inbox is 403 by
  `PlatformWeb.Plugs.ExternalUserScope.gate_external/2`, so a row there is
  written and unreachable and a push deep-links them into that 403 — a
  notification that looks BROKEN rather than absent, which is worse than
  silence.

  ## Not covered here, deliberately

  There is no cancellation case. `Meeting.@statuses` is
  `~w(scheduled live ended)` and no status transition admits a cancelled
  state, so any such test would be asserting against a model that sibling
  task `019fb954-c848` is adding in its own approved first stage.

  Guest delivery appears in case 4's fixtures only as the carrier atom.
  There is no outbound email capability in this repository, so a guest
  invite's honest outcome is `:guest_link` — see the `InviteDelivery`
  moduledoc.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings
  alias Platform.Meetings.Config
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Meetings.SenderSeed
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tenancy

  defmodule InboxRecorder do
    @moduledoc "Records `Platform.Inbox.emit/1` calls as `{:inbox_emit, attrs}`."
    def install(pid \\ self()), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def emit(attrs) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:inbox_emit, attrs})
      end

      {:ok, attrs}
    end
  end

  defmodule NotifStub do
    @moduledoc """
    Records `Platform.Notifications` fan-outs.

    `fan_out_to_user/2` short-circuits entirely when
    `Application.get_env(:platform, :env) == :test`, so a test observing
    the real module observes nothing and would keep passing against code
    that pushes to nobody. The stub is what makes every push assertion —
    positive AND negative — mean something.
    """
    def install(pid \\ self()), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, opts \\ []),
      do: notify({:push_user, user_id, payload, opts})

    def fan_out_to_humans(ids, payload, opts \\ []),
      do: notify({:push_humans, ids, payload, opts})

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :inbox_module, InboxRecorder)
    Application.put_env(:platform, :notifications_module, NotifStub)
    InboxRecorder.install(self())
    NotifStub.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :inbox_module)
      Application.delete_env(:platform, :notifications_module)
    end)

    :ok
  end

  # `config/test.exs` pins `:meetings_enabled` false for the whole suite,
  # and `Config.enabled?/0` short-circuits the OS env read when the key is
  # set — so this is hermetic regardless of the host's `MEETINGS_ENABLED`.
  defp enable_meetings! do
    prior = Application.fetch_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:platform, :meetings_enabled, value)
        :error -> Application.delete_env(:platform, :meetings_enabled)
      end
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp create_user(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{name: name, email: "inv-#{n}@example.com", oidc_sub: "inv-sub-#{n}"})
    |> Repo.insert!()
  end

  # The meeting's project takes the DEFAULT org, which is deliberately not
  # the external invitee's tenant org — that difference is what makes the
  # internal/external split real rather than staged.
  defp meeting_hosted_by(name, host_name) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project"})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    host = create_user(host_name)

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: host.id,
        joined_at: DateTime.utc_now(),
        display_name: host_name
      })

    meeting =
      meeting
      |> Ecto.Changeset.change(host_participant_id: participant.id)
      |> Repo.update!()

    meeting
  end

  # Written through `Tenancy.mark_membership_external/1` rather than by hand
  # so the fixture cannot drift from the predicate delivery actually reads.
  defp external_user(name) do
    user = create_user(name)

    {:ok, _membership} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: tenant_org_id("globex")})

    assert Tenancy.external_user?(%{id: user.id})
    user
  end

  defp invite_row(meeting, user) do
    %Invite{}
    |> Invite.changeset(%{meeting_id: meeting.id, user_id: user.id})
    |> Repo.insert!()
  end

  defp reload(%Invite{id: id}), do: Repo.get!(Invite, id)

  defp message_count, do: Repo.aggregate(Message, :count)

  # Drain the WHOLE mailbox into a list rather than reaching for the one
  # message a given assertion wants. Case 4 delivers to two audiences in one
  # pass, and a selective `assert_receive` there would happily skip past a
  # wrongly-addressed row to find the one it was looking for. A list can be
  # counted and filtered, so "the internal invitee got a push" and "the
  # external invitee did NOT" are answered from the same evidence.
  defp drain(acc \\ []) do
    receive do
      {:inbox_emit, _} = msg -> drain([msg | acc])
      {:push_user, _, _, _} = msg -> drain([msg | acc])
      {:push_humans, _, _, _} = msg -> drain([msg | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp inbox_emits_for(events, user_id) do
    Enum.filter(events, fn
      {:inbox_emit, %{user_id: ^user_id}} -> true
      _ -> false
    end)
  end

  defp pushes_for(events, user_id) do
    Enum.filter(events, fn
      {:push_user, ^user_id, _payload, _opts} -> true
      _ -> false
    end)
  end

  # ── 1. An invite cannot fail for want of a `meeting_producer` ─────────────

  describe "invariant 1: delivery does not consult the meeting_producer role" do
    setup do
      enable_meetings!()
      :ok
    end

    test "both audiences deliver with the role PROVEN unassigned" do
      # Step one: the key is real. `agent_id_for_role/1` answers nil for any
      # string at all, so asserting nil about a misspelled key would be a
      # test of nothing. `get_role/1` reads the catalogue row.
      assert %Roles.Role{key: "meeting_producer"} = Roles.get_role("meeting_producer")

      # Step two: the resolver DISCRIMINATES. If assigning the role did not
      # move `agent_id_for_role/1` off nil, then the nil in step three would
      # be evidence about a broken resolver rather than about an empty
      # assignment. Any agent will do here — the point is the reading, not
      # the agent.
      {:ok, %Agent{id: agent_id}} = SenderSeed.ensure!()
      {:ok, _assignment} = Roles.assign_role("meeting_producer", agent_id)
      assert Roles.agent_id_for_role("meeting_producer") == agent_id

      # Step three: and now unassigned, observably.
      assert :ok = Roles.unassign_role("meeting_producer")
      assert Roles.agent_id_for_role("meeting_producer") == nil

      meeting = meeting_hosted_by("Producerless", "Ada")
      internal = create_user("Internal Invitee")
      external = external_user("External Invitee")

      # Both audiences, because "cannot fail for want of a role" has to hold
      # for the carrier that posts AS the seeded agent too — that is the
      # branch where a role lookup would be most tempting to write.
      assert InviteDelivery.deliver(invite_row(meeting, internal), meeting) ==
               {:ok, :internal_inbox_push}

      assert InviteDelivery.deliver(invite_row(meeting, external), meeting) ==
               {:ok, :external_chat}

      # And the delivery pass did not quietly appoint anybody to make that
      # work: an implementation that self-assigned the role on demand would
      # pass everything above.
      assert Roles.agent_id_for_role("meeting_producer") == nil
    end
  end

  # ── 2. The flag gates sending, and nothing else ───────────────────────────

  describe "invariant 2: with meetings disabled" do
    # No `enable_meetings!/0` — this describe reads the suite's fail-closed
    # default rather than staging a special state.

    test "nothing sends: no inbox row, no push, and no chat message row" do
      refute Config.enabled?()

      meeting = meeting_hosted_by("Silent", "Ada")
      invite = invite_row(meeting, create_user("Invitee"))

      before_messages = message_count()

      assert InviteDelivery.deliver(invite, meeting) == {:ok, :disabled}

      # The third surface, counted rather than sampled: the external carrier
      # writes a `chat_messages` row, and a recorder cannot see that one.
      assert message_count() == before_messages
      assert drain() == []

      # No row write either, so flipping the flag on later still delivers.
      persisted = reload(invite)
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)
    end

    test "nothing crashes: invite_user/3 still returns {:ok, %Invite{}} and commits" do
      # The other half. A disabled meetings module must still let a host
      # DECLARE an invitee — being invited is a database fact, and only the
      # send is behind the flag. An implementation that raised, or that
      # turned the flag into `{:error, :disabled}`, would satisfy the
      # no-side-effects half above completely.
      refute Config.enabled?()

      meeting = meeting_hosted_by("Declarable", "Ada")
      user = create_user("Invitee")

      before_messages = message_count()

      assert {:ok, %Invite{id: invite_id} = invite} = Meetings.invite_user(meeting, user.id)
      assert invite.user_id == user.id

      # Committed, read back through the repo rather than trusted from the
      # returned struct.
      persisted = Repo.get!(Invite, invite_id)
      assert persisted.meeting_id == meeting.id
      assert persisted.user_id == user.id

      # Declared, but explicitly NOT delivered.
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)
      assert message_count() == before_messages
      assert drain() == []
    end
  end

  # ── 3. Seeding is idempotent, proven by count ─────────────────────────────

  describe "invariant 3: SenderSeed.ensure!/0 idempotency" do
    test "two calls leave exactly one agent row with the meetings slug" do
      slug = SenderSeed.slug()

      {:ok, %Agent{id: first_id}} = SenderSeed.ensure!()
      {:ok, %Agent{id: second_id}} = SenderSeed.ensure!()

      # Necessary but nowhere near sufficient — see the count below.
      assert first_id == second_id

      # THE assertion. `agents_unique_slug` was measured to be a plain
      # UNIQUE index (`indnullsnotdistinct = false`), so it does not
      # constrain two rows whose `workspace_id` is NULL and the database
      # will hold a duplicate without complaint. A seeder that inserted
      # unconditionally would therefore RAISE NOTHING and pass every
      # `{:ok, _}` assertion; the row count is the only thing that sees it.
      assert Repo.aggregate(from(a in Agent, where: a.slug == ^slug), :count) == 1
    end
  end

  # ── 4. The audience determines the carrier, exclusively ───────────────────

  describe "invariant 4: carrier exclusivity" do
    setup do
      enable_meetings!()
      :ok
    end

    test "one pass, two audiences: each gets its carrier and ONLY its carrier" do
      meeting = meeting_hosted_by("Exclusive", "Ada")
      internal = create_user("Internal Invitee")
      external = external_user("External Invitee")

      internal_invite = invite_row(meeting, internal)
      external_invite = invite_row(meeting, external)

      before_messages = message_count()

      assert InviteDelivery.deliver(internal_invite, meeting) == {:ok, :internal_inbox_push}
      assert InviteDelivery.deliver(external_invite, meeting) == {:ok, :external_chat}

      events = drain()
      internal_id = internal.id
      external_id = external.id

      # ── The internal invitee: inbox AND push AND no chat message ────────

      # (1) the durable inbox row
      assert [{:inbox_emit, attrs}] = inbox_emits_for(events, internal_id)
      assert attrs.kind == "meeting_invited"
      assert attrs.source_id == meeting.id

      # (2) the push. `Inbox.emit/1` inserts and broadcasts; it does NOT
      # push, so (1) alone passes against code that notifies nobody's device.
      assert [{:push_user, ^internal_id, payload, _opts}] = pushes_for(events, internal_id)
      assert payload.url == "/meetings/#{meeting.slug}"

      # (3) and NO chat message. The internal carrier never resolves a
      # delivery space, so there is nowhere for one to have been written —
      # and the meeting's own chat space, the obvious wrong answer, is empty.
      assert is_nil(reload(internal_invite).delivery_space_id)
      assert Chat.list_messages(meeting.chat_space_id, limit: 100) == []

      # ── The external invitee: chat message AND no inbox row AND no push ──

      external_persisted = reload(external_invite)

      # (4) the message, in the space the receipt names, and exactly one of
      # them. Counting the whole table as well pins that the pass produced
      # ONE message in total, so the internal invitee did not get one
      # somewhere this test did not think to look.
      assert is_binary(external_persisted.delivery_space_id)
      assert [%Message{}] = Chat.list_messages(external_persisted.delivery_space_id, limit: 100)
      assert message_count() == before_messages + 1

      # (5) no inbox row — it would be written into a 403 and unreachable.
      assert inbox_emits_for(events, external_id) == []

      # (6) no push — it would deep-link them into that same 403, which
      # looks BROKEN rather than absent and is worse than silence.
      assert pushes_for(events, external_id) == []

      # The receipts name two different carriers for one meeting, which is
      # the invariant in one line.
      assert reload(internal_invite).delivery_carrier == "internal_inbox_push"
      assert external_persisted.delivery_carrier == "external_chat"
    end
  end

  # ── The telemetry event ───────────────────────────────────────────────────

  describe "the invite_delivered telemetry event" do
    setup do
      enable_meetings!()
      :ok
    end

    test "names the carrier, and carries ids only" do
      # The event exists so that after the fact you can see a guest invite's
      # carrier was `:guest_link` and therefore that NOBODY was contacted —
      # which is otherwise indistinguishable from a delivery that landed.
      handler = "invite-delivered-#{System.unique_integer([:positive])}"
      owner = self()

      :telemetry.attach(
        handler,
        [:platform, :meetings, :invite_delivered],
        fn _event, measurements, metadata, _config ->
          send(owner, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      meeting = meeting_hosted_by("Observed", "Ada")

      assert {:ok, %{invite: guest_invite}} =
               Meetings.invite_guest(meeting, %{display_name: "Grace"})

      guest_id = guest_invite.id
      meeting_id = meeting.id

      assert_receive {:telemetry, measurements, metadata}, 1_000
      assert %{invite_id: ^guest_id, meeting_id: ^meeting_id} = metadata
      assert metadata.carrier == :guest_link
      assert metadata.kind == :guest

      # An occurrence, not a tally: `%{count: 1}` cannot answer "when", and
      # nothing sums this event.
      assert is_integer(measurements.system_time)

      # THIS REPOSITORY IS PUBLIC and the event reaches the audit handler.
      # The metadata is ids and one closed-set atom — no email address, no
      # display name, no host name, no URL. Pinned EXACTLY, not as a
      # subset: a floor assertion would admit a future field silently, and
      # a leak is precisely the kind of addition nobody would notice.
      assert Map.keys(metadata) |> Enum.sort() == [:carrier, :invite_id, :kind, :meeting_id]

      refute metadata |> Map.values() |> Enum.any?(&(is_binary(&1) and &1 =~ "Grace"))
    end
  end
end
