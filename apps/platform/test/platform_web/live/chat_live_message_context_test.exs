defmodule PlatformWeb.ChatLiveMessageContextTest do
  @moduledoc """
  The "Context" affordance on agent messages in `ChatLive` (task 01a0d8de
  stage 3): the header trigger, the panel it opens (popover on desktop,
  sheet on mobile), the answered message's row, "Jump to message", and the
  generated-summary fallback through the stage-1 stub provider.

  Negatives are paired with a positive control in the same test where the
  failure mode would otherwise read as "the mechanism is not installed":
  the escape test asserts the sentinel text IS shown before asserting it
  is not markup; the no-access cases open a visible target first; the
  mobile case asserts the desktop frame renders when the viewport is wide.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Test.ChatContextSummaryStub

  # `@message_limit` in messages_hooks.ex: the default window size.
  @message_limit 50

  @script_context "<script>window.__ctx_pwned = 1</script> sentinel-context-line"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "context_#{n}@example.com",
        name: "Context Tester",
        oidc_sub: "oidc-context-#{n}",
        avatar_url: nil
      })

    {:ok, space} =
      Chat.create_space(%{name: "Context #{n}", slug: "context-#{n}", kind: "channel"})

    {:ok, viewer} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    asker = add_user_participant(space, "asker")
    agent = add_agent_participant(space, "Octavius #{n}")

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     space: space,
     viewer: viewer,
     asker: asker,
     agent: agent}
  end

  defp add_user_participant(space, label) do
    n = System.unique_integer([:positive])

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "#{label}-#{n}",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp add_agent_participant(space, name) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "context-agent-#{n}",
        name: name,
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp post_msg(space, participant, content, metadata \\ %{}) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content,
        metadata: metadata
      })

    msg
  end

  defp seed_filler(space, participant, count) do
    for i <- 1..count, do: post_msg(space, participant, "filler-#{i}")
  end

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  # The header "Context" button is gone (redesign rung 9): the panel opens
  # from the message-actions sheet, which the pill's More button opens.
  defp open_context(view, msg) do
    view
    |> element(
      ~s([data-message-id="#{msg.id}"] [data-role="message-pill"] button[aria-label="More actions"])
    )
    |> render_click()

    view
    |> element(~s(#message-actions-sheet [data-role="message-actions-context"]))
    |> render_click()
  end

  defp popover(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.query("#message-context-popover")

  defp text_of(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp anchor_assign(view), do: :sys.get_state(view.pid).socket.assigns.anchor_message_id

  # The summary arrives from a Task.Supervisor child by message; poll the
  # rendered view until it shows, bounded.
  defp eventually_render(view, fun, tries \\ 50) do
    html = render(view)

    cond do
      fun.(html) ->
        html

      tries == 0 ->
        flunk("condition never held; last render:\n" <> html)

      true ->
        Process.sleep(20)
        eventually_render(view, fun, tries - 1)
    end
  end

  describe "the panel for an agent message with context" do
    test "shows the agent's context as text, never as markup", %{
      conn: conn,
      space: space,
      asker: asker,
      agent: agent
    } do
      q = post_msg(space, asker, "Which tasks still need me today?")

      a =
        post_msg(space, agent, "you need to take action on 6", %{
          "reply_to_message_id" => q.id,
          "reply_context" => @script_context
        })

      view = open_chat(conn, space)
      html = open_context(view, a)

      # Positive control: the popover opened.
      assert popover(html) |> Enum.count() == 1

      # The context is escaped: no live script element anywhere in the page,
      # and the escaped form is what was rendered.
      refute html =~ "<script>window.__ctx_pwned"
      assert html =~ "&lt;script&gt;window.__ctx_pwned"

      # And a reader sees the sentinel as literal text.
      text = text_of(html, "#message-context-popover [data-role=\"message-context-agent-text\"]")
      assert text =~ "<script>window.__ctx_pwned = 1</script> sentinel-context-line"

      # The re-skinned panel (redesign rung 9 stage 2): titled 'Answering',
      # led by "<agent> was answering:" with the name in the agent's accent,
      # the context labelled 'agent context', and the full text with no
      # "Show more" clamp.
      assert text_of(html, "#message-context-popover-title") =~ "Answering"
      refute text_of(html, "#message-context-popover") =~ "What this message is answering"

      assert text_of(html, ~s(#message-context-popover [data-role="message-context-lead"])) =~
               ~r/#{agent.display_name}\s+was answering:/

      assert has_element?(
               view,
               ~s(#message-context-popover [data-role="message-context-agent-name"].message-context-agent-name[data-agent-slot])
             )

      assert text_of(html, "#message-context-popover") =~ "agent context"
      refute html =~ "Show more"
      refute html =~ "line-clamp-2\" id=\"message-context"
      assert text_of(html, "#message-context-popover") =~ "Jump to message"
      assert text_of(html, "#message-context-popover") =~ "Retry summary"

      # The answered message's author and preview, and the jump control.
      assert text_of(
               html,
               ~s(#message-context-popover [data-role="message-context-reply-preview"])
             ) =~
               "Which tasks still need me today?"

      assert text_of(
               html,
               ~s(#message-context-popover [data-role="message-context-reply-author"])
             ) =~
               asker.display_name

      assert html =~ ~s(data-role="message-context-jump")
      refute html =~ ~s(data-role="message-context-reply-no-access")
      # Context was supplied, so nothing was generated.
      refute html =~ ~s(data-role="message-context-generated")
    end

    test "Escape and the close button both close it", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      a = post_msg(space, agent, "reply", %{"reply_context" => "the stage-4 approval"})
      view = open_chat(conn, space)

      open_context(view, a)
      assert has_element?(view, "#message-context-popover")

      view
      |> element("#message-context-popover")
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#message-context-popover")

      open_context(view, a)
      view |> element(~s(#message-context-popover button[aria-label="Close"])) |> render_click()
      refute has_element?(view, "#message-context-popover")
    end

    test "Jump to message patches to ?message= and anchors a target outside the loaded window",
         %{conn: conn, space: space, asker: asker, agent: agent} do
      q = post_msg(space, asker, "the-early-question")
      seed_filler(space, asker, @message_limit + 20)
      a = post_msg(space, agent, "answer", %{"reply_to_message_id" => q.id})

      view = open_chat(conn, space)

      # Baseline: the question is outside the default window.
      refute has_element?(view, ~s([data-message-id="#{q.id}"]))

      open_context(view, a)

      view
      |> element(~s(#message-context-popover [data-role="message-context-jump"]))
      |> render_click()

      assert_patch(view, "/chat/#{space.slug}?message=#{q.id}")
      assert_push_event(view, "chat:message-jump", %{id: jumped})
      assert jumped == q.id

      assert anchor_assign(view) == q.id
      assert has_element?(view, ~s([data-message-id="#{q.id}"]))
      # The panel closed on the jump.
      refute has_element?(view, "#message-context-popover")
    end
  end

  describe "an answered message the viewer may not see" do
    test "renders the no-access line for another space and one before the grant, and the deleted line for a deleted target",
         %{conn: conn, space: space, viewer: viewer, asker: asker, agent: agent} do
      visible = post_msg(space, asker, "visible-question")
      early = post_msg(space, asker, "before-the-grant")

      {:ok, other} =
        Chat.create_space(%{
          name: "Other #{System.unique_integer([:positive])}",
          slug: "other-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      other_asker = add_user_participant(other, "elsewhere")
      foreign = post_msg(other, other_asker, "foreign-secret-text")

      deleted =
        space
        |> post_msg(asker, "deleted-question")
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

      # Grant starts after `early` and before `visible`'s agent reply.
      viewer
      |> Ecto.Changeset.change(
        history_visible_from: DateTime.add(early.inserted_at, 1, :microsecond)
      )
      |> Repo.update!()

      # `visible` was posted before `early`, so it is before the grant too;
      # repost a visible target after the grant.
      after_grant = post_msg(space, asker, "after-grant-question")

      replies =
        for {target, i} <- Enum.with_index([after_grant, foreign, deleted, early, visible]) do
          # The reply's own content must not echo the target's, or the
          # page-wide refute below would match the reply row, not a leak.
          {target,
           post_msg(space, agent, "agent reply #{i}", %{"reply_to_message_id" => target.id})}
        end

      view = open_chat(conn, space)

      [{_, ok_reply} | denied] = replies

      # Positive control: a target inside every bound renders its row.
      html = open_context(view, ok_reply)

      assert text_of(
               html,
               ~s(#message-context-popover [data-role="message-context-reply-preview"])
             ) =~
               "after-grant-question"

      refute html =~ ~s(data-role="message-context-reply-no-access")

      for {target, reply} <- denied do
        html = open_context(view, reply)

        # A deleted target the viewer could otherwise see has its own state
        # since task 01a174f5 stage 3 (`QuotedMessage`): it says so, and
        # still shows nothing of the message.
        {role, words} =
          if target.id == deleted.id,
            do: {"message-context-reply-deleted", "Original message deleted"},
            else:
              {"message-context-reply-no-access",
               "Replying to a message you don't have access to"}

        assert text_of(html, ~s(#message-context-popover [data-role="#{role}"])) =~ words,
               "expected #{role} for #{target.content}"

        refute html =~ ~s(data-role="message-context-jump")
        refute text_of(html, "#message-context-popover") =~ target.content
      end

      # The foreign message's text never reached the page at all.
      refute render(view) =~ "foreign-secret-text"
    end

    test "Jump refuses a target outside the active space", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      {:ok, other} =
        Chat.create_space(%{
          name: "Other #{System.unique_integer([:positive])}",
          slug: "other-j-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      foreign = post_msg(other, add_user_participant(other, "x"), "foreign")
      a = post_msg(space, agent, "reply", %{"reply_context" => "ctx"})

      view = open_chat(conn, space)
      open_context(view, a)

      render_click(view, "jump_to_answered_message", %{"message-id" => foreign.id})
      refute_push_event(view, "chat:message-jump", %{id: _})
      assert has_element?(view, "#message-context-popover")
    end
  end

  describe "the generated-summary fallback" do
    test "an agent message without context offers Summarise and shows the generated summary",
         %{conn: conn, space: space, asker: asker, agent: agent} do
      ChatContextSummaryStub.install!(
        ChatContextSummaryStub.text("The asker wants the task list.")
      )

      t1 = post_msg(space, asker, "top-level-one")
      t2 = post_msg(space, asker, "top-level-two")
      r = post_msg(space, agent, "plain agent reply")

      view = open_chat(conn, space)

      # No header marker on any message; the actions sheet has the entry.
      refute has_element?(view, ~s([data-context-message-id="#{r.id}"]))

      open_context(view, r)

      assert_receive {:context_summary_stub_called, _creds, _messages, _opts}, 2_000

      html =
        eventually_render(view, &(&1 =~ ~s(data-role="message-context-summary")))

      assert text_of(html, "#message-context-popover") =~ "Generated summary"

      assert text_of(html, ~s(#message-context-popover [data-role="message-context-summary"])) =~
               "The asker wants the task list."

      assert text_of(html, "#message-context-popover") =~
               "Summarised by Burrow from the messages before this one that you can see."

      [ids] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s(#message-context-popover [data-role="message-context-summary"]))
        |> LazyHTML.attribute("data-source-message-ids")

      assert String.split(ids, ",") |> MapSet.new() == MapSet.new([t1.id, t2.id])
    end

    test "a provider error shows Retry, and Retry regenerates", %{
      conn: conn,
      space: space,
      asker: asker,
      agent: agent
    } do
      ChatContextSummaryStub.install!(fn _c, _m, _o -> {:error, :boom} end)

      post_msg(space, asker, "some-earlier-message")
      r = post_msg(space, agent, "plain agent reply")

      view = open_chat(conn, space)
      render_click(view, "summarise_message_context", %{"message-id" => r.id})
      assert_receive {:context_summary_stub_called, _, _, _}, 2_000

      html = eventually_render(view, &(&1 =~ ~s(data-role="message-context-retry")))
      assert text_of(html, "#message-context-popover") =~ "The summary could not be generated."
      refute html =~ ~s(data-role="message-context-summary")
      refute html =~ ~s(data-role="message-context-summary-source")

      ChatContextSummaryStub.reply!(ChatContextSummaryStub.text("Second try worked."))

      view
      |> element(~s(#message-context-popover [data-role="message-context-retry"]))
      |> render_click()

      assert_receive {:context_summary_stub_called, _, _, _}, 2_000
      html = eventually_render(view, &(&1 =~ "Second try worked."))
      refute html =~ ~s(data-role="message-context-summary-error")
      # 'Retry summary' is one of the panel's two standing buttons (the
      # masters' 'Answering' stub), so it is offered again after a success.
      assert has_element?(view, ~s(#message-context-popover [data-role="message-context-retry"]))
    end

    test "with no provider configured, it says summaries are unavailable", %{
      conn: conn,
      space: space,
      asker: asker,
      agent: agent
    } do
      post_msg(space, asker, "earlier")
      r = post_msg(space, agent, "plain agent reply")

      view = open_chat(conn, space)
      render_click(view, "summarise_message_context", %{"message-id" => r.id})

      html = eventually_render(view, &(&1 =~ ~s(data-role="message-context-summary-unavailable")))
      assert text_of(html, "#message-context-popover") =~ "Summaries are not available"
      refute html =~ ~s(data-role="message-context-retry")
    end

    test "a human message cannot be summarised", %{conn: conn, space: space, asker: asker} do
      h = post_msg(space, asker, "a human line")
      view = open_chat(conn, space)

      render_click(view, "open_message_actions", %{"id" => h.id})
      refute has_element?(view, ~s(#message-actions-sheet [data-role="message-actions-context"]))
      render_click(view, "close_message_actions", %{})

      render_click(view, "summarise_message_context", %{"message-id" => h.id})
      refute has_element?(view, "#message-context-popover")
    end
  end

  describe "frames" do
    test "desktop renders the popover and never the sheet; mobile the sheet and never the popover",
         %{conn: conn, space: space, agent: agent} do
      a = post_msg(space, agent, "reply", %{"reply_context" => "the mobile case"})
      view = open_chat(conn, space)

      open_context(view, a)
      assert has_element?(view, "#message-context-popover")
      refute has_element?(view, "#message-context-sheet")

      render_click(view, "close_message_context", %{})
      render_hook(view, "message_context_viewport", %{"below" => true})

      html = open_context(view, a)
      assert has_element?(view, "#message-context-sheet")
      # Swipe-dismissable, with the handle Close button and a visible title.
      assert has_element?(view, ~s(#message-context-sheet[data-swipe-dismiss="true"]))
      assert has_element?(view, "#message-context-sheet .sheet-handle-button")
      assert text_of(html, ~s(#message-context-sheet p[aria-hidden="true"])) =~ "Answering"
      refute has_element?(view, "#message-context-popover")

      assert text_of(html, ~s(#message-context-sheet [data-role="message-context-agent-text"])) =~
               "the mobile case"

      # A malformed report is ignored rather than coerced.
      render_hook(view, "message_context_viewport", %{"below" => "no"})
      assert has_element?(view, "#message-context-sheet")
    end

    test "the actions sheet's first row opens the panel for agent messages only", %{
      conn: conn,
      space: space,
      asker: asker,
      agent: agent
    } do
      a = post_msg(space, agent, "reply", %{"reply_context" => "from the sheet"})
      h = post_msg(space, asker, "human line")
      view = open_chat(conn, space)

      render_click(view, "open_message_actions", %{"id" => h.id})
      refute has_element?(view, ~s([data-role="message-actions-context"]))
      render_click(view, "close_message_actions", %{})

      render_click(view, "open_message_actions", %{"id" => a.id})
      # One row in each frame of the one assign: the phone sheet and the
      # desktop popover.
      assert has_element?(view, ~s(#message-actions-sheet [data-role="message-actions-context"]))

      assert has_element?(
               view,
               ~s(#message-actions-popover [data-role="message-actions-context"])
             )

      view
      |> element(~s(#message-actions-sheet [data-role="message-actions-context"]))
      |> render_click()

      # Exactly one sheet open: the actions surface closed (both frames)
      # before the context panel opened.
      refute has_element?(view, "#message-actions-sheet")
      refute has_element?(view, "#message-actions-popover")

      assert render(view)
             |> text_of(~s(#message-context-popover [data-role="message-context-agent-text"])) =~
               "from the sheet"
    end
  end
end
