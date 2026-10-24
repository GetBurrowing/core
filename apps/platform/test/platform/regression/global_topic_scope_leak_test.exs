defmodule Platform.Regression.GlobalTopicScopeLeakTest do
  @moduledoc """
  Task 019ffca8 stage 5 — scoped leak tests for the install-wide chat and audit
  PubSub topics.

  ## What this file generalises

  On 2026-08-06, PR core#676 fixed a `transcript_chunk` broadcast on an unscoped
  topic that let a subscriber receive a sibling's chunk. The fix bound the refute
  to `%{transcript_id: ^id}`. One instance found and closed; nobody had asked
  since whether it was the only one. Stage 2 of this task classified 56 topic
  shapes across 62 call sites and found 25 global topics
  (`pubsub_topic_inventory_audit_test.exs`). This file is the regression net
  under the chat and audit ones; the meetings topics, which have the same
  bare-vs-scoped construction core#676 got wrong, are in
  `meetings_topic_scope_leak_test.exs`. `Platform.PubSubLeakHelpers` carries the
  machinery both use and explains the watcher-process design.

  ## The anti-vacuity contract

  A test asserting "no message leaked" passes trivially against a system that
  delivered nothing at all: a broken broadcast would read as a security pass. So
  EVERY refute here is paired, IN THE SAME TEST, with a positive control proving
  the legitimate subscriber DID receive what it was entitled to.

  The topics in this file are genuinely global: `chat:spaces`,
  `chat:sidebar:defaults` and `audit:all` have no "outside the scope" at the
  broadcast layer, because every connected session is a subscriber by design. So
  the assertion is mostly the second half of the brief — a subscriber "cannot
  derive protected content from it" — and the positive control is the delivery
  itself. These tests pin the payload SHAPE, so a future change that enriches a
  ping with the content it currently omits fails here rather than in production.
  Where a scoped sibling DOES exist (`space_agents:<space_id>`,
  `audit:<event_type>`, `audit:<resource_type>:<resource_id>`) the refute is the
  cross-scope one and the control is the same subscription's own event.

  ## async: false, deliberately

  `chat:sidebar:defaults` carries a bare atom with no payload, so its refute
  cannot be bound to a fixture id the way `%{transcript_id: ^id}` can. A
  concurrent async test broadcasting the same atom would land in this module's
  mailbox and fail the refute for a reason it does not assert. Running sync is
  the only way to own the mailbox for that one, and the unbound
  `{:space_archived, _}` refute relies on it too. Every other assertion here is
  bound to a fixture id and would hold either way.

  ## What is deliberately NOT here

  Changing any topic's design, and adding any guard. This stage writes tests.
  The `:canvas_restored` clause that stage 3 recorded as unguarded is covered in
  `test/platform_web/live/chat_live_canvas_scope_leak_test.exs`, where the hook
  state is observable; the fix for it belongs to task
  `01a011a8-0038-76c5-8880-f41fa3dafaa8`.
  """
  use Platform.DataCase, async: false

  import Platform.PubSubLeakHelpers

  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp channel!(name) do
    {:ok, space} = Chat.create_space(%{name: name, slug: "leak-ch-#{unique()}", kind: "channel"})
    space
  end

  defp agent! do
    n = unique()

    %Agent{}
    |> Agent.changeset(%{
      slug: "leak-agent-#{n}",
      name: "Leak Agent #{n}",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  # A real org row — `audit_events.actor_org_id` carries an FK, so a random
  # UUID cannot stand in for "some other tenant".
  defp tenant_org! do
    n = unique()

    %Org{}
    |> Org.changeset(%{
      name: "Leak Tenant #{n}",
      slug: "leak_tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp participant_for!(space) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Member #{unique()}",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp canvas!(space, participant, title) do
    Chat.create_canvas(%{
      "space_id" => space.id,
      "created_by" => participant.id,
      "title" => title,
      "created_by_display_name" => "Member",
      "created_by_participant_type" => "user",
      "document" => %{
        "version" => 1,
        "revision" => 1,
        "root" => %{"id" => "root", "type" => "stack", "children" => []}
      }
    })
  end

  defp audit_subscription_regex, do: ~r/Audit\.subscribe\(|"audit:all"/

  # ── chat:spaces — global by design, so the payload is the boundary ─────────

  describe "chat:spaces" do
    test "a non-member receives the new space row and can derive no content from inside it" do
      assert :ok = ChatPubSub.subscribe_spaces()

      # POSITIVE CONTROL through the real production path: `Chat.create_space/1`
      # broadcasts to every connected session, member or not. This subscriber
      # joined no space and is entitled to nothing, and it still receives the
      # row. That is the documented design (a new channel appears in every
      # internal rail without a refresh) and stage 2 accepted it.
      space = channel!("Global Fanout Channel")
      space_id = space.id

      assert_receive {:space_created, %Space{id: ^space_id}}, 1_000

      # Now put content in the space and re-broadcast the row, which is what
      # any producer on this topic hands every session in the install.
      participant = participant_for!(space)
      body = "channel-body-#{unique()}"
      canvas_title = "channel-canvas-#{unique()}"

      {:ok, _message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: body
        })

      {:ok, _canvas} = canvas!(space, participant, canvas_title)

      populated = Repo.get!(Space, space.id)
      ChatPubSub.broadcast_space_event({:space_created, populated})

      assert_receive {:space_created, %Space{id: ^space_id} = second}, 1_000

      # THE LEAK ASSERTION: the row that reaches every non-member carries no
      # message body, no canvas and no roster. `Space` has no associations
      # today, so this holds by schema shape — the test exists because the
      # producer hands the topic whatever struct it happens to be holding, and
      # a `Repo.preload` added upstream would push content onto a topic every
      # session in the install joins.
      refute deep_inspect(second) =~ body
      refute deep_inspect(second) =~ canvas_title

      ChatPubSub.unsubscribe_spaces()
    end

    test "archiving a space puts nothing on the global topic, by any producer shape" do
      # `Chat.PubSub.spaces_topic/0`'s @doc promises subscribers receive
      # `{:space_archived, space}`. Nothing broadcasts it and nothing handles
      # it: both archive paths (`archive_space/1` and `/2`) end at
      # `tap_space_lifecycle_telemetry/4`, which emits telemetry only.
      #
      # Runtime rather than only a source scan, because a scan can see just the
      # spelling it was written for. This catches `broadcast_space_event(event)`
      # with the tuple built on a previous line, and a direct
      # `Phoenix.PubSub.broadcast` to `spaces_topic()`, neither of which a regex
      # over the inline-literal call form would find.
      assert :ok = ChatPubSub.subscribe_spaces()

      space = channel!("Doomed Channel")
      space_id = space.id

      # POSITIVE CONTROL on the very subscription the refute below uses: this
      # topic is live, this process is on it, and it does deliver.
      assert_receive {:space_created, %Space{id: ^space_id}}, 1_000

      assert {:ok, _archived} = Chat.archive_space(space)

      # THE ASSERTION. Deliberately unbound: the point is that NO archival event
      # of any shape reaches this topic, so binding it to `^space_id` would miss
      # a producer that broadcast a bare id or a map. Safe unbound because this
      # is a sync module and nothing in the tree broadcasts the event at all.
      refute_receive {:space_archived, _}, 300

      # A source scan alongside it, for the case where a producer is added but
      # this test's runtime path (the system-level `archive_space/1`) is not the
      # one that reaches it. Matched on the EVENT TUPLE rather than on the
      # broadcast call, so building the tuple on a previous line does not evade.
      #
      # The backtick guards exclude doc prose — `spaces_topic/0`'s own @doc
      # names both events in backticks, which is the documentation this test
      # exists to contradict, not a producer. Prose that names the tuple WITHOUT
      # backticks still trips the scan. That is the right direction to be wrong
      # in: this assertion errs toward a loud false red, never toward a silent
      # false green.
      producers = matching_sources(lib_sources(), ~r/(?<!`)\{:space_archived,\s*\w+\}(?!`)/)

      assert producers == [], """
      `{:space_archived, _}` is now constructed as an event tuple in:

      #{Enum.map_join(producers, "\n", &"  #{&1}")}

      Every connected chat session joins `chat:spaces`, so if that tuple reaches
      the topic it needs the same pair the `:space_created` test above has:
      prove a non-member receives it, and prove nothing from inside the archived
      space rides along.
      """

      # POSITIVE CONTROL for the scan: the same shape, backtick guards included,
      # against the event that IS produced must find its call site
      # (`chat.ex:93`). Without this the guards could exclude everything and the
      # assertion above would be green forever.
      assert matching_sources(lib_sources(), ~r/(?<!`)\{:space_created,\s*\w+\}(?!`)/) != [],
             "the scan found no `{:space_created, _}` producer tuple either, so it is broken " <>
               "rather than reporting a real absence"

      ChatPubSub.unsubscribe_spaces()
    end
  end

  # ── space_agents:<space_id> — the per-space roster topic ───────────────────
  #
  # The global `space_agents:*` ping this describe also covered was deleted in
  # task 01a1557a-8f80 stage 3 with its only subscriber, the utility bar's
  # agents meter. What is left to hold is that the per-space topic is per space.

  describe "space_agents:<space_id>" do
    test "the per-space roster topic never fires for a sibling space" do
      ours = channel!("Our Roster Channel")
      theirs = channel!("Their Roster Channel")
      their_agent = agent!()
      their_id = theirs.id
      our_id = ours.id

      # Per-space subscription for OUR space only.
      watcher(:roster_ours, fn ->
        Phoenix.PubSub.subscribe(Platform.PubSub, "space_agents:#{ours.id}")
      end)

      # PROOF THE EVENT IS ON THE WIRE: this process hears THEIR topic.
      assert :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "space_agents:#{theirs.id}")

      # A real roster mutation in the OTHER space.
      assert {:ok, _entry} = Chat.add_space_agent(theirs.id, their_agent.id)

      assert_receive {:roster_changed, ^their_id}, 1_000

      # THE LEAK ASSERTION: our space's roster subscribers heard nothing.
      refute_receive {:roster_ours, {:roster_changed, ^their_id}}, 300

      # POSITIVE CONTROL on the refuted per-space subscription.
      our_agent = agent!()
      assert {:ok, _entry} = Chat.add_space_agent(ours.id, our_agent.id)

      assert_receive {:roster_ours, {:roster_changed, ^our_id}},
                     1_000,
                     "the per-space roster subscription delivered nothing even for its OWN " <>
                       "space, so the refute above was passing for the wrong reason"

      Phoenix.PubSub.unsubscribe(Platform.PubSub, "space_agents:#{theirs.id}")
    end
  end

  # ── chat:sidebar:defaults — a payload-free global ping ─────────────────────

  describe "chat:sidebar:defaults" do
    test "the defaults ping is a bare atom, delivered to other sessions and never echoed to the actor" do
      # Stand-in for a second connected session: any user, any org, no
      # membership anywhere. It is entitled to the ping (its resolved sidebar
      # may have changed) and to nothing else.
      watcher(:other_session, fn -> ChatPubSub.subscribe_sidebar_defaults() end)

      # The acting admin's own session also holds the subscription.
      assert :ok = ChatPubSub.subscribe_sidebar_defaults()

      ChatPubSub.broadcast_sidebar_defaults_changed_from(self())

      # POSITIVE CONTROL: the other session received it, and what it received
      # is the bare atom. That is the whole reason this topic is acceptable as
      # an install-wide broadcast — there is no payload to leak, so the
      # receiving session recomputes from its OWN authorization. Pin the atom:
      # `{:sidebar_defaults_changed, sections}` would hand every session in the
      # install another org's curated layout.
      assert_receive {:other_session, relayed}, 1_000
      assert relayed == :sidebar_defaults_changed

      # THE SCOPING THIS TOPIC ACTUALLY HAS: `broadcast_from/4` excludes the
      # acting pid, because the admin's handler already recomputed synchronously
      # and a second pass would clobber the just-applied state. The control for
      # this refute is necessarily on a second pid — that is the only correct
      # shape for an exclusion.
      refute_receive :sidebar_defaults_changed, 300

      ChatPubSub.unsubscribe_sidebar_defaults()
    end
  end

  # ── audit:all and its scoped siblings ─────────────────────────────────────

  describe "audit topics" do
    test "audit:<event_type> does not deliver a different event type, and does deliver its own" do
      ours = "platform.leaktest.ours.#{unique()}"
      theirs = "platform.leaktest.theirs.#{unique()}"

      watcher(:type_ours, fn -> Audit.subscribe("audit:#{ours}") end)
      assert :ok = Audit.subscribe("audit:all")

      assert {:ok, foreign} =
               Audit.record(%{
                 event_type: theirs,
                 actor_type: "system",
                 action: "created",
                 metadata: %{"detail" => "foreign-detail-#{unique()}"}
               })

      foreign_id = foreign.id

      # PROOF THE EVENT WAS ON THE WIRE: `audit:all` is the install-wide
      # fan-out and receives every recorded event.
      assert_receive {:audit_event, %{id: ^foreign_id}}, 1_000

      # THE LEAK ASSERTION.
      refute_receive {:type_ours, {:audit_event, %{id: ^foreign_id}}}, 300

      # POSITIVE CONTROL on the refuted subscription.
      assert {:ok, own} =
               Audit.record(%{event_type: ours, actor_type: "system", action: "created"})

      own_id = own.id

      assert_receive {:type_ours, {:audit_event, %{id: ^own_id}}},
                     1_000,
                     "the event-type-scoped audit subscription delivered nothing even for its " <>
                       "OWN type, so the refute above was passing for the wrong reason"
    end

    test "audit:<resource_type>:<resource_id> does not deliver a sibling resource's event" do
      event_type = "platform.leaktest.resource.#{unique()}"
      our_resource = Ecto.UUID.generate()
      their_resource = Ecto.UUID.generate()
      their_name = "Their Private Channel #{unique()}"

      watcher(:resource_ours, fn -> Audit.subscribe("audit:chat_space:#{our_resource}") end)
      assert :ok = Audit.subscribe("audit:all")

      assert {:ok, foreign} =
               Audit.record(%{
                 event_type: event_type,
                 actor_type: "user",
                 actor_id: Ecto.UUID.generate(),
                 action: "archived",
                 resource_type: "chat_space",
                 resource_id: their_resource,
                 metadata: %{"space_name" => their_name}
               })

      foreign_id = foreign.id

      # PROOF THE EVENT WAS ON THE WIRE, carrying a space name a non-member
      # never had — which is exactly why the resource scoping has to hold.
      assert_receive {:audit_event, %{id: ^foreign_id, metadata: %{"space_name" => ^their_name}}},
                     1_000

      refute_receive {:resource_ours, {:audit_event, %{id: ^foreign_id}}}, 300

      assert {:ok, own} =
               Audit.record(%{
                 event_type: event_type,
                 actor_type: "user",
                 actor_id: Ecto.UUID.generate(),
                 action: "archived",
                 resource_type: "chat_space",
                 resource_id: our_resource
               })

      own_id = own.id

      assert_receive {:resource_ours, {:audit_event, %{id: ^own_id}}},
                     1_000,
                     "the resource-scoped audit subscription delivered nothing even for its OWN " <>
                       "resource, so the refute above was passing for the wrong reason"

      # And no copy of the foreign event reached the scoped watcher by any
      # shape, name included.
      relayed = for {:resource_ours, msg} <- collect(200), do: msg

      refute_any_mentions(
        relayed,
        their_name,
        "the resource-scoped audit subscription relayed a sibling resource's space name:"
      )
    end

    test "audit:all is install-wide by construction, so its subscriber set is the whole boundary" do
      # There is no "outside the scope" for `audit:all`: it is every audit event
      # in the install, cross-org, and the payload is the persisted
      # `%Audit.Event{}` including caller-supplied `metadata`. Space archival
      # already routes `space_name` through it
      # (`tap_space_lifecycle_telemetry/4`), so the stream does carry names a
      # non-member never had. That is what an audit log is for; the boundary is
      # therefore WHO may subscribe, not what is on the topic, and this test
      # pins that rather than pretending the payload is scoped.
      other_tenant = tenant_org!()

      assert :ok = Audit.subscribe("audit:all")

      assert {:ok, event} =
               Audit.record(%{
                 event_type: "platform.leaktest.crossorg.#{unique()}",
                 actor_type: "user",
                 actor_id: Ecto.UUID.generate(),
                 actor_org_id: other_tenant.id,
                 action: "created",
                 metadata: %{"space_name" => "Someone Else's Channel"}
               })

      event_id = event.id

      # POSITIVE CONTROL and the finding in one: a subscriber with no
      # relationship to that actor's org receives the event, metadata included.
      assert_receive {:audit_event, %{id: ^event_id, metadata: metadata}}, 1_000
      assert metadata["space_name"] == "Someone Else's Channel"

      # THE BOUNDARY: no LiveView, Channel or Controller under platform_web may
      # hold this subscription without its own authorization. Today none does.
      # There is no established scoped-read pattern on that surface to point at
      # either — `Audit.list/1` and `Audit.stream/1` have no platform_web
      # callers at all (the Activity page that read agent actions another way
      # was retired by task 01a1557a-7a71 stage 4). So the property held here is
      # "the firehose has no user-facing subscriber", not "user-facing surfaces
      # read it safely by some other route".
      subscribers = matching_sources(web_sources(), audit_subscription_regex())

      assert subscribers == [], """
      A module under platform_web now subscribes to the audit stream:

      #{Enum.map_join(subscribers, "\n", &"  #{&1}")}

      `audit:all` carries every audit event in the install, cross-org, with
      caller-supplied metadata (space names among it). A user-facing process on
      that topic is a cross-org read with no query scoping in front of it. If
      the surface is genuinely admin-only it still needs the authorization at
      the SUBSCRIBE, and this test needs narrowing to say so.
      """

      # POSITIVE CONTROL for the PATTERN, not merely for the glob.
      # `Audit.subscribe(` appears in ZERO files under lib today — the only
      # definition is in `audit.ex` — so without this the assertion above is
      # unfalsifiable: rename the function, or call it through an alias, and it
      # stays green forever. Over the whole lib tree the pattern must find
      # `audit.ex` via its "audit:all" literal.
      assert matching_sources(lib_sources(), audit_subscription_regex()) != [], """
      The audit-subscription pattern matches nothing anywhere in lib, including
      `platform/audit.ex`, which defines `subscribe/1` and broadcasts to
      "audit:all". The pattern is broken, so the platform_web assertion above is
      reporting "no subscribers" for every possible input rather than a real
      absence.
      """
    end
  end
end
