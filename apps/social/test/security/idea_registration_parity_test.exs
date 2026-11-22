defmodule Platform.Social.IdeaRegistrationParityTest do
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolCall

  @social_tools ~w(social_clip_job_claim social_clip_job_complete social_clip_job_fail
    social_clip_job_list social_clip_job_progress social_clip_job_source social_clip_list
    social_clip_propose social_clip_render social_clip_submit social_draft_create
    social_draft_update social_idea_archive social_idea_create social_idea_list social_idea_note_add
    social_idea_unvote social_idea_vote social_post_list social_profile_get social_profile_list
    social_results_get social_studio_draft_create social_task_request social_weekly_note_list
    social_weekly_note_submit)

  test "an existing Social owner retains the same tool list and full payload with unrestricted or use-only runtimes" do
    n = System.unique_integer([:positive])
    org = Platform.Tenancy.get_org_by_slug!("acme")

    owner =
      Repo.insert!(%Platform.Accounts.User{
        name: "Parity owner",
        email: "idea-parity-#{n}@example.com",
        oidc_sub: "idea-parity-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      org_id: org.id,
      user_id: owner.id,
      role: "member"
    })

    agent =
      Repo.insert!(%Agent{
        slug: "idea-parity-#{n}",
        name: "Parity agent",
        metadata: %{"org_id" => org.id}
      })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Parity #{n}", org_id: org.id})

    {:ok, profile} =
      Platform.Social.create_profile(org.id, %{name: "Parity #{n}", project_id: project.id})

    {:ok, idea} =
      Platform.Social.Ideas.create(
        org.id,
        profile.id,
        %{title: "Parity idea", brief: "Parity brief"},
        {:agent, agent.id}
      )

    for restrictions <- [nil, %{"social.use" => "all"}] do
      runtime =
        Repo.insert!(%AgentRuntime{
          runtime_id: "idea-parity-runtime-#{System.unique_integer([:positive])}",
          agent_id: agent.id,
          owner_user_id: owner.id,
          status: "active"
        })

      {:ok, _} = RuntimeProfiles.create_for_runtime(runtime, ["social"], restrictions)

      assert runtime
             |> Tools.tool_names()
             |> Enum.filter(&String.starts_with?(&1, "social_"))
             |> Enum.sort() == @social_tools

      assert {:ok, %{ideas: [row], total: 1, limit: 50, offset: 0, has_more: false}} =
               ToolCall.invoke("social_idea_list", %{"profile_id" => profile.id}, runtime)

      assert %{
               id: id,
               profile_id: profile_id,
               title: "Parity idea",
               brief: "Parity brief",
               source_kind: "agent",
               created_by_agent_id: author,
               stage: "inbox",
               vote_count: 0,
               voted: false,
               selected: false,
               selected_at: nil,
               posts: [],
               open_revisions: [],
               notes: []
             } = row

      assert {id, profile_id, author} == {idea.id, profile.id, agent.id}

      assert MapSet.new(Map.keys(row)) ==
               MapSet.new(
                 ~w(id profile_id title brief source_kind clip_id task_id meeting_id message_id source_url created_by_user_id created_by_agent_id archived_at inserted_at stage vote_count voted selected selected_at posts open_revisions notes)a
               )
    end
  end
end
