defmodule Platform.Memory.Insights.UnattendedTest do
  @moduledoc """
  Task 01a15587 stage 2: `Platform.Memory.Insights.Actions.apply_unattended/2`
  and the identities it acts as (`Platform.Memory.Insights.Unattended`).

  Every refusal reads the page (content AND version) or the task table back
  afterwards and checks the insight is still open, so a refusal that wrote
  first and errored second is caught. Each refusal has a positive control on
  the same fixture.

  Mutation probes: (a) skipping `Routing.gate_write/3` turns "the wiki gate
  refuses a key the Historian may not write" red, and pointing it at the
  dreaming agent turns "an unattended page_edit is written as the Historian"
  red; (b) skipping the re-grounding turns the downgrade test red; (c)
  dropping `sponsor_user_id` from the task attrs turns the backlog-task test
  red; (d) `eligible?/1` always true turns the not-authored test red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InsightFixtures
  import Platform.RuntimeProfileFixtures
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.Unattended
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks.Task

  @journal "org/journal/2026-10-19.md"

  defp n, do: System.unique_integer([:positive])

  defp agent!(prefix) do
    i = n()
    Repo.insert!(%Agent{slug: "#{prefix}-#{i}", name: "#{prefix} #{i}", status: "active"})
  end

  # A runtime for `agent` owned by a root admin, carrying `modules`, last
  # connected `ago` seconds before now. By default it becomes the agent's
  # BRAIN runtime (`agent.runtime_id`); `brain: false` leaves it a voice row.
  defp runtime_for!(agent, modules, opts \\ []) do
    connected = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :ago, 0), :second)

    runtime =
      runtime!(
        root_admin!().id,
        modules,
        %{agent_id: agent.id, last_connected_at: connected},
        Keyword.get(opts, :restriction, :translated)
      )

    if Keyword.get(opts, :brain, true) do
      Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [runtime_id: runtime.id])
    end

    runtime
  end

  defp historian!(opts \\ []) do
    agent = agent!("historian")
    {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    if Keyword.get(opts, :runtime, true), do: runtime_for!(agent, ["memory"])
    agent
  end

  defp page!(content, editor, key \\ nil) do
    key = key || "org/page/unattended-#{n()}.md"
    {:ok, page} = Wiki.upsert_page(key, %{content: content, updated_by: editor && editor.id})
    {key, page}
  end

  defp edit_block(key, old, new, source \\ nil) do
    ~s(<synthesis-insight action="page_edit" confidence="high" target="#{key}" source="#{source || "page:" <> key}">
    The page is out of date, ref #{n()}.
    <old>#{old}</old><new>#{new}</new>
    </synthesis-insight>)
  end

  defp ingest!(content, author) do
    before = Repo.all(from(i in Insight, select: i.id))
    {:ok, 1} = Insights.ingest_from_journal(nil, @journal, content, author && author.id)
    Repo.one!(from(i in Insight, where: i.id not in ^before))
  end

  defp page_state(key) do
    page = Wiki.get_page(key)
    {page.content, page.version}
  end

  defp project! do
    {:ok, project} = Platform.Tasks.create_project(%{name: "un-#{n()}", org_id: acme_org_id()})
    project
  end

  defp task_block(project, addressee) do
    addressee_attr = if addressee, do: ~s( addressee="#{addressee.id}"), else: ""

    ~s(<synthesis-insight action="task" confidence="high" target="#{project.id}"#{addressee_attr}>
    Rotate the deploy key on the build box, ref #{n()}.
    </synthesis-insight>)
  end

  setup do
    dreamer = dreaming_agent!()
    %{dreamer: dreamer, member: person!()}
  end

  describe "page_edit" do
    test "an unattended page_edit is written as the Historian", %{
      dreamer: dreamer,
      member: member
    } do
      historian = historian!()
      {key, page} = page!("Deploys go to host-a every night.", member)
      insight = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      assert insight.authored_by == dreamer.id
      assert insight.tier == "reversible"

      assert {:ok, %Insight{state: "done"} = acted} = Actions.apply_unattended(insight)

      written = Wiki.get_page(key)
      assert written.content == "Deploys go to host-b every night."
      assert written.version == page.version + 1
      assert written.updated_by == historian.id

      assert acted.acted_by == historian.id
      assert acted.artefact_ref == "page:#{key}@v#{written.version}"

      assert %{
               "file_key" => ^key,
               "content" => "Deploys go to host-a every night.",
               "version" => v,
               "written_version" => wv,
               "unattended" => true,
               "acting_agent_id" => acting
             } = Repo.get!(Insight, insight.id).pre_image

      assert v == page.version
      assert wv == written.version
      assert acting == historian.id

      # A second apply does nothing more.
      assert {:error, :not_open} = Actions.apply_unattended(insight)
      assert Wiki.get_page(key).version == written.version
    end

    test "with no Historian assigned nothing is written", %{dreamer: dreamer, member: member} do
      {key, _page} = page!("Deploys go to host-a every night.", member)
      insight = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      before = page_state(key)

      assert {:error, :no_historian} = Unattended.page_edit_actor(key)
      assert {:error, :no_historian} = Actions.apply_unattended(insight)
      assert page_state(key) == before

      assert %Insight{state: "open", acted_by: nil, pre_image: nil} =
               Repo.get!(Insight, insight.id)

      # A Historian with no runtime has no scope to act under.
      historian = historian!(runtime: false)
      assert {:error, :unauthorized} = Actions.apply_unattended(insight)
      assert page_state(key) == before

      # Control: give it a runtime and the same insight is applied.
      runtime_for!(historian, ["memory"])
      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(insight)
      assert Wiki.get_page(key).content == "Deploys go to host-b every night."
    end

    test "a Historian runtime without memory.write is refused", %{
      dreamer: dreamer,
      member: member
    } do
      historian = historian!(runtime: false)
      runtime_for!(historian, ["memory"], restriction: %{"memory.read" => "all"})

      {key, _page} = page!("Deploys go to host-a every night.", member)
      insight = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      before = page_state(key)

      assert {:error, :unauthorized} = Unattended.page_edit_actor(key)
      assert {:error, :unauthorized} = Actions.apply_unattended(insight)
      assert page_state(key) == before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # Control: a brain runtime that carries memory.write is the one the
      # Historian acts through.
      runtime_for!(historian, ["memory"])
      assert {:ok, %Insight{acted_by: acted_by}} = Actions.apply_unattended(insight)
      assert acted_by == historian.id
      assert Wiki.get_page(key).updated_by == historian.id
    end

    test "the unattended scope is the brain runtime's, never a later voice runtime's", %{
      dreamer: dreamer,
      member: member
    } do
      # Brain: memory read only. Voice: connected later, carries memory.write.
      historian = historian!(runtime: false)
      runtime_for!(historian, ["memory"], restriction: %{"memory.read" => "all"}, ago: 600)
      runtime_for!(historian, ["memory"], brain: false, ago: -60)

      {key, _page} = page!("Deploys go to host-a every night.", member)
      insight = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      before = page_state(key)

      assert {:error, :unauthorized} = Unattended.page_edit_actor(key)
      assert {:error, :unauthorized} = Actions.apply_unattended(insight)
      assert page_state(key) == before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # The dreaming agent likewise: a brain with no task module and a later
      # voice runtime with one still yields the brain runtime's scope.
      brain = runtime_for!(dreamer, ["memory"], ago: 600)
      runtime_for!(dreamer, ["task"], brain: false, ago: -60)
      assert {:ok, _agent, scope} = Unattended.task_actor()
      assert scope.actor.id == brain.id

      # Control: a brain carrying memory.write is what the Historian acts
      # through.
      runtime_for!(historian, ["memory"], ago: 1200)
      assert {:ok, %Insight{acted_by: acted_by}} = Actions.apply_unattended(insight)
      assert acted_by == historian.id
    end

    test "the wiki gate refuses a key the Historian may not write", %{
      dreamer: dreamer,
      member: member
    } do
      historian = historian!()
      other_agent = agent!("private-owner")
      private_key = "space/#{Ecto.UUID.generate()}/private/#{other_agent.id}/notes.md"
      {key, _page} = page!("Deploys go to host-a every night.", member, private_key)

      insight = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      assert insight.tier == "reversible"
      before = page_state(key)

      assert {:error, :unauthorized} = Unattended.page_edit_actor(key)
      assert {:error, :unauthorized} = Actions.apply_unattended(insight)
      assert page_state(key) == before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # Control: the same Historian, same runtime, an org page.
      {org_key, _} = page!("Deploys go to host-a every night.", member)
      org = ingest!(edit_block(org_key, "go to host-a", "go to host-b"), dreamer)
      assert {:ok, %Insight{acted_by: acted_by}} = Actions.apply_unattended(org)
      assert acted_by == historian.id
    end

    test "a page_edit whose source no longer resolves is downgraded to a question and the page is untouched",
         %{dreamer: dreamer, member: member} do
      historian!()
      {key, _page} = page!("Deploys go to host-a every night.", member)
      {source_key, _} = page!("Scratch notes that say host-b.", member)

      insight =
        ingest!(edit_block(key, "go to host-a", "go to host-b", "page:" <> source_key), dreamer)

      assert insight.action_type == "page_edit"

      {:ok, _} = Wiki.delete_page(source_key)
      before = page_state(key)

      assert {:ok, :downgraded, %Insight{} = question} = Actions.apply_unattended(insight)
      assert page_state(key) == before

      stored = Repo.get!(Insight, insight.id)
      assert stored.id == question.id
      assert stored.action_type == "question"
      assert stored.downgraded_from == "page_edit"
      assert stored.state == "open"
      assert stored.body =~ "Is this still true?"
      refute Map.has_key?(stored.action, "hunks")
      assert stored.addressee_user_id == member.id
      assert stored.acted_by == nil
      assert stored.pre_image == nil

      # A question is never applied unattended.
      assert {:error, :not_supported} = Actions.apply_unattended(stored)
      assert page_state(key) == before

      # Control: a page_edit whose source still resolves is applied.
      {key2, _} = page!("Deploys go to host-a every night.", member)
      grounded = ingest!(edit_block(key2, "go to host-a", "go to host-b"), dreamer)
      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(grounded)
    end

    test "an insight not authored by the dreaming agent is never applied unattended", %{
      dreamer: dreamer,
      member: member
    } do
      historian!()
      other = agent!("not-the-dreamer")
      {key, _page} = page!("Deploys go to host-a every night.", member)

      by_other = ingest!(edit_block(key, "go to host-a", "go to host-b"), other)
      by_nobody = ingest!(edit_block(key, "every night", "every morning"), nil)
      before = page_state(key)

      refute Unattended.eligible?(by_other)
      refute Unattended.eligible?(by_nobody)
      assert {:error, :not_eligible} = Actions.apply_unattended(by_other)
      assert {:error, :not_eligible} = Actions.apply_unattended(by_nobody)
      assert page_state(key) == before
      assert %Insight{state: "open"} = Repo.get!(Insight, by_other.id)
      assert %Insight{state: "open"} = Repo.get!(Insight, by_nobody.id)

      # Control: the same edit written by the dreaming agent is applied.
      mine = ingest!(edit_block(key, "go to host-a", "go to host-b"), dreamer)
      assert Unattended.eligible?(mine)
      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(mine)
      assert Wiki.get_page(key).content == "Deploys go to host-b every night."

      # Once memory.dreaming moves away from the agent that wrote the block
      # (here back to the historian role's bundle), the block is no longer
      # eligible: eligibility is judged against the CURRENT holder.
      :ok = Platform.Roles.clear_override("memory.dreaming")
      refute Unattended.eligible?(Repo.get!(Insight, mine.id))
    end
  end

  describe "task" do
    test "an unattended task is filed in backlog, unassigned, sponsored by the addressee", %{
      dreamer: dreamer,
      member: member
    } do
      runtime_for!(dreamer, ["task"])
      project = project!()
      insight = ingest!(task_block(project, member), dreamer)
      assert insight.addressee_user_id == member.id
      assert insight.tier == "reversible"
      tasks_before = Repo.aggregate(Task, :count)

      assert {:ok, %Insight{state: "done", artefact_ref: "task:" <> task_id} = acted} =
               Actions.apply_unattended(insight)

      assert Repo.aggregate(Task, :count) == tasks_before + 1
      filed = Repo.get!(Task, task_id)
      assert filed.project_id == project.id
      assert filed.status == "backlog"
      assert filed.assignee_id == nil
      assert filed.assignee_type == nil
      assert filed.phase_assignees == %{}
      assert filed.auto_approve_plan == false
      assert filed.sponsor_user_id == member.id
      assert filed.reported_by =~ insight.id
      assert filed.reported_by =~ dreamer.slug

      assert filed.metadata == %{
               "insight_id" => insight.id,
               "filed_by_agent_id" => dreamer.id
             }

      assert acted.acted_by == dreamer.id

      assert Repo.get!(Insight, insight.id).pre_image == %{
               "unattended" => true,
               "acting_agent_id" => dreamer.id
             }

      assert {:error, :not_open} = Actions.apply_unattended(insight)
      assert Repo.aggregate(Task, :count) == tasks_before + 1
    end

    test "no addressee -> no task", %{dreamer: dreamer, member: member} do
      runtime_for!(dreamer, ["task"])
      project = project!()
      insight = ingest!(task_block(project, nil), dreamer)
      assert insight.addressee_user_id == nil
      tasks_before = Repo.aggregate(Task, :count)

      assert {:error, :no_sponsor} = Actions.apply_unattended(insight)
      assert Repo.aggregate(Task, :count) == tasks_before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # Control: the same project with an addressee is filed.
      routed = ingest!(task_block(project, member), dreamer)
      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(routed)
      assert Repo.aggregate(Task, :count) == tasks_before + 1
    end

    test "a dreaming agent with no runtime files nothing", %{dreamer: dreamer, member: member} do
      project = project!()
      insight = ingest!(task_block(project, member), dreamer)
      tasks_before = Repo.aggregate(Task, :count)

      assert {:error, :no_agent} = Unattended.task_actor()
      assert {:error, :no_agent} = Actions.apply_unattended(insight)
      assert Repo.aggregate(Task, :count) == tasks_before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # Control.
      runtime_for!(dreamer, ["task"])
      assert {:ok, agent, _scope} = Unattended.task_actor()
      assert agent.id == dreamer.id
      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(insight)
    end
  end
end
