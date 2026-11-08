defmodule Platform.Calendar.DraftTest do
  @moduledoc """
  The write-free agent draft (task 01a1b8a5 stage 3): authorization,
  owner scoping, expiry, idempotency, the clarification rules and the one
  explicit save through `Authoring.save/4`.

  "Writes nothing" is asserted as row counts of every store an event, a
  call, an invitation, a hold or a consent could land in.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Access.{RuntimeProfile, RuntimeProfiles, Scope}
  alias Platform.Calendar.{AgentAccess, Authoring, Consent, Draft, Event}
  alias Platform.Meetings.{Invite, Meeting}
  alias Platform.Memory.Briefing

  @zone "America/Chicago"

  setup do
    n = System.unique_integer([:positive])
    org = Platform.Tenancy.get_org_by_slug!("globex")
    user = Platform.ExternalUserFixtures.create_user!(%{name: "Draft owner #{n}"})
    Platform.ExternalUserFixtures.plain_member!(user, org)

    agent =
      Repo.insert!(%Platform.Agents.Agent{name: "Scheduler #{n}", slug: "calendar-draft-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "calendar-draft-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Scheduler"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions: RuntimeProfiles.translated_permissions(["context_read"])
    })

    %{
      n: n,
      org: org,
      user: user,
      owner: Scope.for_user(user),
      agent: agent,
      runtime: runtime,
      scope: Scope.for_runtime(runtime)
    }
  end

  defp grant!(ctx, extra \\ %{}) do
    {:ok, grant} =
      AgentAccess.grant(ctx.owner, ctx.agent.id, Map.merge(%{read: true, create: true}, extra))

    grant
  end

  defp member!(ctx, name) do
    user =
      Platform.ExternalUserFixtures.create_user!(%{
        name: name,
        email: "#{String.downcase(String.replace(name, " ", "."))}@example.com"
      })

    Platform.ExternalUserFixtures.plain_member!(user, ctx.org)
    user
  end

  defp project!(ctx) do
    Repo.insert!(%Platform.Tasks.Project{
      name: "Draft project #{ctx.n}",
      slug: "draft-project-#{ctx.n}",
      org_id: ctx.org.id
    })
  end

  defp args(extra \\ %{}) do
    Map.merge(
      %{
        "request_key" => "req-1",
        "time_zone" => @zone,
        "title" => "Design review",
        "start" => "2026-12-04T14:00:00",
        "end" => "2026-12-04T15:00:00"
      },
      extra
    )
  end

  defp create(ctx, extra \\ %{}), do: Draft.create(ctx.scope, ctx.user.id, args(extra))

  defp counts,
    do: %{
      events: Repo.aggregate(Event, :count),
      meetings: Repo.aggregate(Meeting, :count),
      invites: Repo.aggregate(Invite, :count),
      consents: Repo.aggregate(Consent, :count),
      briefings: Repo.aggregate(Briefing, :count),
      inbox: Repo.aggregate(Platform.Inbox.Item, :count),
      mail: Repo.aggregate(Platform.Mail.Delivery, :count)
    }

  describe "authorization" do
    test "no grant, a revoked grant, no create, an inactive runtime or another owner: forbidden",
         ctx do
      before = counts()
      assert {:error, :forbidden} = create(ctx)

      grant!(ctx, %{create: false})
      assert {:error, :forbidden} = create(ctx)

      grant!(ctx)
      {:ok, _} = AgentAccess.revoke(ctx.owner, ctx.agent.id)
      assert {:error, :forbidden} = create(ctx)

      grant!(ctx)
      other = Platform.ExternalUserFixtures.create_user!()
      Platform.ExternalUserFixtures.plain_member!(other, ctx.org)
      assert {:error, :forbidden} = Draft.create(ctx.scope, other.id, args())
      assert {:error, :forbidden} = Draft.create(ctx.scope, "not-a-uuid", args())

      ctx.runtime |> Ecto.Changeset.change(status: "revoked") |> Repo.update!()
      assert {:error, :forbidden} = create(ctx)

      # A user scope is not a runtime.
      assert {:error, :forbidden} = Draft.create(ctx.owner, ctx.user.id, args())

      assert Repo.aggregate(Draft, :count) == 0
      assert counts() == before
    end
  end

  describe "a draft writes nothing but itself" do
    test "a resolved draft: no event, meeting, invite, hold, consent, briefing, inbox or mail",
         ctx do
      grant!(ctx)
      guest = member!(ctx, "Quill #{ctx.n} Ashby")
      project = project!(ctx)
      before = counts()

      assert {:ok, draft, :created} =
               create(ctx, %{
                 "attendees" => [%{"user_id" => guest.id}, %{"email" => "visitor@example.org"}],
                 "notes" => "Bring the mockups",
                 "project_id" => project.id
               })

      assert counts() == before
      assert Repo.aggregate(Draft, :count) == 1
      assert draft.issues == []
      assert draft.clarifications == []
      assert Draft.status(draft) == "ready"

      # 14:00 in Chicago on Dec 4 is CST, UTC-6.
      assert draft.attrs["starts_at"] == "2026-12-04T20:00:00Z"
      assert draft.attrs["ends_at"] == "2026-12-04T21:00:00Z"
      assert draft.attrs["date"] == "2026-12-04"

      assert [
               %{"kind" => "user", "user_id" => user_id},
               %{"kind" => "guest", "email" => "visitor@example.org"}
             ] = draft.attrs["add_invitees"]

      assert user_id == guest.id
      assert draft.attrs["project_id"] == project.id
      assert Draft.url(draft) == "/calendar?draft=" <> draft.token
      assert byte_size(draft.token) >= 32
    end

    test "an instant with an offset is that instant, whatever time_zone says", ctx do
      grant!(ctx)

      assert {:ok, draft, :created} =
               create(ctx, %{
                 "start" => "2026-12-04T09:00:00-05:00",
                 "end" => "2026-12-04T10:00:00-05:00"
               })

      assert draft.attrs["starts_at"] == "2026-12-04T14:00:00Z"
    end

    test "nothing is defaulted: a missing title, start or end stays missing", ctx do
      grant!(ctx)

      assert {:ok, draft, :created} =
               create(ctx, %{"title" => nil, "start" => nil, "end" => nil})

      assert draft.attrs["title"] == nil
      assert draft.attrs["starts_at"] == nil
      assert draft.attrs["date"] == nil
      assert "No title yet." in draft.issues
      assert "No start or end time yet." in draft.issues
      assert Draft.status(draft) == "incomplete"
    end

    test "a malformed call is refused for the agent to fix, and stores nothing", ctx do
      grant!(ctx)

      assert {:error, {:invalid, [message]}} = create(ctx, %{"time_zone" => "Mars/Olympus"})
      assert message =~ "time_zone"
      assert {:error, {:invalid, _}} = create(ctx, %{"time_zone" => nil})
      assert {:error, {:invalid, _}} = create(ctx, %{"category" => "party"})
      assert {:error, {:invalid, _}} = create(ctx, %{"attendees" => "everyone"})
      assert {:error, {:invalid, _}} = create(ctx, %{"request_key" => nil})
      assert Repo.aggregate(Draft, :count) == 0
    end
  end

  describe "clarification, never a silent choice" do
    test "a local time the fall-back change repeats keeps no instant and asks", ctx do
      grant!(ctx)

      # 2026-11-01 01:30 happens twice in Chicago (CDT, then CST).
      assert {:ok, draft, :created} =
               create(ctx, %{"start" => "2026-11-01T01:30:00", "end" => "2026-11-01T03:00:00"})

      assert draft.attrs["starts_at"] == nil
      assert draft.attrs["ends_at"] == "2026-11-01T09:00:00Z"
      assert draft.attrs["date"] == "2026-11-01"

      assert [%{"id" => "time:start", "kind" => "time", "question" => question}] =
               draft.clarifications

      assert question =~ "1:30 AM happens twice"
      assert Draft.status(draft) == "needs_clarification"
    end

    test "a local time the spring-forward change skips keeps no instant and asks", ctx do
      grant!(ctx)

      assert {:ok, draft, :created} =
               create(ctx, %{"start" => "2026-03-08T02:30:00", "end" => "2026-03-08T04:00:00"})

      assert draft.attrs["starts_at"] == nil
      assert [%{"kind" => "time", "question" => question}] = draft.clarifications
      assert question =~ "doesn't exist"
    end

    test "a name matching two people lists both and stages neither", ctx do
      grant!(ctx)
      first = member!(ctx, "Wren#{ctx.n} Ashby")
      second = member!(ctx, "Wren#{ctx.n} Colt")

      assert {:ok, draft, :created} = create(ctx, %{"attendees" => [%{"name" => "Wren#{ctx.n}"}]})

      assert draft.attrs["add_invitees"] == []

      assert [%{"id" => "attendee:0", "kind" => "attendee", "candidates" => candidates}] =
               draft.clarifications

      assert candidates |> Enum.map(& &1["user_id"]) |> Enum.sort() ==
               Enum.sort([first.id, second.id])

      assert Draft.status(draft) == "needs_clarification"
    end

    test "a full name matching one person stages that person", ctx do
      grant!(ctx)
      only = member!(ctx, "Wren#{ctx.n} Ashby")
      _other = member!(ctx, "Wren#{ctx.n} Colt")

      assert {:ok, draft, :created} =
               create(ctx, %{"attendees" => [%{"name" => "Wren#{ctx.n} Ashby"}]})

      assert [%{"user_id" => id}] = draft.attrs["add_invitees"]
      assert id == only.id
      assert draft.clarifications == []
    end

    test "a name nobody has, and an id nobody has, ask instead of dropping", ctx do
      grant!(ctx)

      assert {:ok, draft, :created} =
               create(ctx, %{
                 "attendees" => [
                   %{"name" => "Nobody#{ctx.n}"},
                   %{"user_id" => Ecto.UUID.generate(), "name" => "Ghost"}
                 ]
               })

      assert [%{"kind" => "attendee", "candidates" => []}, %{"kind" => "attendee"}] =
               draft.clarifications
    end
  end

  describe "idempotency" do
    test "the same request_key returns the original draft, unchanged", ctx do
      grant!(ctx)
      assert {:ok, first, :created} = create(ctx)
      assert {:ok, again, :existing} = create(ctx, %{"title" => "Something else"})

      assert again.id == first.id
      assert again.token == first.token
      assert again.attrs["title"] == "Design review"
      assert Repo.aggregate(Draft, :count) == 1

      assert {:ok, other, :created} = create(ctx, %{"request_key" => "req-2"})
      assert other.token != first.token
    end
  end

  describe "who can open a draft" do
    test "only its owner, by token or id; anyone else sees nothing", ctx do
      grant!(ctx)
      {:ok, draft, _} = create(ctx)
      stranger = Scope.for_user(Platform.ExternalUserFixtures.create_user!())

      assert {:ok, %Draft{id: id}} = Draft.fetch(ctx.owner, draft.token)
      assert id == draft.id
      assert {:ok, _} = Draft.get(ctx.owner, draft.id)

      assert {:error, :not_found} = Draft.fetch(stranger, draft.token)
      assert {:error, :not_found} = Draft.get(stranger, draft.id)
      assert {:error, :not_found} = Draft.fetch(ctx.scope, draft.token)
      assert {:error, :not_found} = Draft.fetch(ctx.owner, "short")
      assert {:error, :not_found} = Draft.get(ctx.owner, "not-a-uuid")
    end

    test "an expired draft is refused to its owner too", ctx do
      grant!(ctx)
      {:ok, draft, _} = create(ctx)
      later = DateTime.add(draft.expires_at, 1, :second)
      just_before = DateTime.add(draft.expires_at, -1, :second)

      assert {:ok, _} = Draft.fetch(ctx.owner, draft.token, now: just_before)
      assert {:error, :expired} = Draft.fetch(ctx.owner, draft.token, now: later)
      assert {:error, :expired} = Draft.fetch(ctx.owner, draft.token, now: draft.expires_at)

      assert DateTime.diff(draft.expires_at, draft.inserted_at) in (Draft.ttl_seconds() - 5)..Draft.ttl_seconds()
    end
  end

  describe "the one explicit save" do
    defp attrs_for(draft, scope) do
      base = Draft.event_draft(draft, scope)

      {base,
       %{
         "title" => base.title,
         "starts_at" => base.starts_at,
         "ends_at" => base.ends_at,
         "time_zone" => base.time_zone,
         "add_invitees" => base.add_invitees,
         "call_enabled" => false
       }}
    end

    test "saves exactly one event and then refuses the same draft", ctx do
      grant!(ctx)
      {:ok, draft, _} = create(ctx)
      {base, attrs} = attrs_for(draft, ctx.owner)
      assert base.source == "agent"
      before = counts()

      assert {:ok, %{event: %Event{id: event_id, title: "Design review"}}} =
               Authoring.save(ctx.owner, base, attrs, agent_draft: draft.id)

      assert counts() == %{before | events: before.events + 1}
      assert %Draft{saved_at: %DateTime{}, event_id: ^event_id} = Repo.get!(Draft, draft.id)

      assert {:error, :saved} = Authoring.save(ctx.owner, base, attrs, agent_draft: draft.id)
      assert {:error, :saved} = Draft.fetch(ctx.owner, draft.token)
      assert counts().events == before.events + 1
    end

    test "an unanswered attendee question blocks the save, an answer unblocks it", ctx do
      grant!(ctx)
      member!(ctx, "Wren#{ctx.n} Ashby")
      member!(ctx, "Wren#{ctx.n} Colt")
      {:ok, draft, _} = create(ctx, %{"attendees" => [%{"name" => "Wren#{ctx.n}"}]})
      {base, attrs} = attrs_for(draft, ctx.owner)
      before = counts()

      assert {:error, :unresolved} = Authoring.save(ctx.owner, base, attrs, agent_draft: draft.id)
      assert counts() == before
      assert is_nil(Repo.get!(Draft, draft.id).saved_at)

      assert {:ok, _} =
               Authoring.save(ctx.owner, base, attrs,
                 agent_draft: draft.id,
                 resolved: ["attendee:0"]
               )
    end

    test "a stranger or an expired draft saves nothing", ctx do
      grant!(ctx)
      {:ok, draft, _} = create(ctx)
      {base, attrs} = attrs_for(draft, ctx.owner)
      stranger = Platform.ExternalUserFixtures.create_user!()
      Platform.ExternalUserFixtures.plain_member!(stranger, ctx.org)
      before = counts()

      assert {:error, :not_found} =
               Authoring.save(Scope.for_user(stranger), base, attrs, agent_draft: draft.id)

      draft
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      assert {:error, :expired} = Authoring.save(ctx.owner, base, attrs, agent_draft: draft.id)
      assert counts() == before
    end

    test "a refused event save rolls the draft back to unsaved", ctx do
      grant!(ctx)
      {:ok, draft, _} = create(ctx)
      {base, attrs} = attrs_for(draft, ctx.owner)

      assert {:error, _} =
               Authoring.save(ctx.owner, base, %{attrs | "title" => ""}, agent_draft: draft.id)

      assert is_nil(Repo.get!(Draft, draft.id).saved_at)
    end
  end

  describe "the agents Calendar offers" do
    test "only agents with a live create grant and an active runtime; online? is presence",
         ctx do
      assert Platform.Calendar.AgentAccess.draft_agents(ctx.owner) == []

      grant!(ctx, %{create: false})
      assert Platform.Calendar.AgentAccess.draft_agents(ctx.owner) == []

      grant!(ctx)
      assert [%{id: id, online?: false}] = Platform.Calendar.AgentAccess.draft_agents(ctx.owner)
      assert id == ctx.agent.id

      Platform.Federation.RuntimePresence.track(ctx.runtime.runtime_id)
      on_exit(fn -> Platform.Federation.RuntimePresence.untrack(ctx.runtime.runtime_id) end)
      assert [%{online?: true}] = Platform.Calendar.AgentAccess.draft_agents(ctx.owner)

      {:ok, _} = AgentAccess.revoke(ctx.owner, ctx.agent.id)
      assert Platform.Calendar.AgentAccess.draft_agents(ctx.owner) == []
    end

    test "asking an offline agent sends nothing; an online one gets one DM message", ctx do
      grant!(ctx)
      messages = fn -> Repo.aggregate(Platform.Chat.Message, :count) end
      before = messages.()

      assert {:error, :unavailable} =
               Draft.ask(ctx.owner, ctx.agent.id, "Lunch Friday", time_zone: @zone)

      assert messages.() == before

      Platform.Federation.RuntimePresence.track(ctx.runtime.runtime_id)
      on_exit(fn -> Platform.Federation.RuntimePresence.untrack(ctx.runtime.runtime_id) end)

      assert {:error, :blank} = Draft.ask(ctx.owner, ctx.agent.id, "   ", time_zone: @zone)
      assert {:error, :forbidden} = Draft.ask(ctx.owner, Ecto.UUID.generate(), "x")

      assert {:ok, %{space: space, message: message, request_key: key}} =
               Draft.ask(ctx.owner, ctx.agent.id, "Lunch Friday",
                 time_zone: @zone,
                 today: ~D[2026-11-07]
               )

      assert messages.() == before + 1
      assert space.kind == "dm"
      assert message.content =~ "Lunch Friday"
      assert message.content =~ "request_key #{key}"
      assert message.content =~ "owner_id #{ctx.user.id}"
      assert message.content =~ "Today is Saturday, November 7, 2026 in #{@zone}"
      assert message.metadata["source"] == "calendar_draft_request"
      assert counts().events == 0
    end
  end
end
