defmodule Platform.Federation.CalendarToolsTest do
  @moduledoc """
  `calendar_draft` on the federated tool surface (task 01a1b8a5 stage 3),
  through the same doors a runtime uses: `ToolAuthorization.authorize/2`
  then `ToolArguments.dispatch/3`. Also pins that `calendar_list` and
  `calendar_propose` are unchanged: the definitions byte for byte, and
  propose still reserving a hold with its consent in Inbox.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Access.{RuntimeProfile, RuntimeProfiles, Scope, ToolPermissions}
  alias Platform.Calendar.{AgentAccess, Consent, Draft, Event}
  alias Platform.Federation.{CalendarTools, ToolArguments, ToolAuthorization, ToolSurface}

  # sha256 of the two pre-existing definitions, inspected with sorted maps
  # (stable across OTP releases, unlike `term_to_binary/1`), measured at
  # base 43325c86 before calendar_draft existed.
  @propose_and_list_sha "963b34bc9be647c0da1bacd15930c433da09ee83426e5393f80b60c37591e220"

  setup do
    n = System.unique_integer([:positive])
    user = Platform.ExternalUserFixtures.create_user!()
    Platform.ExternalUserFixtures.plain_member!(user, Platform.Tenancy.get_org_by_slug!("globex"))

    agent =
      Repo.insert!(%Platform.Agents.Agent{name: "Tool scheduler", slug: "calendar-tool-#{n}"})

    runtime = runtime!(user, agent, "calendar-tool-#{n}", ["context_read"])

    %{
      user: user,
      owner: Scope.for_user(user),
      agent: agent,
      runtime: runtime,
      context: %{runtime_id: runtime.runtime_id, agent_id: agent.id}
    }
  end

  defp runtime!(user, agent, id, profile) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: id,
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Tool scheduler"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: profile,
      restricted_permissions: RuntimeProfiles.translated_permissions(profile)
    })

    runtime
  end

  defp grant!(ctx, extra \\ %{}) do
    {:ok, grant} =
      AgentAccess.grant(ctx.owner, ctx.agent.id, Map.merge(%{read: true, create: true}, extra))

    grant
  end

  defp draft_args(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "owner_id" => ctx.user.id,
        "request_key" => "cal-wire-1",
        "time_zone" => "America/Chicago",
        "title" => "Planning",
        "start" => "2026-12-04T14:00:00",
        "end" => "2026-12-04T15:00:00"
      },
      extra
    )
  end

  defp call(tool, args, ctx) do
    runtime = Platform.Federation.get_runtime_by_runtime_id(ctx.context.runtime_id)

    with :ok <- ToolAuthorization.authorize(tool, runtime) do
      ToolArguments.dispatch(tool, args, ctx.context)
    end
  end

  defp writes,
    do: %{
      events: Repo.aggregate(Event, :count),
      consents: Repo.aggregate(Consent, :count),
      inbox: Repo.aggregate(Platform.Inbox.Item, :count),
      meetings: Repo.aggregate(Platform.Meetings.Meeting, :count)
    }

  describe "registration" do
    test "calendar_draft is in context_read beside the two older tools, under calendar.write" do
      names =
        for %{name: "calendar_" <> _ = name, bundle: bundle} <- ToolSurface.tool_definitions(),
            do: {name, bundle}

      assert names == [
               {"calendar_list", "context_read"},
               {"calendar_propose", "context_read"},
               {"calendar_draft", "context_read"}
             ]

      assert ToolPermissions.for_tool("calendar_draft") == "calendar.write"
      assert ToolPermissions.for_tool("calendar_propose") == "calendar.write"

      draft = Enum.find(CalendarTools.definitions(), &(&1.name == "calendar_draft"))

      assert MapSet.new(for {k, %{required: true}} <- draft.parameters, do: k) ==
               MapSet.new([:owner_id, :request_key, :time_zone])

      for field <- [:description, :returns, :limitations, :when_to_use],
          do: assert(is_binary(Map.fetch!(draft, field)))

      assert draft.description =~ "Write-free"
    end

    test "calendar_list and calendar_propose definitions are byte for byte unchanged" do
      [list, propose | _] = CalendarTools.definitions()
      assert {list.name, propose.name} == {"calendar_list", "calendar_propose"}

      printed =
        inspect([list, propose],
          limit: :infinity,
          printable_limit: :infinity,
          custom_options: [sort_maps: true]
        )

      assert :crypto.hash(:sha256, printed) |> Base.encode16(case: :lower) ==
               @propose_and_list_sha
    end

    test "every required argument is enforced by the shared validator", ctx do
      args = Map.take(draft_args(ctx), ~w(owner_id request_key time_zone))
      assert :ok = ToolArguments.validate("calendar_draft", args)

      for key <- Map.keys(args),
          do:
            assert({:error, _} = ToolArguments.validate("calendar_draft", Map.delete(args, key)))
    end
  end

  describe "calendar_draft over the wire" do
    test "a granted runtime gets an owner-only link and nothing else is written", ctx do
      grant!(ctx)
      before = writes()

      assert {:ok, %{status: "ready", url: "/calendar?draft=" <> token} = result} =
               call("calendar_draft", draft_args(ctx), ctx)

      assert result.clarifications == []
      assert result.issues == []
      assert {:ok, _, _} = DateTime.from_iso8601(result.expires_at)
      assert writes() == before
      assert {:ok, %Draft{}} = Draft.fetch(ctx.owner, token)
    end

    test "a retried delivery returns the same link and one draft", ctx do
      grant!(ctx)
      assert {:ok, %{url: url}} = call("calendar_draft", draft_args(ctx), ctx)
      assert {:ok, %{url: ^url}} = call("calendar_draft", draft_args(ctx), ctx)
      assert Repo.aggregate(Draft, :count) == 1
    end

    test "clarifications reach the agent with candidate ids and names only", ctx do
      grant!(ctx)
      org = Platform.Tenancy.get_org_by_slug!("globex")
      n = System.unique_integer([:positive])

      for last <- ["Ashby", "Colt"] do
        user =
          Platform.ExternalUserFixtures.create_user!(%{
            name: "Juniper#{n} #{last}",
            email: "juniper#{n}.#{String.downcase(last)}@example.com"
          })

        Platform.ExternalUserFixtures.plain_member!(user, org)
      end

      assert {:ok, %{status: "needs_clarification", clarifications: [question]}} =
               call(
                 "calendar_draft",
                 draft_args(ctx, %{"attendees" => [%{"name" => "Juniper#{n}"}]}),
                 ctx
               )

      assert question.kind == "attendee"
      assert length(question.candidates) == 2
      assert Enum.all?(question.candidates, &(Map.keys(&1) |> Enum.sort() == ["name", "user_id"]))
    end

    test "no grant is a non-recoverable denial; a bad zone is recoverable", ctx do
      assert {:error, %{recoverable: false}} = call("calendar_draft", draft_args(ctx), ctx)

      grant!(ctx)

      assert {:error, %{recoverable: true, error: error}} =
               call("calendar_draft", draft_args(ctx, %{"time_zone" => "Nowhere/Here"}), ctx)

      assert error =~ "time_zone"
      assert Repo.aggregate(Draft, :count) == 0
    end

    test "a runtime whose profile lacks calendar.write is refused at both doors", ctx do
      grant!(ctx)
      n = System.unique_integer([:positive])
      narrow = runtime!(ctx.user, ctx.agent, "calendar-narrow-#{n}", ["federation"])

      assert {:error, _} = ToolAuthorization.authorize("calendar_draft", narrow)

      assert {:error, %{recoverable: false}} =
               ToolSurface.execute("calendar_draft", draft_args(ctx), %{
                 runtime_id: narrow.runtime_id,
                 agent_id: ctx.agent.id
               })

      assert Repo.aggregate(Draft, :count) == 0
    end
  end

  describe "calendar_propose is unchanged" do
    test "it still reserves a tentative hold and routes its consent to Inbox", ctx do
      grant!(ctx)
      before = writes()

      assert {:ok, %{state: "pending", inbox_url: "/inbox", id: consent_id}} =
               call(
                 "calendar_propose",
                 %{
                   "owner_id" => ctx.user.id,
                   "operation" => "create",
                   "request_key" => "hold-1",
                   "attributes" => %{
                     "title" => "Held",
                     "starts_at" => "2026-12-04T20:00:00Z",
                     "ends_at" => "2026-12-04T21:00:00Z",
                     "time_zone" => "America/Chicago"
                   }
                 },
                 ctx
               )

      consent = Repo.get!(Consent, consent_id)
      assert %Event{tentative: true, title: "Held"} = Repo.get!(Event, consent.hold_id)
      assert writes().events == before.events + 1
      assert writes().consents == before.consents + 1
      assert writes().inbox == before.inbox + 1
      assert Repo.aggregate(Draft, :count) == 0
    end
  end
end
