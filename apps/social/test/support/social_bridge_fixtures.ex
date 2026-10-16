defmodule Platform.SocialBridgeFixtures do
  @moduledoc """
  The task bridge fixture (Social 6/7): org O with project Pr and channel
  S; approver H (a real user, member of O, on the profile's list); profile
  P (O, Pr, S) with approve_first accounts L (linkedin) and X (x); agent G
  pinned to O; meeting M in Pr. Candidates are written through core's
  `Platform.Meetings.Candidates` (create/1 and close/2), never insert_all.
  """

  import Platform.SocialFixtures

  alias Platform.Meetings.{Candidates, IntentRouting}
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.TaskRequest

  def bridge_world!(opts \\ []) do
    org_id = Keyword.get_lazy(opts, :org_id, &org_id!/0)
    project = project!(org_id)
    space = channel!(org_id)
    approver = member!(user!(), org_id)

    {:ok, profile} =
      Social.create_profile(org_id, %{
        name: "Bridge show #{unique()}",
        project_id: project.id,
        space_id: space.id,
        approver_user_ids: [approver.id]
      })

    {:ok, linkedin} =
      Social.create_account(org_id, profile, %{platform: "linkedin", handle: "@bridge"})

    {:ok, x} = Social.create_account(org_id, profile, %{platform: "x", handle: "@bridge_x"})

    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{project_id: project.id, name: "Bridge meet"})

    agent = pinned_agent!(org_id)

    %{
      org_id: org_id,
      project: project,
      space: space,
      approver: approver,
      profile: profile,
      linkedin: linkedin,
      x: x,
      meeting: meeting,
      agent: agent,
      scope: {:tenant, org_id},
      ctx: %{agent_id: agent.id, space_id: space.id}
    }
  end

  @doc "A routable classified intent, read from core's routing table."
  def routable_intent, do: hd(IntentRouting.intents())

  @doc "A fresh segment id (a UUID, as the transcriber mints them)."
  def segment_id, do: Platform.Types.UUIDv7.generate()

  @doc """
  A candidate in `meeting` keyed by `segment`, classified routable and
  `:heard` unless `attrs` say otherwise.
  """
  def candidate!(meeting, segment, attrs \\ %{}) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            transcript_chunk_id: segment,
            state: :heard,
            outcome_kind: :task,
            classified_intent: routable_intent(),
            evidence_quote: "clip the doomsday clock bit"
          },
          attrs
        )
      )

    candidate
  end

  @doc "A candidate closed with `reason` through core's one close path."
  def closed_candidate!(meeting, segment, reason, attrs \\ %{}) do
    candidate = candidate!(meeting, segment, attrs)
    {:ok, closed} = Candidates.close(candidate, {reason, "test close"})
    closed
  end

  @doc "A candidate the live pipeline already graduated into `task`."
  def graduated_candidate!(meeting, segment, task) do
    candidate = candidate!(meeting, segment, %{state: :acting, task_id: task.id})
    {:ok, closed} = Candidates.close(candidate, :done)
    closed
  end

  @doc "Request attrs citing `segments` of the world's meeting."
  def meeting_ask(world, segments, attrs \\ %{}) do
    Map.merge(
      %{
        "profile_id" => world.profile.id,
        "platforms" => ["linkedin", "x"],
        "ask" => "clip the doomsday clock bit",
        "refs" => %{"meeting_id" => world.meeting.id, "segment_ids" => segments}
      },
      attrs
    )
  end

  @doc "Everything a refusal must leave untouched."
  def snapshot(world) do
    %{
      tasks: length(Platform.Tasks.list_tasks_by_project(world.project.id)),
      requests: Repo.aggregate(TaskRequest, :count),
      candidates: Candidates.list_for_meeting(world.meeting.id)
    }
  end
end
