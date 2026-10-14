defmodule Platform.Federation.ToolSurfaceMeetingActivityPushTest do
  @moduledoc """
  Coverage for the `meeting_activity_push` MCP tool (task `01a07400`
  stage 1).

  Driven through `ToolArguments.dispatch/3`, the entry point both
  federation transports use, so the declared-required gate runs here the
  way it runs in production rather than being skipped by calling
  `ToolSurface.execute/3` directly.

  Three properties are worth more than the happy path:

    * **The state set is closed.** A runtime that could name `failed` could
      overwrite the one reading that says something went wrong, and one
      that could name `listening` would rebuild the always-on badge canvas
      `01a05b11-54ff` removed. Both refusals are asserted, and each is
      followed by a read proving nothing was written.
    * **The agent is the caller.** There is no parameter for whose state
      this is, so the test asserts the row lands under the calling agent's
      id and not under anything supplied in `args`.
    * **A refusal writes nothing.** Every error case is paired with a read
      of the store, for the same reason `tool_surface_meeting_say_test.exs`
      pairs each refusal with a `refute_receive`: a green-looking refusal
      that still wrote would be worse than a crash.

  The expiry itself is NOT re-tested here — it belongs to the store and is
  pinned in `test/platform/meetings/agent_activity_test.exs`. What this
  file checks is that the tool hands the store a real ttl and reports it
  back, so a runtime knows how often to refresh.
  """

  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolArguments
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Repo
  alias Platform.Tasks.Project

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "activity-push-agent-#{n}",
      name: "Activity Push Agent #{n}",
      status: "active"
    })
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Activity Push Project #{n}",
        slug: "activity-push-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Activity Push Meeting #{n}",
        slug: "activity-push-meeting-#{n}"
      })

    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)

    %{meeting: meeting, room: room}
  end

  # The seat the tool guards on: an un-departed participant row for the
  # meeting's ACTIVE room, which is what the rail renders from.
  defp seat!(room, %Agent{} = agent) do
    {:ok, _} = Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})
    :ok
  end

  defp dispatch(args, agent),
    do: ToolArguments.dispatch("meeting_activity_push", args, %{agent: agent})

  setup do
    %{meeting: meeting, room: room} = meeting!()
    agent = agent!()
    :ok = seat!(room, agent)

    on_exit(fn -> AgentActivity.clear_pushed(meeting.id, agent.id) end)

    {:ok, meeting: meeting, room: room, agent: agent}
  end

  describe "a seated agent declaring its own state" do
    test "thinking is recorded under the CALLING agent and reported with its ttl",
         %{meeting: meeting, agent: agent} do
      assert {:ok, result} =
               dispatch(
                 %{
                   "meeting_id" => meeting.id,
                   "state" => "thinking",
                   "reason" => "reading the transcript"
                 },
                 agent
               )

      assert result.meeting_id == meeting.id
      assert result.agent_id == agent.id
      assert result.state == "thinking"
      assert result.reason == "reading the transcript"
      assert result.ttl_ms == AgentActivity.pushed_ttl_ms()

      # A runtime has to know when the claim lapses to know how often to
      # refresh, so both timestamps are parseable and ordered.
      {:ok, pushed_at, _} = DateTime.from_iso8601(result.pushed_at)
      {:ok, expires_at, _} = DateTime.from_iso8601(result.expires_at)
      assert DateTime.diff(expires_at, pushed_at, :millisecond) == result.ttl_ms

      assert %{state: :thinking, reason: "reading the transcript"} =
               AgentActivity.pushed(meeting.id, agent.id, pushed_at)
    end

    test "composing is accepted too, and a second push replaces the first",
         %{meeting: meeting, agent: agent} do
      assert {:ok, _} = dispatch(%{"meeting_id" => meeting.id, "state" => "thinking"}, agent)

      assert {:ok, %{state: "composing"}} =
               dispatch(%{"meeting_id" => meeting.id, "state" => "composing"}, agent)

      assert %{state: :composing} =
               AgentActivity.pushed(meeting.id, agent.id, DateTime.utc_now())
    end

    test "a blank reason is absent rather than an empty string",
         %{meeting: meeting, agent: agent} do
      assert {:ok, %{reason: nil}} =
               dispatch(
                 %{"meeting_id" => meeting.id, "state" => "thinking", "reason" => "   "},
                 agent
               )
    end
  end

  describe "refusals" do
    # The closed set is the security property, not a validation nicety.
    test "no state outside thinking/composing can be declared, and none is written",
         %{meeting: meeting, agent: agent} do
      for state <- ~w(idle typing computing failed listening heard Thinking THINKING nonsense) do
        assert {:error, %{error: message, recoverable: false}} =
                 dispatch(%{"meeting_id" => meeting.id, "state" => state}, agent)

        assert message =~ "not a state you can declare"
        assert AgentActivity.pushed(meeting.id, agent.id, DateTime.utc_now()) == nil
      end
    end

    test "an agent that is not seated in the meeting is refused",
         %{meeting: meeting} do
      outsider = agent!()

      assert {:error, %{error: message, recoverable: false}} =
               dispatch(%{"meeting_id" => meeting.id, "state" => "thinking"}, outsider)

      assert message =~ "not seated"
      assert AgentActivity.pushed(meeting.id, outsider.id, DateTime.utc_now()) == nil
    end

    # An agent whose seat was released has no tile to appear on, so the
    # guard has to read "seated now", not "seated at some point".
    test "an agent whose seat has been released is refused",
         %{meeting: meeting, room: room, agent: agent} do
      assert {:ok, _} = dispatch(%{"meeting_id" => meeting.id, "state" => "thinking"}, agent)

      {:ok, _} = Meetings.participant_left(room, agent.name)

      assert {:error, %{error: message}} =
               dispatch(%{"meeting_id" => meeting.id, "state" => "composing"}, agent)

      assert message =~ "not seated"
    end

    test "an unknown, malformed or absent meeting_id is refused", %{agent: agent} do
      unknown = Platform.Types.UUIDv7.generate()

      assert {:error, %{error: message}} =
               dispatch(%{"meeting_id" => unknown, "state" => "thinking"}, agent)

      assert message =~ "no meeting"

      assert {:error, %{error: malformed}} =
               dispatch(%{"meeting_id" => "not-a-uuid", "state" => "thinking"}, agent)

      assert malformed =~ "no meeting"

      # Absence is caught one layer earlier, by the declared-required gate
      # in `ToolArguments.validate/2`, and carries its own code.
      assert {:error, %{code: :missing_meeting_id}} = dispatch(%{"state" => "thinking"}, agent)
    end

    test "an absent state is refused by the required-argument gate",
         %{meeting: meeting, agent: agent} do
      assert {:error, %{code: :missing_state}} =
               dispatch(%{"meeting_id" => meeting.id}, agent)

      assert AgentActivity.pushed(meeting.id, agent.id, DateTime.utc_now()) == nil
    end

    test "a call with no agent in context is refused", %{meeting: meeting} do
      assert {:error, %{error: message, recoverable: false}} =
               ToolArguments.dispatch(
                 "meeting_activity_push",
                 %{"meeting_id" => meeting.id, "state" => "thinking"},
                 %{}
               )

      assert message =~ "no calling agent"
    end
  end
end
