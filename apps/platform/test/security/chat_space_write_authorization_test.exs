defmodule Platform.Security.ChatSpaceWriteAuthorizationTest do
  @moduledoc """
  Adversarial suite for the chat space-write choke point (task 01a01ce0,
  stage 1).

  `Platform.Chat.SpaceAccess.authorize_writer/2` is composed by
  `Chat.pin_message/2` and `Chat.unpin_message/3` (and was by
  `Chat.remove_space_agent/3` until task 01a1557a-8f80 stage 3 deleted it).
  `space_access_test.exs` pins the predicate.
  This file exists to prove the composition actually protects the shipped
  surface, and it takes its discipline from
  `task_canvas_attachment_authorization_test.exs`: drive the real transport,
  not a hand-built call into the context.

  ## Forged params, not a UI action

  The pin button is never RENDERED for a space the user is not viewing, so a
  test that clicks something cannot reach this path at all and would pass
  against a completely unguarded context. The vehicle is therefore the one
  `chat_live_test.exs` already uses:

      render_click(view, "pin_toggle", %{"message-id" => id, "space-id" => id})

  A LiveView event is a client-controlled message. `"space-id"` is whatever the
  sender puts in it.

  ## Three traps that would let a broken guard pass green

  All three are handled below, and each is named at the assertion it governs:

    a. **`pin_toggle` returns `{:halt, socket}` on EVERY branch** — denial
       included, and so does the pre-existing nil-participant branch. A render
       diff is therefore identical for "refused" and "written", so every
       assertion here reads `Chat.list_pins/1` or `Repo.get_by(Pin, ...)`.
       Never the HTML.

    b. **The attacker session must NEVER be routed through the target space's
       URL.** `ChatLive.handle_params/3` calls `ensure_participant/2`, which
       INSERTS a `chat_participants` row with no authorization of its own. A
       session that mounts `/chat/<target>` first is a genuine member by the
       time the forged event fires, and the test proves nothing. Every session
       here mounts its OWN space, and `refute Chat.participant?(target, ...)`
       pins that it stayed that way.

    c. **Positive and negative controls target the IDENTICAL space and message
       pair, varying only the actor.** Without a same-test positive control, an
       implementation that refuses everything passes every `refute`.

  ## Reaching the unpin branch honestly

  `PinHooks` decides pin-versus-unpin from `socket.assigns.pinned_message_ids`,
  which is loaded from the VIEWED space. A session sitting on its own space has
  an empty set, so a forged toggle can only ever take the PIN branch. To reach
  the UNPIN branch the message id has to be in that set, so `arm_unpin_branch/2`
  pins the target's message into the session's OWN space first — a legitimate
  write for a member of that space, because `chat_pins` ties `space_id` and
  `message_id` in no way to each other. The forged toggle that follows then
  takes the unpin branch against the target.

  ## Where the transport cannot reach, and why that is stated rather than faked

  No transport in the tree produces an `{:agent, _}` actor for these three
  functions: `PinHooks` builds `{:user, socket.assigns.user_id}` and `ShellLive`
  builds `{:user, socket.assigns[:current_user_id]}`. The agent arm is therefore
  exercised at the context seam, and this note is the reason rather than an
  oversight. Inventing a fake agent transport would be a test of the fake.

  ## Scope of the claim, so nobody over-reads a green run

  This suite proves that a forged `space-id` sent from a session open on a
  DIFFERENT space is refused. It does NOT prove that non-participants cannot
  write, full stop: `ensure_participant/2` mints genuine membership one layer
  above this guard for the kinds in `chat_live.ex`'s
  `@implicitly_joinable_kinds` (`channel`, `system`, `execution`), after which
  `authorize_writer/2` correctly passes. The fixtures here are CHANNELS, so
  that door is open for exactly the spaces under test, which is why trap (b)
  is load-bearing rather than theoretical.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.Pin
  alias Platform.Repo

  # 16 characters: the shape a bare `Ecto.UUID.cast/1` hex-encodes and lets
  # through to raise. `Platform.UUID.valid?/1` is what refuses it.
  @slug_16 "space-slug-16chr"

  # ── Fixtures (invented names only; `core` is a public repo) ───────────────

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  defp user!(label) do
    n = uniq()

    Repo.insert!(%User{
      email: "#{label}-#{n}@example.com",
      name: "#{String.capitalize(label)} #{n}",
      oidc_sub: "oidc-#{label}-#{n}"
    })
  end

  defp space!(label) do
    n = uniq()

    {:ok, space} =
      Chat.create_space(%{name: "#{label} #{n}", slug: "#{label}-#{n}", kind: "channel"})

    space
  end

  defp join!(space, %User{} = user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp agent!(label) do
    n = uniq()
    Repo.insert!(%Agent{slug: "#{label}-#{n}", name: "#{label}-#{n}", status: "active"})
  end

  defp message!(space, participant, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    message
  end

  # A target space with one member and one message in it.
  defp target_fixture do
    target = space!("target")
    owner = user!("owner")
    owner_participant = join!(target, owner)
    message = message!(target, owner_participant, "the message under attack")
    %{space: target, owner: owner, owner_participant: owner_participant, message: message}
  end

  # TRAP (b). The session mounts its OWN space and never touches the target's
  # URL, so `ChatLive.handle_params/3`'s `ensure_participant/2` cannot mint the
  # membership the forged event is supposed to be missing.
  defp forging_session(conn, user) do
    home = space!("home")
    _ = join!(home, user)

    {:ok, view, _html} =
      conn
      |> init_test_session(current_user_id: user.id)
      |> live(~p"/chat/#{home.id}")

    %{view: view, home: home, user: user}
  end

  # Puts `message_id` into the session's `:pinned_message_ids` without touching
  # the target space — see the moduledoc.
  defp arm_unpin_branch(%{view: view, home: home}, message_id) do
    render_click(view, "pin_toggle", %{"message-id" => message_id, "space-id" => home.id})
    _ = render(view)

    assert MapSet.member?(
             :sys.get_state(view.pid).socket.assigns.pinned_message_ids,
             message_id
           ),
           "the session must believe the message is pinned, or the toggle takes the pin branch"

    :ok
  end

  defp forge(%{view: view}, event, params) do
    render_click(view, event, params)
    _ = render(view)
    :ok
  end

  defp pins_in(space_id), do: Chat.list_pins(space_id)

  # ── 1. Cross-space PIN ────────────────────────────────────────────────────

  describe "pin_toggle with a forged space-id" do
    test "a non-participant cannot PIN into the target space; a participant can",
         %{conn: conn} do
      %{space: target, message: message} = target_fixture()

      attacker = user!("attacker")
      attacker_session = forging_session(conn, attacker)

      forge(attacker_session, "pin_toggle", %{
        "message-id" => message.id,
        "space-id" => target.id
      })

      # TRAP (a): every branch of `pin_toggle` halts, so the row is the only
      # honest probe. TRAP (b): the attacker never became a member.
      assert pins_in(target.id) == []
      assert Repo.get_by(Pin, space_id: target.id, message_id: message.id) == nil
      refute Chat.participant?(target.id, attacker.id)

      # TRAP (c) POSITIVE CONTROL — identical space and message, identical
      # forged event, only the actor differs. Without this, an implementation
      # that refuses every write passes the refutation above.
      member = user!("member")
      member_participant = join!(target, member)
      member_session = forging_session(conn, member)

      forge(member_session, "pin_toggle", %{
        "message-id" => message.id,
        "space-id" => target.id
      })

      assert [pin] = pins_in(target.id)
      assert pin.message_id == message.id
      assert pin.pinned_by == member_participant.id
    end

    test "a non-participant cannot UNPIN in the target space; a participant can",
         %{conn: conn} do
      %{space: target, owner: owner, message: message} = target_fixture()

      {:ok, existing} =
        Chat.pin_message({:user, owner.id}, %{space_id: target.id, message_id: message.id})

      attacker = user!("attacker")
      attacker_session = forging_session(conn, attacker)
      :ok = arm_unpin_branch(attacker_session, message.id)

      forge(attacker_session, "pin_toggle", %{
        "message-id" => message.id,
        "space-id" => target.id
      })

      assert Repo.get(Pin, existing.id)
      assert [survivor] = pins_in(target.id)
      assert survivor.id == existing.id
      refute Chat.participant?(target.id, attacker.id)

      # TRAP (c) POSITIVE CONTROL — same target space, same message, same
      # forged event, same armed unpin branch. Only the actor changes.
      member = user!("member")
      _ = join!(target, member)
      member_session = forging_session(conn, member)
      :ok = arm_unpin_branch(member_session, message.id)

      forge(member_session, "pin_toggle", %{
        "message-id" => message.id,
        "space-id" => target.id
      })

      assert Repo.get(Pin, existing.id) == nil
      assert pins_in(target.id) == []
    end

    test "pinned_by names the pinner's participant row in the TARGET space",
         %{conn: conn} do
      # `chat_pins.pinned_by` FKs `chat_participants(id)` with NO same-space
      # constraint, and `put_author_snapshot/3` denormalizes a display name off
      # it, so a pin in space B that names a participant of space A renders that
      # person to space B's members. `pin_message/2` derives the attribution
      # from the row it resolved in the target space; nothing the client sends
      # can influence it.
      %{space: target, message: message} = target_fixture()

      pinner = user!("pinner")
      target_participant = join!(target, pinner)
      session = forging_session(conn, pinner)

      home_participant =
        Repo.get_by!(Participant, space_id: session.home.id, participant_id: pinner.id)

      refute home_participant.id == target_participant.id

      forge(session, "pin_toggle", %{"message-id" => message.id, "space-id" => target.id})

      assert [pin] = pins_in(target.id)
      assert pin.pinned_by == target_participant.id
      refute pin.pinned_by == home_participant.id
    end

    test "a non-UUID space-id is refused without raising", %{conn: conn} do
      %{space: target, message: message} = target_fixture()

      attacker = user!("attacker")
      session = forging_session(conn, attacker)
      pins_before = Repo.aggregate(Pin, :count)

      forge(session, "pin_toggle", %{"message-id" => message.id, "space-id" => @slug_16})

      # The LiveView is still up: a malformed id has to DENY, not crash the
      # session with `Ecto.Query.CastError`.
      assert Process.alive?(session.view.pid)

      # Counted rather than looked up by the malformed id: a `Repo.get_by(Pin,
      # space_id: @slug_16)` probe raises the very CastError this test is about,
      # from the TEST rather than from the system, which would report a pass as
      # a failure and tell nobody anything.
      assert Repo.aggregate(Pin, :count) == pins_before
      assert pins_in(target.id) == []

      # And the exact return value at the context seam, which the halting hook
      # swallows.
      assert {:error, :forbidden} =
               Chat.pin_message({:user, attacker.id}, %{
                 space_id: @slug_16,
                 message_id: message.id
               })

      assert {:error, :forbidden} =
               Chat.unpin_message({:user, attacker.id}, @slug_16, message.id)
    end
  end

  # ── 2. Agent principals (no transport produces these — see the moduledoc) ─

  describe "agent actors at the context seam" do
    test "an agent with no participant row in the target space is refused; one with a row is not" do
      %{space: target, message: message} = target_fixture()

      outsider = agent!("outsider")
      resident = agent!("resident")
      {:ok, resident_participant} = Chat.add_agent_participant(target.id, resident)

      assert {:error, :forbidden} =
               Chat.pin_message({:agent, outsider.id}, %{
                 space_id: target.id,
                 message_id: message.id
               })

      assert pins_in(target.id) == []

      # POSITIVE CONTROL — same space, same message, only the agent differs.
      assert {:ok, pin} =
               Chat.pin_message({:agent, resident.id}, %{
                 space_id: target.id,
                 message_id: message.id
               })

      assert pin.pinned_by == resident_participant.id

      assert {:error, :forbidden} =
               Chat.unpin_message({:agent, outsider.id}, target.id, message.id)

      assert [_] = pins_in(target.id)

      assert {:ok, _} = Chat.unpin_message({:agent, resident.id}, target.id, message.id)
      assert pins_in(target.id) == []
    end
  end

  # ── 3. Members sheet Remove ───────────────────────────────────────────────
  #
  # The utility-bar `dismiss_agent` event took a `space-id` from the client and
  # was the third surface this file guarded. It was deleted with the agents
  # dropdown in task 01a1557a-8f80 stage 3, together with the context function
  # it called, `Chat.remove_space_agent/3`. Removing an agent is now the Members
  # sheet's `members_remove_agent`, which takes NO space id: the space is the
  # component's own `:space` assign. What a forger controls is the participant
  # id, so that is what this forges.

  describe "members_remove_agent with a participant id from another space" do
    test "an admin of their own space cannot evict an agent from the target space; the target's admin can",
         %{conn: conn} do
      %{space: target} = target_fixture()

      agent = agent!("roster-agent")
      {:ok, agent_participant} = Chat.add_agent_participant(target.id, agent)

      # The attacker is an ADMIN of the space they are viewing, so
      # `can_summon_agents?/2` passes there: only the space scoping can stop it.
      attacker = user!("attacker")
      %{view: view, home: home} = forging_session(conn, attacker)

      Participant
      |> Repo.get_by!(space_id: home.id, participant_id: attacker.id)
      |> Ecto.Changeset.change(role: "admin")
      |> Repo.update!()

      assert Chat.can_summon_agents?(Chat.get_space(home.id), attacker.id)

      forge_remove(view, agent_participant.id)

      assert Repo.get(Participant, agent_participant.id)
      refute Chat.participant?(target.id, attacker.id)

      # POSITIVE CONTROL — same agent row, same event, sent by the target's own
      # admin from the target space.
      admin = user!("admin")

      {:ok, _} =
        Chat.add_participant(target.id, %{
          participant_type: "user",
          participant_id: admin.id,
          display_name: admin.name,
          role: "admin",
          joined_at: DateTime.utc_now()
        })

      {:ok, admin_view, _html} =
        conn
        |> init_test_session(current_user_id: admin.id)
        |> live(~p"/chat/#{target.id}")

      forge_remove(admin_view, agent_participant.id)

      assert Repo.get(Participant, agent_participant.id) == nil
    end
  end

  defp forge_remove(view, participant_id) do
    view
    |> with_target("#chat-members")
    |> render_click("members_remove_agent", %{"participant_id" => participant_id})

    _ = render(view)
    :ok
  end
end
