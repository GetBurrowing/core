defmodule PlatformWeb.ChatLiveReplyQuoteTest do
  @moduledoc """
  The main-log reply quote (task 01a174f5 stage 3, design canvas 01a174f6):
  `PlatformWeb.Components.ReplyQuote` rendered on a top-level row whose
  `metadata["reply_to_message_id"]` resolves, by `ReplyQuoteHooks`.

  Presence, not layout: every assertion is an element (or its text) found
  with `LazyHTML.query/2`.

  Named mutations this file is meant to kill:

    * M14 always show the quote (drop the adjacency rule);
    * M15 never show it for agents;
    * M16 apply adjacency to member replies too;
    * M17 render the target's own quote inside the quote (nesting);
    * M18 render quotes in thread rows;
    * M19 drop the deleted state;
    * M19b drop the re-insert on delete;
    * M20 render a thread chip on the agent's original.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "reply_quote_#{n}@example.com",
        name: "Member",
        oidc_sub: "oidc-reply-quote-#{n}",
        avatar_url: nil
      })

    {:ok, space} =
      Chat.create_space(%{name: "Quote #{n}", slug: "quote-#{n}", kind: "channel"})

    viewer = add_user(space, user)
    agent_a = add_agent(space, "Agent A", "teal")
    agent_b = add_agent(space, "Agent B", "amber")

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     space: space,
     viewer: viewer,
     a: agent_a,
     b: agent_b}
  end

  defp add_user(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp add_agent(space, name, color) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "reply-quote-agent-#{n}",
        name: name,
        status: "active",
        color: color,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post_msg(space, participant, content, extra \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: content
          },
          extra
        )
      )

    msg
  end

  # A member's main-log reply (stage 1's attr) and an agent's answer (the
  # metadata key a federated or built-in agent writes).
  defp member_reply(space, viewer, target, content),
    do: post_msg(space, viewer, content, %{reply_to_message_id: target.id})

  defp answer(space, agent, target, content),
    do: post_msg(space, agent, content, %{metadata: %{"reply_to_message_id" => target.id}})

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  defp q(view, selector) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector)
  end

  defp present?(view, selector), do: Enum.count(q(view, selector)) > 0
  defp text(view, selector), do: view |> q(selector) |> LazyHTML.text()

  defp row(msg), do: ~s([data-message-id="#{msg.id}"])
  defp quote_of(msg), do: row(msg) <> ~s( [data-role="reply-quote"])

  describe "an agent's answer" do
    test "adjacent agent answer has no reply-quote (M14)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      ans = answer(space, a, reply, "After the audit, likely Monday.")

      view = open_chat(conn, space)

      # Positive control: the row is there and the member's reply quotes.
      assert present?(view, row(ans))
      assert present?(view, quote_of(reply))
      refute present?(view, quote_of(ans))
    end

    test "adjacent agent answer arriving LIVE has no reply-quote (M14)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      view = open_chat(conn, space)

      reply = member_reply(space, viewer, orig, "When does it ship?")
      ans = answer(space, a, reply, "After the audit, likely Monday.")

      assert present?(view, row(ans))
      assert present?(view, quote_of(reply))
      refute present?(view, quote_of(ans))
    end

    test "agent answer with a message in between shows the reply-quote naming the member and the reply text (M15)",
         %{conn: conn, space: space, viewer: viewer, a: a} do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler while waiting")
      ans = answer(space, a, reply, "After the audit, likely Monday.")

      for view <- [open_chat(conn, space)] do
        assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-author"])) =~ "Member"

        assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-preview"])) =~
                 "When does it ship?"
      end
    end

    test "agent answer with a message in between, LIVE, shows the reply-quote (M15)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      view = open_chat(conn, space)

      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler while waiting")
      ans = answer(space, a, reply, "After the audit, likely Monday.")

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-author"])) =~ "Member"

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-preview"])) =~
               "When does it ship?"
    end

    test "the answer's quote contains the reply text and not the agent original (M17)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler while waiting")
      ans = answer(space, a, reply, "After the audit, likely Monday.")

      view = open_chat(conn, space)

      quote_text = text(view, quote_of(ans))
      assert quote_text =~ "When does it ship?"
      refute quote_text =~ "The viewer fix is in review."
      # One level: no quote block inside the quote block.
      refute present?(view, quote_of(ans) <> ~s( [data-role="reply-quote"]))
      assert Enum.count(q(view, row(ans) <> ~s( [data-role="reply-quote"]))) == 1
    end

    test "a short 'yes' or emoji reply is still quoted", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "Ship it today?")
      yes = member_reply(space, viewer, orig, "yes")
      _filler = post_msg(space, viewer, "something else")
      ans = answer(space, a, yes, "Shipping.")
      emoji = member_reply(space, viewer, orig, "👍")
      _filler = post_msg(space, viewer, "and another")
      ans2 = answer(space, a, emoji, "Noted.")

      view = open_chat(conn, space)

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-preview"])) =~ "yes"
      assert text(view, quote_of(ans2) <> ~s( [data-role="reply-quote-preview"])) =~ "👍"
    end

    test "an agent answer at the head of the window still sees its predecessor", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      ans = answer(space, a, reply, "After the audit, likely Monday.")
      # 49 newer rows: the window (newest 50) starts at `ans`, and `reply`
      # is outside it.
      for i <- 1..49, do: post_msg(space, viewer, "later #{i}")

      view = open_chat(conn, space)

      assert present?(view, row(ans))
      refute present?(view, row(reply))
      refute present?(view, quote_of(ans))
    end
  end

  describe "a member's reply" do
    test "a member reply directly under the agent message still shows its quote (M16)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")

      view = open_chat(conn, space)

      assert text(view, quote_of(reply) <> ~s( [data-role="reply-quote-author"])) =~ "Agent A"

      assert text(view, quote_of(reply) <> ~s( [data-role="reply-quote-preview"])) =~
               "The viewer fix is in review."
    end

    test "the bar takes the quoted author's colour: the agent slot, or base-300 for a person", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)

      # Quoting Agent A (teal): the block points --ag at A's slot and the
      # bar paints it, aria-hidden.
      assert present?(view, quote_of(reply) <> ~s([data-agent-slot="teal"]))

      assert present?(
               view,
               quote_of(reply) <>
                 ~S| [data-role="reply-quote-bar"][aria-hidden="true"].bg-\(--ag\)|
             )

      # Quoting a person: no slot, the neutral bar.
      refute present?(view, quote_of(ans) <> "[data-agent-slot]")
      assert present?(view, quote_of(ans) <> ~s( [data-role="reply-quote-bar"].bg-base-300))
    end
  end

  describe "jumping from a quote" do
    test "a visible quote is a button that jumps with the quote variant", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)

      assert present?(view, row(ans) <> ~s( button[data-role="reply-quote"]))
      view |> element(row(ans) <> ~s( button[data-role="reply-quote"])) |> render_click()

      assert_push_event(view, "chat:message-jump", %{id: jumped, variant: "quote"})
      assert jumped == reply.id
      assert_patch(view, "/chat/#{space.slug}?message=#{reply.id}")
    end

    # Fix stage, clause 2: the quote jump's ONLY mark is the neutral
    # `.chat-message-jump-quote` flash. The `?message=` patch it makes used to
    # also paint the deep-link arrival highlight for ~6s.
    test "after a quote jump the target row has neither bg-primary/5 nor ring-primary/20", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)
      view |> element(row(ans) <> ~s( button[data-role="reply-quote"])) |> render_click()
      assert_patch(view, "/chat/#{space.slug}?message=#{reply.id}")

      # The jump DID land on the row (the arrival anchor), it just is not tinted.
      assert :sys.get_state(view.pid).socket.assigns.highlighted_message_id == reply.id
      assert present?(view, row(reply))
      refute present?(view, row(reply) <> ".bg-primary\\/5")
      refute present?(view, row(reply) <> ".ring-primary\\/20")
    end

    test "the Answering panel's jump still applies the primary highlight", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      _ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)
      render_click(view, "jump_to_answered_message", %{"message-id" => reply.id})
      assert_push_event(view, "chat:message-jump", payload)
      refute Map.has_key?(payload, :variant)
      assert_patch(view, "/chat/#{space.slug}?message=#{reply.id}")

      assert present?(view, row(reply) <> ".bg-primary\\/5.ring-1.ring-primary\\/20")
    end

    test "a panel jump after a quote jump to the same row gets the primary highlight back", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)
      view |> element(row(ans) <> ~s( button[data-role="reply-quote"])) |> render_click()
      refute present?(view, row(reply) <> ".ring-primary\\/20")

      render_click(view, "jump_to_answered_message", %{"message-id" => reply.id})
      assert present?(view, row(reply) <> ".bg-primary\\/5.ring-1.ring-primary\\/20")
    end

    test "the arrival ring's expiry still clears the highlight and drops the quote marker", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)
      view |> element(row(ans) <> ~s( button[data-role="reply-quote"])) |> render_click()
      assert :sys.get_state(view.pid).socket.assigns.quote_jump_message_id == reply.id

      send(view.pid, {:clear_anchor_highlight, reply.id})
      _ = render(view)
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.quote_jump_message_id == nil
      assert assigns.highlighted_message_id == nil
    end
  end

  describe "the excerpt clamp on every call site" do
    # The log row and the composer chip clamp to two lines; a display utility
    # beside `line-clamp-2` would override its `display: -webkit-box`.
    test "the log row's excerpt is clamped with no display utility beside it", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, String.duplicate("long reply text ", 40))
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)

      classes =
        view
        |> q(quote_of(ans) <> ~s( [data-role="reply-quote-preview"]))
        |> LazyHTML.attribute("class")
        |> List.first()
        |> String.split()

      assert "line-clamp-2" in classes

      assert Enum.filter(classes, &(&1 in PlatformWeb.Components.ReplyQuote.display_utilities())) ==
               []
    end
  end

  describe "the quoted message deleted" do
    test "Original message deleted, no jump button (M19)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")
      {:ok, _} = Chat.delete_message(reply)

      view = open_chat(conn, space)

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-deleted"])) =~
               "Original message deleted"

      assert present?(
               view,
               quote_of(ans) <> ~s( [data-role="reply-quote-deleted"].italic.text-subtle)
             )

      refute present?(view, row(ans) <> ~s( button[data-role="reply-quote"]))
      refute text(view, quote_of(ans)) =~ "When does it ship?"
    end

    test "the deleted state appears live on the open view (M19b)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      reply = member_reply(space, viewer, orig, "When does it ship?")
      _filler = post_msg(space, viewer, "filler")
      ans = answer(space, a, reply, "Monday.")

      view = open_chat(conn, space)
      assert present?(view, row(ans) <> ~s( button[data-role="reply-quote"]))

      {:ok, _} = Chat.delete_message(reply)

      refute present?(view, row(reply))

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-deleted"])) =~
               "Original message deleted"

      refute present?(view, row(ans) <> ~s( button[data-role="reply-quote"]))
    end
  end

  describe "a quote the viewer may not see" do
    test "a target in another space renders the no-access line and nothing of it", %{
      conn: conn,
      space: space,
      a: a
    } do
      {:ok, other} =
        Chat.create_space(%{
          name: "Other #{System.unique_integer([:positive])}",
          slug: "other-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, stranger} =
        Chat.add_participant(other.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Stranger",
          joined_at: DateTime.utc_now()
        })

      foreign = post_msg(other, stranger, "foreign-secret-text")
      ans = answer(space, a, foreign, "Answering elsewhere.")

      view = open_chat(conn, space)

      assert text(view, quote_of(ans) <> ~s( [data-role="reply-quote-no-access"])) =~
               "Replying to a message you don't have access to"

      refute present?(view, row(ans) <> ~s( button[data-role="reply-quote"]))
      refute render(view) =~ "foreign-secret-text"
    end
  end

  describe "threads" do
    test "thread reply rows have no reply-quote (M18)", %{
      conn: conn,
      space: space,
      viewer: viewer,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: orig.id})
      asked = post_msg(space, viewer, "asked inside the thread", %{thread_id: thread.id})

      _ans =
        post_msg(space, a, "Agent A echo: asked inside the thread", %{
          thread_id: thread.id,
          metadata: %{"reply_to_message_id" => asked.id}
        })

      view = open_chat(conn, space)
      view |> element(row(orig) <> ~s( [data-role="thread-chip"])) |> render_click()

      # Positive control: the thread is open with both rows in it.
      assert text(view, "#inline-thread-#{orig.id}") =~ "Agent A echo: asked inside the thread"
      refute present?(view, "#inline-thread-#{orig.id} [data-role=\"reply-quote\"]")
    end

    test "no thread-chip on the agent's original after a main-log exchange (M20)", %{
      conn: conn,
      space: space,
      a: a
    } do
      orig = post_msg(space, a, "The viewer fix is in review.")
      view = open_chat(conn, space)

      view |> element(row(orig) <> ~s( [data-role="message-pill-reply"])) |> render_click()
      view |> form("#compose-form", compose: %{text: "When does it ship?"}) |> render_submit()

      [reply] =
        space.id
        |> Chat.list_messages(top_level_only: true)
        |> Enum.filter(&(&1.content == "When does it ship?"))

      _ans = answer(space, a, reply, "Monday.")

      # Positive control: the exchange is in the log, quoted.
      assert present?(view, quote_of(reply))
      refute present?(view, row(orig) <> ~s( [data-role="thread-chip"]))
      refute present?(view, "#inline-thread-#{orig.id}")
    end
  end

  describe "the waiting state" do
    test "the typing indicator names the agent in the main log, with no placeholder bubble", %{
      conn: conn,
      space: space,
      a: a
    } do
      view = open_chat(conn, space)
      Platform.Chat.PubSub.broadcast_agent_typing(space.id, a.id, true)

      assert text(view, ~s(#chat-typing-indicator[data-typing="true"])) =~ "Agent A is thinking"
      refute present?(view, ~s([id^="streaming-"]))
    end
  end
end
