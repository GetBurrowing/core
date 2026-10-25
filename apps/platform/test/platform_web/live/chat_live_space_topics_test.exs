defmodule PlatformWeb.ChatLiveSpaceTopicsTest do
  @moduledoc """
  Task 01a01a1b stage 3: ChatLive's `chat:space:<id>` subscriptions are held
  through `PlatformWeb.SpaceTopics` under an explicit owner (`:chat_rail` for
  a background rail row, `:chat_active` for the space on screen) rather than
  through a module-private `MapSet`.

  Everything here counts registrations DIRECTLY off
  `Registry.lookup(Platform.PubSub, ChatPubSub.space_topic(id))`, filtered to
  the LiveView pid. Never through a `ChatPubSub` helper and never through the
  `:chat_space_holders` assign: the holder map is the thing under test, and a
  test that read its own subject's bookkeeping could not tell a correct holder
  map from one that has drifted away from the registry it claims to describe.

  A count of 1 is not delivery. `Phoenix.PubSub` will hold a registration for a
  process that does nothing with it, so "the count did not drop to 0" is an
  assertion a silently-inert registration also satisfies. `delivery_count/2`
  closes that: it posts a real message on the retained topic and reads the
  unread pill, a counter that moves once per DELIVERY. It answers "exactly N",
  not "at least one" — and exactly-one is the whole point, since the defect on
  the other side of this change is a duplicate registration that an
  `assert_receive` cannot see.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  describe "one registration per space, owned per surface" do
    test "a rail channel that becomes active holds one registration, and still one after leaving",
         %{conn: conn} do
      conn = authed(conn, create_user!("Bramble Viewer"))

      subject = channel!("bramble")
      elsewhere = channel!("clover")

      {:ok, view, _html} = live(conn, ~p"/chat/#{Chat.space_path_segment(subject)}")

      # Active AND on the rail: two holders, one registration. Before this
      # change the enter path had to unsubscribe-then-subscribe to get here.
      assert registrations(view, subject) == 1

      render_patch(view, ~p"/chat/#{Chat.space_path_segment(elsewhere)}")

      # The `:chat_active` hold was released; the `:chat_rail` hold taken at
      # mount survives it. The old code destroyed the registration outright and
      # re-took it from a restore branch that is now deleted.
      assert registrations(view, subject) == 1
      assert registrations(view, elsewhere) == 1

      # ... and the retained registration is LIVE, and fires exactly once. A
      # count of 1 is a fact about the registry; this is a fact about delivery.
      assert delivery_count(view, subject) == 1,
             "the registration that survived the navigation must deliver, and deliver once"
    end

    test "a space reached only by URL holds one while active and none after leaving", %{
      conn: conn
    } do
      conn = authed(conn, create_user!("Dogwood Viewer"))

      on_rail = channel!("dogwood")
      off_rail = execution_space!("Fixture Execution Space")

      {:ok, view, _html} = live(conn, ~p"/chat/#{Chat.space_path_segment(on_rail)}")

      render_patch(view, ~p"/chat/#{Chat.space_path_segment(off_rail)}")
      assert registrations(view, off_rail) == 1

      render_patch(view, ~p"/chat/#{Chat.space_path_segment(on_rail)}")

      # The absence assertion. An execution space is on nobody's rail, so
      # nothing holds it once `:chat_active` lets go and it must reach zero —
      # the direction the naive fix (delete the unsubscribe) leaks in.
      assert registrations(view, off_rail) == 0

      # Its positive control, in the same test: a rail space put through the
      # SAME two navigations does not reach zero. Without this pair, a zero
      # above is equally consistent with a harness that cannot see any
      # registration at all.
      assert registrations(view, on_rail) == 1
    end
  end

  describe "losing access releases chat's holds" do
    setup %{conn: conn} do
      org = tenant_org!()
      viewer = external_user!(org)

      # Both in the viewer's own org: an external identity is refused a space
      # outside its org before any of this stage's code runs, and a 403 mount
      # would make every assertion below vacuous.
      revoked = channel!("elderflower", org_id: org.id)
      retained = channel!("foxglove", org_id: org.id)

      join!(revoked, viewer)
      join!(retained, viewer)

      {:ok, view, _html} =
        live(authed(conn, viewer), ~p"/chat/#{Chat.space_path_segment(revoked)}")

      %{view: view, viewer: viewer, revoked: revoked, retained: retained}
    end

    test "`:participant_left` for the viewer releases chat's holds and empties the topic", ctx do
      # Both spaces start held: the viewer participates in each, so chat's
      # mount loop took a `:chat_rail` hold on both and `handle_params/3` an
      # `:chat_active` hold on `revoked`. ShellLive's presence hook holds them
      # too, from the same pid — that is the whole reason this task exists.
      assert registrations(ctx.view, ctx.revoked) == 1
      assert registrations(ctx.view, ctx.retained) == 1

      participant = leave!(ctx.revoked, ctx.viewer)
      send(ctx.view.pid, {:participant_left, participant})
      _ = render(ctx.view)

      # Zero — and it takes all THREE holds letting go, each released by the
      # surface that took it, in one pass over one event. Chat drops
      # `:chat_rail` and `:chat_active`; ShellLive drops `:presence` from its
      # own hook. Leave any one of them behind and the holder set is non-empty
      # and this reads 1, which is what makes the assertion discriminating
      # rather than a restatement of the teardown.
      assert registrations(ctx.view, ctx.revoked) == 0

      # Positive control, same test: the space the viewer did NOT leave is
      # untouched, so the zero above is a release of one space rather than a
      # teardown of everything — the failure mode `Registry.unregister/2` gave
      # us before this task. No `delivery_count/2` here: an external identity
      # renders the chrome-less rail, which has no `#chat-sidebar` and so no
      # unread pill to read. Delivery on a retained topic is measured in the
      # first case above, on an internal viewer.
      assert registrations(ctx.view, ctx.retained) == 1
    end

    test "the shell's release ALONE does not empty a topic chat still holds", ctx do
      # The discriminating half of the pair. Identical to the case above with
      # the `:participant_left` removed, so the only difference between the two
      # is whether chat released — and the counts differ. Without this, the
      # zero above is equally consistent with `:presence_spaces_resolved`
      # unsubscribing unconditionally, which would be the old all-or-nothing
      # bug wearing a new hat.
      assert registrations(ctx.view, ctx.revoked) == 1

      send(ctx.view.pid, {:presence_spaces_resolved, [ctx.retained.id]})
      _ = render(ctx.view)

      assert registrations(ctx.view, ctx.revoked) == 1,
             "chat still holds :chat_rail and :chat_active here, so the shell letting go " <>
               "must not take the registration with it"
    end
  end

  # ── Registry + delivery probes ──────────────────────────────────────────

  # Entries — not a boolean. `Phoenix.PubSub` starts its registry with
  # `keys: :duplicate`, so a second `subscribe/1` from the same pid adds a
  # SECOND entry and every broadcast on the topic fires `handle_info` twice.
  # A yes/no answer cannot see that, which is why this counts.
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  # How many copies of ONE broadcast the LiveView actually processed.
  #
  # Deliberately not `assert_receive` from the test process — the test process
  # is not a subscriber and, even if it were, `assert_receive` answers
  # "at least one" while the defect on the other side of this change is a
  # SECOND delivery. It needs a counter that moves once per delivery, and
  # `MessagesHooks.increment_unread/2` is exactly that: it runs on every
  # `{:new_message, _}` for a space that is not active and is not the viewer's
  # own message, and the rail pill renders the number it wrote. Two
  # registrations render "2".
  #
  # Also the only probe here that a silently-unregistered topic fails: a
  # registration count is a property of the registry, a moving badge is proof
  # the message crossed it.
  defp delivery_count(view, space) do
    post_from_a_stranger(space, "fixture probe message")

    case unread_pill(render(view), space) do
      nil -> 0
      digits -> String.to_integer(digits)
    end
  end

  # The unread pill on one rail row, or nil when the row carries no pill.
  # Scoped to `#chat-sidebar` because the same row renders again in the mobile
  # drawer and the switcher, and an unscoped query would concatenate their
  # texts into a number that is not the badge.
  # Burrow redesign 22 stage 2 deleted the desktop channel rail: the badge is
  # now the Chat list row's unread count, scoped to `#chat-list-scroller`
  # because the search sheet and popover rows carry the same data-role.
  defp unread_pill(html, space) do
    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space.id}"] [data-role="chat-list-unread-count"] [aria-hidden="true"])
      )

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one list badge for #{space.id}, found #{length(many)}")
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "space-topics-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-space-topics-#{n}",
      avatar_url: nil
    })
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp channel!(slug, opts \\ []) do
    n = System.unique_integer([:positive])

    attrs =
      %{name: String.capitalize(slug), slug: "#{slug}-#{n}", kind: "channel"}
      |> Map.merge(Map.new(opts))

    {:ok, channel} = Chat.create_space(attrs)
    channel
  end

  # A space the rail never lists: not a channel, not a DM, not pinned to a
  # task. Reachable only by typing its URL.
  defp execution_space!(name) do
    {:ok, space} = Chat.create_space(%{name: name, kind: "execution"})
    space
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_space_topics_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  # `handle_info({:participant_left, _})`'s predicate is LOSS OF ACCESS, and
  # `presence_subscribe_space_ids/2` returns its input unchanged for an
  # internal session — so the clause is inert for an internal user by design
  # and an external viewer is the only fixture that exercises it.
  defp external_user!(org) do
    user = create_user!("Xena External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
    user
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

  # Removes the row FIRST and returns the payload the broadcast carries. Order
  # matters: the handler re-derives the viewer's scope from the database, so
  # sending the event while the row still exists would test nothing.
  defp leave!(space, user) do
    participant =
      space.id
      |> Chat.list_participants()
      |> Enum.find(&(&1.participant_type == "user" and &1.participant_id == user.id))

    {:ok, _} = Chat.remove_participant(participant)
    participant
  end

  # A message from somebody who is not the viewer. The `{:new_message, _}`
  # handler skips the unread increment for the viewer's own participant row, so
  # the author has to be a separate participant or `delivery_count/2` reads 0
  # for every tree and its assertions go vacuously red.
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
end
