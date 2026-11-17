defmodule PlatformWeb.CalendarAgentDraftTest do
  @moduledoc """
  Calendar's scheduling language (task 01a1b8a5 stage 3), end to end over
  deterministic fixtures: the owner's words become ONE message in their DM
  with a granted agent; the agent's `calendar_draft` tool call (through
  `ToolArguments.dispatch/3`, as a runtime makes it) and its chat reply
  come back; Review draft opens the SAME Calendar editor; the owner's one
  explicit Create event is the only write.

  The agent is a fixture: these tests stand in for the runtime by calling
  the real tool and posting as the agent's real DM participant. Nothing in
  the product path is faked.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.{RuntimeProfile, RuntimeProfiles, Scope}
  alias Platform.Calendar.{AgentAccess, Consent, Draft, Event}
  alias Platform.Federation.{RuntimePresence, ToolArguments}
  alias Platform.Meetings.{Invite, Meeting}
  alias Platform.Repo

  @zone "America/Chicago"
  @editor "#calendar-editor"
  @form "#calendar-event-form"

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup do
    keys = [:meetings_enabled, :inbox_module, :notifications_module]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}
    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :inbox_module, Quiet)
    Application.put_env(:platform, :notifications_module, Quiet)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.acme_org_id()
    owner = member!(org_id, "Owner #{n}")

    agent =
      Repo.insert!(%Platform.Agents.Agent{name: "Scheduler #{n}", slug: "cal-draft-live-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "cal-draft-live-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Scheduler"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions: RuntimeProfiles.translated_permissions(["context_read"])
    })

    %{n: n, org_id: org_id, owner: owner, agent: agent, runtime: runtime}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "cal-draft-#{n}@example.com",
        name: name,
        oidc_sub: "cal-draft-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    user
  end

  defp project!(ctx) do
    Repo.insert!(%Platform.Tasks.Project{
      name: "Draft project #{ctx.n}",
      slug: "draft-live-project-#{ctx.n}",
      org_id: ctx.org_id
    })
  end

  defp grant!(ctx) do
    {:ok, _} =
      AgentAccess.grant(Scope.for_user(ctx.owner), ctx.agent.id, %{read: true, create: true})

    :ok
  end

  defp online!(ctx) do
    RuntimePresence.track(ctx.runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(ctx.runtime.runtime_id) end)
  end

  defp conn_for(user) do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => @zone})
  end

  defp open!(user, path \\ "/calendar") do
    {:ok, view, _} = live(conn_for(user), path)
    view
  end

  defp counts,
    do: %{
      events: Repo.aggregate(Event, :count),
      meetings: Repo.aggregate(Meeting, :count),
      invites: Repo.aggregate(Invite, :count),
      consents: Repo.aggregate(Consent, :count),
      mail: Repo.aggregate(Platform.Mail.Delivery, :count)
    }

  defp ask!(view, text) do
    view |> form("#quick-plan-form", plan: %{text: text}) |> render_submit()
  end

  # The request message Calendar sent, as the agent receives it.
  defp request!(ctx) do
    import Ecto.Query

    Repo.one!(
      from(m in Platform.Chat.Message,
        where: fragment("?->>'source' = 'calendar_draft_request'", m.metadata),
        where: fragment("?->>'owner_id' = ?", m.metadata, ^ctx.owner.id),
        order_by: [desc: m.inserted_at],
        limit: 1
      )
    )
  end

  # The agent's side: the real tool through the real argument gate, with
  # the runtime context a connected runtime carries.
  defp tool!(ctx, request, extra) do
    args =
      Map.merge(
        %{
          "owner_id" => request.metadata["owner_id"],
          "request_key" => request.metadata["request_key"],
          "time_zone" => request.metadata["time_zone"]
        },
        extra
      )

    ToolArguments.dispatch("calendar_draft", args, %{
      runtime_id: ctx.runtime.runtime_id,
      agent_id: ctx.agent.id
    })
  end

  defp reply!(ctx, request, content) do
    participant = Platform.Chat.get_agent_participant(request.space_id, ctx.agent.id)

    {:ok, _} =
      Platform.Chat.post_message(%{
        space_id: request.space_id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })
  end

  # ── the v7 entry ────────────────────────────────────────────────────────

  describe "the #quick-plan entry" do
    test "renders the inventory copy and, with no granted agent, says where to grant one",
         ctx do
      view = open!(ctx.owner)

      assert has_element?(view, "#quick-plan", "Describe what you want to schedule")

      assert has_element?(
               view,
               "#quick-plan input[data-role=quick-plan-text][placeholder='Meet Friday at 2pm with Alex and Sam'][disabled]"
             )

      assert has_element?(
               view,
               "#quick-plan button[data-role=quick-plan-submit][disabled]",
               "Draft event"
             )

      assert has_element?(
               view,
               "#quick-plan [data-role=quick-plan-empty] a[href='/calendar/settings']",
               "Calendar settings"
             )

      # No browser parser, no demo helper.
      html = render(view)
      refute html =~ "Demo parser"
      refute html =~ "data-demo"
    end

    test "with a granted agent the entry is live and names who drafts", ctx do
      grant!(ctx)
      view = open!(ctx.owner)

      refute has_element?(view, "#quick-plan input[data-role=quick-plan-text][disabled]")

      assert has_element?(
               view,
               "#quick-plan [data-role=quick-plan-agent-note]",
               "#{ctx.agent.name} drafts it; nothing is saved until you choose Create event."
             )
    end
  end

  # ── agent message -> tool draft -> same editor -> one explicit save ─────

  describe "a resolved request" do
    test "one DM message, the tool's draft, the same editor, one save", ctx do
      grant!(ctx)
      online!(ctx)
      project = project!(ctx)
      guest = member!(ctx.org_id, "Marlow#{ctx.n} Ashby")
      view = open!(ctx.owner)
      before = counts()

      ask!(view, "Design review Friday Dec 4 at 2pm with Marlow#{ctx.n} Ashby")

      assert has_element?(
               view,
               "[data-role=quick-plan-waiting]",
               "Sent to #{ctx.agent.name}. Waiting for a reply…"
             )

      request = request!(ctx)
      assert request.content =~ "Design review Friday Dec 4 at 2pm"
      assert request.content =~ "time_zone #{@zone}"
      assert %{kind: "dm"} = Repo.get!(Platform.Chat.Space, request.space_id)

      assert {:ok, %{status: "ready", url: url}} =
               tool!(ctx, request, %{
                 "title" => "Design review",
                 "start" => "2026-12-04T14:00:00",
                 "end" => "2026-12-04T15:00:00",
                 "attendees" => [%{"user_id" => guest.id}],
                 "call_enabled" => true,
                 "project_id" => project.id
               })

      reply!(ctx, request, "Drafted it for you: #{url}")

      assert has_element?(view, "[data-role=quick-plan-reply]", "Drafted it for you")
      assert has_element?(view, "[data-role=quick-plan-draft][data-draft-status=ready]")

      # Nothing is written by asking, by the tool or by the reply.
      assert counts() == before

      view |> element("[data-role=quick-plan-review]") |> render_click()

      # The ONE editor, as New event, prefilled with the resolved fields.
      assert has_element?(view, "#{@editor}[data-source=agent] h2.editor-heading", "New event")
      assert has_element?(view, "#{@editor} input[data-role=f-title][value='Design review']")
      assert has_element?(view, "#{@editor} input[data-role=f-date][value='2026-12-04']")
      assert has_element?(view, "#{@editor} input[data-role=f-s][value='2:00 PM']")
      assert has_element?(view, "#{@editor} input[data-role=f-e][value='3:00 PM']")
      assert has_element?(view, "#{@editor} [data-role=f-people]", guest.name)
      assert has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      assert has_element?(view, "#{@editor} [data-role=calendar-editor-agent]", ctx.agent.name)
      assert has_element?(view, "#{@editor} button[data-role=f-save]", "Create event")
      refute has_element?(view, "#{@editor} button[data-role=f-save][disabled]")
      assert counts() == before

      # Edit, then the one explicit save.
      view |> form(@form, event: %{title: "Design review, edited"}) |> render_change()
      view |> form(@form, event: %{title: "Design review, edited"}) |> render_submit()

      refute has_element?(view, @editor)
      after_save = counts()
      assert after_save.events == before.events + 1
      assert after_save.meetings == before.meetings + 1
      assert after_save.consents == before.consents

      [event] = Repo.all(Event)
      assert event.title == "Design review, edited"
      assert event.starts_at == ~U[2026-12-04 20:00:00.000000Z]
      assert event.tentative == false

      assert [%Invite{user_id: invited}] =
               Repo.all(Invite) |> Enum.filter(&(&1.meeting_id == event.meeting_id))

      assert invited == guest.id

      "/calendar?draft=" <> token = url
      assert %Draft{event_id: event_id, saved_at: %DateTime{}} = Repo.get_by!(Draft, token: token)
      assert event_id == event.id

      # The same link again: refused, still one event.
      view = open!(ctx.owner, url)
      refute has_element?(view, @editor)
      assert render(view) =~ "This draft was already saved."
      assert counts().events == after_save.events
    end

    test "a retried tool delivery leaves one draft and one link", ctx do
      grant!(ctx)
      online!(ctx)
      view = open!(ctx.owner)
      ask!(view, "Focus block tomorrow morning")
      request = request!(ctx)

      fields = %{
        "title" => "Focus",
        "category" => "focus",
        "start" => "2026-11-09T09:00:00",
        "end" => "2026-11-09T11:00:00"
      }

      assert {:ok, %{url: url}} = tool!(ctx, request, fields)
      assert {:ok, %{url: ^url}} = tool!(ctx, request, fields)
      assert Repo.aggregate(Draft, :count) == 1

      view |> element("[data-role=quick-plan-review]") |> render_click()

      assert has_element?(
               view,
               "#{@editor} select[data-role=f-type] option[value=focus][selected]"
             )
    end
  end

  # ── clarification, never a silent choice ───────────────────────────────

  describe "ambiguity" do
    test "two people sharing a name: asked, Save disabled, refused until answered", ctx do
      grant!(ctx)
      online!(ctx)
      project!(ctx)
      first = member!(ctx.org_id, "Rowan#{ctx.n} Ashby")
      _second = member!(ctx.org_id, "Rowan#{ctx.n} Colt")
      view = open!(ctx.owner)
      ask!(view, "Friday at 2 with Rowan#{ctx.n}")
      request = request!(ctx)

      assert {:ok, %{status: "needs_clarification", url: url, clarifications: [_]}} =
               tool!(ctx, request, %{
                 "title" => "Catch up",
                 "start" => "2026-12-04T14:00:00",
                 "end" => "2026-12-04T14:30:00",
                 "attendees" => [%{"name" => "Rowan#{ctx.n}"}]
               })

      reply!(ctx, request, "Two people are called Rowan#{ctx.n}. Which one?")

      assert has_element?(
               view,
               "[data-role=quick-plan-draft][data-draft-status=needs_clarification]",
               "needs your answer"
             )

      assert has_element?(view, "[data-role=quick-plan-reply]", "Which one?")

      # The link opens it too (the agent's reply carries it).
      view = open!(ctx.owner, url)
      before = counts()

      assert has_element?(
               view,
               "#{@editor} [data-role=calendar-editor-agent-question][data-kind=attendee]",
               "2 people match Rowan#{ctx.n}"
             )

      assert has_element?(view, "#{@editor} button[data-role=f-save][disabled]")
      refute has_element?(view, "#{@editor} [data-role=f-people]", "Rowan#{ctx.n} Ashby ")

      # A forced submit is refused in words and writes nothing.
      view |> form(@form, event: %{}) |> render_submit()

      assert has_element?(
               view,
               "#{@editor} [data-role=f-err]",
               "Answer the question above before saving."
             )

      assert counts() == before

      view
      |> element(
        "#{@editor} button[data-role=calendar-editor-agent-candidate][phx-value-choice='#{first.id}']"
      )
      |> render_click()

      assert has_element?(view, "#{@editor} [data-answered=true]", "Answered.")
      refute has_element?(view, "#{@editor} button[data-role=f-save][disabled]")

      view |> form(@form, event: %{}) |> render_submit()
      refute has_element?(view, @editor)
      assert counts().events == before.events + 1

      [event] = Repo.all(Event)

      assert [%Invite{user_id: invited}] =
               Repo.all(Invite) |> Enum.filter(&(&1.meeting_id == event.meeting_id))

      assert invited == first.id
    end

    test "a local time the clocks repeat: asked, no time kept, the editor refuses it", ctx do
      grant!(ctx)
      online!(ctx)
      view = open!(ctx.owner)
      ask!(view, "Night shift handoff Nov 1 at 1:30am")
      request = request!(ctx)

      assert {:ok, %{status: "needs_clarification"}} =
               tool!(ctx, request, %{
                 "title" => "Handoff",
                 "start" => "2026-11-01T01:30:00",
                 "end" => "2026-11-01T03:00:00"
               })

      view |> element("[data-role=quick-plan-review]") |> render_click()

      assert has_element?(
               view,
               "#{@editor} [data-role=calendar-editor-agent-question][data-kind=time]",
               "1:30 AM happens twice"
             )

      assert has_element?(view, "#{@editor} input[data-role=f-date][value='2026-11-01']")
      assert has_element?(view, "#{@editor} input[data-role=f-s][value='']")
      before = counts()

      view |> form(@form, event: %{}) |> render_submit()
      assert has_element?(view, "#{@editor} [data-role=f-err]", "Pick a date, start and end.")

      # Typing the repeated time itself is still refused, not picked.
      view |> form(@form, event: %{start: "1:30 AM"}) |> render_submit()
      assert has_element?(view, @editor)
      assert counts() == before

      view |> form(@form, event: %{start: "3:30 AM", end: "4:00 AM"}) |> render_submit()
      refute has_element?(view, @editor)
      assert counts().events == before.events + 1
    end
  end

  # ── who can open a link ─────────────────────────────────────────────────

  describe "links" do
    setup ctx do
      grant!(ctx)
      online!(ctx)

      {:ok, draft, :created} =
        Draft.create(Scope.for_runtime(ctx.runtime), ctx.owner.id, %{
          "request_key" => "link-1",
          "time_zone" => @zone,
          "title" => "Private",
          "start" => "2026-12-04T09:00:00",
          "end" => "2026-12-04T10:00:00"
        })

      %{draft: draft}
    end

    test "a stolen link opens nothing for anyone else", ctx do
      stranger = member!(ctx.org_id, "Stranger #{ctx.n}")
      view = open!(stranger, Draft.url(ctx.draft))

      refute has_element?(view, @editor)
      assert render(view) =~ "This draft link isn&#39;t available to you."
      refute render(view) =~ "Private"
    end

    test "an expired link opens nothing for its owner either", ctx do
      ctx.draft
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      view = open!(ctx.owner, Draft.url(ctx.draft))
      refute has_element?(view, @editor)
      assert render(view) =~ "This draft has expired."
    end

    test "its owner gets the editor on the draft's day", ctx do
      view = open!(ctx.owner, Draft.url(ctx.draft))
      assert has_element?(view, "#{@editor}[data-source=agent] input[value='Private']")
    end
  end

  # ── the agent is not there ──────────────────────────────────────────────

  describe "outage" do
    test "an offline agent gets nothing; the manual editor still saves", ctx do
      grant!(ctx)
      view = open!(ctx.owner)
      messages = Repo.aggregate(Platform.Chat.Message, :count)

      ask!(view, "Lunch Friday")

      assert has_element?(
               view,
               "[data-role=quick-plan-unavailable]",
               "#{ctx.agent.name} isn't connected right now, so nothing was sent."
             )

      assert Repo.aggregate(Platform.Chat.Message, :count) == messages

      view |> element("#calendar-new") |> render_click()
      assert has_element?(view, @editor)

      view
      |> form(@form,
        event: %{title: "Lunch", date: "2026-12-04", start: "12:00 PM", end: "1:00 PM"}
      )
      |> render_submit()

      refute has_element?(view, @editor)
      assert [%Event{title: "Lunch"}] = Repo.all(Event)
    end

    test "an agent that never answers turns into a useful waiting state", ctx do
      grant!(ctx)
      online!(ctx)
      view = open!(ctx.owner)
      ask!(view, "Lunch Friday")
      key = request!(ctx).metadata["request_key"]

      send(view.pid, {:plan_slow, key})

      assert has_element?(
               view,
               "[data-role=quick-plan-slow]",
               "hasn't replied yet. You can keep waiting, or add the event yourself with + New."
             )

      view |> element("[data-role=quick-plan-reset]") |> render_click()
      refute has_element?(view, "[data-role=quick-plan-state]")
    end

    test "a reply the shell also delivers shows once", ctx do
      grant!(ctx)
      online!(ctx)
      view = open!(ctx.owner)
      ask!(view, "Lunch Friday")
      request = request!(ctx)
      reply!(ctx, request, "Which Friday?")

      [message] =
        Repo.all(Platform.Chat.Message)
        |> Enum.filter(&(&1.space_id == request.space_id and &1.content == "Which Friday?"))

      send(view.pid, {:new_message, message})
      assert view |> render() |> String.split("Which Friday?") |> length() == 2
    end

    test "a blank request sends nothing and says why", ctx do
      grant!(ctx)
      online!(ctx)
      view = open!(ctx.owner)
      messages = Repo.aggregate(Platform.Chat.Message, :count)

      ask!(view, "   ")

      assert has_element?(
               view,
               "[data-role=quick-plan-failed]",
               "Describe what you want to schedule first."
             )

      assert Repo.aggregate(Platform.Chat.Message, :count) == messages
    end
  end
end
