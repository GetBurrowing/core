defmodule PlatformWeb.ChatRosterSpaceRegistrationTest do
  @moduledoc """
  Task 01a01d10 stage 3. The worst instance of the defect: one space carrying
  THREE `chat:space:<id>` registrations on a single LiveView pid, so its unread
  pill moved by three per message and every reaction, pin, canvas and presence
  event on it was handled three times.

  ## Where the three came from

  `PlatformWeb.ShellLive` is the `on_mount` hook for every authenticated live
  session, so it runs INSIDE `PlatformWeb.ChatLive`'s process. Three
  independent sites on that one pid reach the same space:

    1. `ChatLive.mount` subscribes it as a rail row, through
       `subscribe_space/3` (`chat_live.ex:213`, now delegating to
       `SpaceTopics.hold/3`), driven from the mount loop at `:684-687`.
    2. ShellLive's `{:roster_resolved, sid}` branch subscribes it
       (`shell_live.ex:288-300`, the hold at `:298`).
    3. ShellLive's `{:presence_spaces_resolved, space_ids}` branch subscribes
       it AGAIN (`shell_live.ex:370-389`, the hold at `:381`), because the
       roster space is tracked in the separate `:roster_space_id` assign and
       never appears in `:shell_chat_space_ids`, so the `space_ids -- current`
       difference at `:380` never removes it.

       The assign was called `:presence_space_ids` when this file was written.
       Task 01a01f4c renamed it to `:shell_chat_space_ids`, because it stopped
       naming the presence set: see the correction to the paragraph below.

  Step 3 is guaranteed rather than incidental, and that is what makes this
  case worth its own file. `visible_roster/2` (`shell_live.ex:1001`) requires
  an `exists/1` viewer row with `participant_type: "user"` on a non-archived
  space under `Tenancy.scope`, then narrows twice more: the space must carry
  an agent participant, and its kind must not be in `@private_roster_kinds`
  (`["dm"]`, `:993`). The `space_ids` in step 3 is `Chat.list_member_space_ids/1`
  since task 01a01f4c: the same participation predicate WITHOUT those two
  narrowings AND without the org fence, resolved at `shell_live.ex:1190`. It
  was `Chat.list_viewer_presence_space_ids/1` when this file was written, and
  the subset relation survives the swap in the same direction it always ran.
  The roster set is fenced and twice narrowed; the subscribe set is neither,
  and `Tenancy.scope/3` can only remove rows. So the roster set is still a
  strict SUBSET of `space_ids`, and the roster space is always in it.

  What did change is the reason a zero-org viewer is now affected too. Before
  01a01f4c their `space_ids` was `[]` and step 3 could not fire; now it is
  their full participation set, so a zero-org viewer reaches this file's
  three-registration case on the same terms as an org-affiliated one. Nothing
  asserted below depends on that, because this fixture's viewer holds a
  membership.

  Arrival order does not change the count. If presence resolves first,
  `release_roster_subscriptions/1` (`shell_live.ex:903`) finds
  `:roster_space_id` unset and returns the socket untouched.

  ## Which space the roster picks

  `sid` is not the active space. `async_load_roster/3` (`shell_live.ex:1121`)
  takes it from `visible_roster/2`'s `space_id`, which is the viewer's
  agent-bearing visible space with the newest `space_updated_at`
  (`shell_live.ex:1062`, `:1085`). This fixture makes `roster_space` the ONLY
  agent-bearing space the viewer participates in, so the selection is
  deterministic without depending on timestamp ordering.

  ## The fence, and why it is measured on a different topic

  Task `01a011e6` shipped a confidentiality fence stopping an org-mate's
  session subscribing to a space they are not a member of. Its positive
  control in `shell_live_test.exs` used to be a literal `member_count == 2`,
  which worked because two registrations could distinguish "the roster path
  ran" from "only presence ran". Task `01a01a1b` collapsed that to 1 and moved
  the two-paths claim onto `SpaceTopics.held_by?`, correctly labelled in-file
  as an assign the code under test writes rather than registry evidence.

  That is a real discriminator, and it is a weaker kind of evidence than the
  one it replaced. So the fence assertions below use `space_agents:<id>`
  instead, which is ROSTER-EXCLUSIVE: `shell_live.ex:294` is the only site in
  `apps/platform/lib` that subscribes it (`chat.ex:4311` broadcasts to it and
  `:4333` is the separate `space_agents:*` fan-out topic). It therefore still
  distinguishes the two paths after the collapse, and it does so from
  `Registry.lookup/2` rather than from the subject's own bookkeeping.

  `chat:space:<id>` cannot answer that question here for a second reason: an
  internal viewer's rail is workspace-wide (`Chat.list_spaces/1`, `chat.ex:382`,
  applies no membership filter), so ChatLive holds a `:chat_rail` registration
  on a channel the viewer never joined. A count of 1 on a non-member space is
  the RAIL, not a leak, and asserting 0 there would fail against correct code.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  describe "a background space that the roster, presence and the rail all reach" do
    test "holds one registration and moves its badge by one", %{conn: conn} do
      %{viewer: viewer, org: org} = org_affiliated_viewer!()

      # Mounted here, so `roster_space` stays a BACKGROUND row and never gets
      # the unsubscribe-then-subscribe round trip that would launder its count.
      active = channel!("larkspur", org)

      # THE SUBJECT. Agent-bearing, so `visible_roster/2` selects it; viewer
      # participant row plus matching `org_id`, so it is in the presence set;
      # a channel, so it is on the rail. All three holders reach it.
      roster_space = channel!("marigold", org)

      # CONTROL. On the rail, no participant row, no agent: one registration
      # on every build, before and after the collapse.
      rail_only = channel!("nasturtium", org)

      join!(active, viewer)
      join!(roster_space, viewer)
      seed_agent!(roster_space, "Fixture Roster Agent")

      view = mount_chat(conn, viewer, active)

      # ── Preconditions: all three holders really do reach this space ───────

      assert {:orgs, _} = Tenancy.visibility(viewer),
             "the viewer resolved to :none or :root_all, so the org fence is not being " <>
               "exercised and the presence half may be empty for the wrong reason"

      presence_set = Chat.list_viewer_presence_space_ids(viewer)

      # HOLDER 3, from the database side.
      assert roster_space.id in presence_set,
             "the subject is not in ShellLive's presence set, so the presence branch " <>
               "never reaches it and this fixture cannot produce three registrations"

      # HOLDER 2, from the REGISTRY. `space_agents:<id>` is roster-exclusive,
      # so a registration on it is proof the roster branch ran AND that it
      # selected this space, without reading any assign the code under test
      # writes.
      assert agent_topic_registrations(view, roster_space) == 1,
             "the roster branch did not select the subject, so the roster holder is " <>
               "absent and a count of 1 below would mean two holders rather than three"

      # HOLDER 1 is ChatLive's rail, established by the control below holding
      # a registration under identical conditions minus the agent and the
      # participant row.

      assert active_space_id(view) == active.id
      refute active_space_id(view) == roster_space.id

      assert unread_pill(render(view), roster_space) == nil
      assert unread_pill(render(view), rail_only) == nil

      # ── One message each, from somebody who is not the viewer ─────────────

      post_from_a_stranger(roster_space, "subject fixture message")
      post_from_a_stranger(rail_only, "control fixture message")
      post_from_a_stranger(active, "active fixture message")

      html = render(view)

      # ── Control first ────────────────────────────────────────────────────

      assert unread_pill(html, rail_only) == "1",
             "positive control: a plain rail channel did not increment, so the harness " <>
               "cannot see badges move and the subject assertions prove nothing"

      assert registrations(view, rail_only) == 1,
             "the control is reached only by ChatLive's rail, so it holds exactly one " <>
               "registration on every build"

      # ── The symptom: an unread delta of exactly one ──────────────────────

      assert unread_pill(html, roster_space) == "1",
             "one message moved the badge on the roster space by more than one: the " <>
               "LiveView holds a registration per holder and increment_unread/2 ran once " <>
               "per delivery"

      # ── The cause: exactly one registration for three holders ────────────

      assert registrations(view, roster_space) == 1,
             "the roster space holds more than one registration on one pid, so every " <>
               "broadcast on it (reactions, pins, canvases, presence) is handled more " <>
               "than once"

      # ── Anti-vacuity: THREE distinct owners, not one that arrived alone ───

      # A count of 1 is the right answer for two different reasons, and only
      # one of them is the fix: it is also what a build produces when two of
      # the three holders never arrived. Two of the three are already proven
      # from the registry above (`space_agents:<id>` for the roster, and the
      # control for the rail). This names all three explicitly.
      #
      # Read off the holder map and labelled as such: an assign WRITTEN BY the
      # code under test, so it is NOT evidence about the registry. The
      # `registrations/2` line above is. This is evidence about which owners
      # arrived, which is the precondition that makes that line meaningful,
      # and it is the only surface that records per-owner intent once the
      # registry has collapsed the three into one entry.
      socket = :sys.get_state(view.pid).socket

      for owner <- [:chat_rail, :roster, :presence] do
        assert PlatformWeb.SpaceTopics.held_by?(socket, roster_space.id, owner),
               "#{inspect(owner)} never took a hold on the roster space, so the count of " <>
                 "1 above means a holder failed to arrive rather than that three of them " <>
                 "shared one registration"
      end

      assert unread_pill(html, active) == nil,
             "the channel the session is mounted on grew an unread pill, so increments " <>
               "are no longer gated on the space being in the background"
    end
  end

  describe "the roster confidentiality fence, measured on the roster-exclusive topic" do
    # Task 01a011e6's fence: an org-mate's session must not subscribe to a
    # space they are not a member of. The old positive control was a literal
    # `member_count == 2` on `chat:space:<id>`; the collapse to 1 removed its
    # ability to discriminate. This restores the discriminator on
    # `space_agents:<id>`, which stays one-per-roster-space after the collapse
    # because only the roster branch ever subscribes it.
    #
    # Deliberately in a NEW file rather than as an edit to
    # `shell_live_test.exs`, which tasks 01a02491 and 01a01f4c may both be
    # touching.
    test "no roster subscription for an agent space the viewer never joined", %{conn: conn} do
      %{viewer: viewer, org: org} = org_affiliated_viewer!()

      active = channel!("larkspur", org)
      roster_space = channel!("marigold", org)

      # Same kind, same org, agent-bearing, and created AFTER the member
      # space. The only difference is the missing participant row.
      foreign = channel!("oleander", org)

      join!(active, viewer)
      join!(roster_space, viewer)
      seed_agent!(roster_space, "Fixture Roster Agent")
      seed_agent!(foreign, "Fixture Foreign Agent")

      view = mount_chat(conn, viewer, active)

      # The fence, as a database fact first: a space with no viewer row is not
      # in the presence set either, so neither shell branch can reach it.
      presence_set = Chat.list_viewer_presence_space_ids(viewer)
      refute foreign.id in presence_set
      assert roster_space.id in presence_set

      # THE FENCE.
      assert agent_topic_registrations(view, foreign) == 0,
             "the session holds a roster subscription on a space the viewer never " <>
               "joined, so the 01a011e6 confidentiality fence is open"

      # THE POSITIVE CONTROL, and the replacement for the retired
      # `member_count == 2`. An unpaired refute above would pass against a
      # build whose roster branch never ran at all. This is registry evidence,
      # on a topic only the roster branch subscribes, that the path under test
      # was alive and selected the member space.
      assert agent_topic_registrations(view, roster_space) == 1,
             "the roster path never subscribed the member space either, so the fence " <>
               "assertion above is green because the roster branch is DEAD rather than " <>
               "because it is fenced"

      # Documented for the next reader, because the intuitive assertion here
      # is wrong: an internal viewer's rail is workspace-wide, so ChatLive
      # holds a `:chat_rail` registration on `foreign` despite the missing
      # participant row. One is the rail. It is not a leak, and asserting 0
      # would red against correct code.
      assert registrations(view, foreign) == 1,
             "the non-member space holds a number of chat:space registrations that is " <>
               "neither the rail's one nor zero, so a shell branch has added one"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # A viewer holding a plain membership in a CHILD org of the root. A
  # membership in the root org resolves to `:root_all`, which leaves the query
  # unscoped and would make the org fence untestable here.
  defp org_affiliated_viewer! do
    org =
      Repo.insert!(
        Org.changeset(%Org{}, %{
          name: "Roster Fixture Tenant #{unique()}",
          slug: "roster_fixture_tenant_#{unique()}",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id
        })
      )

    viewer =
      Repo.insert!(%User{
        email: "roster-space-#{unique()}@example.test",
        name: "Roster Fixture Viewer",
        oidc_sub: "oidc-roster-space-#{unique()}",
        avatar_url: nil
      })

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: viewer.id,
        org_id: org.id,
        role: "member"
      })
    )

    %{viewer: viewer, org: org}
  end

  # `org_id` matters: a channel with a NULL `org_id` is dropped by
  # `Tenancy.scope` however many memberships the viewer holds, because
  # `NULL in ^ids` is NULL rather than false. That is how a fixture in this
  # area goes silently blind.
  defp channel!(slug, org) do
    {:ok, channel} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: "#{slug}-#{unique()}",
        kind: "channel",
        org_id: org.id
      })

    channel
  end

  defp join!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # The agent participant is what `visible_roster/2` selects on. Inserted
  # directly rather than through `Chat.add_participant/2` so seeding it does
  # not broadcast a roster change the LiveView would react to.
  defp seed_agent!(space, name) do
    agent =
      Repo.insert!(%Agent{
        name: name,
        slug: "#{String.downcase(String.replace(name, " ", "-"))}-#{unique()}",
        status: "active",
        runtime_type: "builtin"
      })

    Repo.insert!(%Chat.Participant{
      space_id: space.id,
      participant_type: "agent",
      participant_id: agent.id,
      role: "principal",
      display_name: agent.name,
      joined_at: DateTime.utc_now()
    })

    agent
  end

  # `handle_info({:new_message, _})` skips the increment when the message
  # carries the viewer's own participant row, so the author has to be somebody
  # else or the badge never moves and every assertion goes vacuously red.
  defp post_from_a_stranger(space, body) do
    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Fixture Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: body
      })

    message
  end

  defp mount_chat(conn, viewer, space) do
    {:ok, view, _html} =
      conn
      |> init_test_session(current_user_id: viewer.id)
      |> live(~p"/chat/#{Chat.space_path_segment(space)}")

    settle(view)
  end

  # `render_async/1` waits for the shell's `assign_async` loaders; each sends
  # its resolution message before returning and both travel the same mailbox
  # in order, so the trailing `render/1` round trip guarantees the LiveView
  # has processed `{:roster_resolved, _}` AND `{:presence_spaces_resolved, _}`.
  # Never `Process.sleep/1`: that pins the box's timing rather than the code's
  # ordering, and the arrival of those two messages is this file's subject.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    view
  end

  defp unique, do: System.unique_integer([:positive])

  # ── Reading the registry, never the holder assign ─────────────────────────

  # How many `chat:space:<id>` registrations the LiveView process holds.
  # `Phoenix.PubSub.subscribe/2` is `Registry.register/3` on a
  # `keys: :duplicate` registry, so this counts ENTRIES rather than answering
  # a yes/no, which is the whole point: three entries fire `handle_info`
  # three times.
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(Platform.Chat.PubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  # The ROSTER-EXCLUSIVE topic. `shell_live.ex:294` is the only site in
  # `apps/platform/lib` that subscribes `space_agents:<id>`, so a registration
  # here means the roster branch ran and chose this space, and nothing else
  # can produce one. This is the discriminator that survives the collapse of
  # `chat:space:<id>` to a single shared registration.
  defp agent_topic_registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup("space_agents:#{space.id}")
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  defp active_space_id(view) do
    case :sys.get_state(view.pid).socket.assigns[:active_space] do
      nil -> nil
      space -> space.id
    end
  end

  # ── Assertions ────────────────────────────────────────────────────────────

  # The unread pill on one channel's desktop rail row, or nil when the row
  # carries no pill. Scoped to `#chat-sidebar` because the same row renders
  # again in the mobile drawer and the switcher, and an unscoped query would
  # concatenate their texts into a number that is not the badge.
  defp unread_pill(html, space) do
    href = "/chat/#{Chat.space_path_segment(space)}"

    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#chat-sidebar a[href="#{href}"] .channel-row-unread-pill))

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one rail pill for #{href}, found #{length(many)}")
    end
  end
end
