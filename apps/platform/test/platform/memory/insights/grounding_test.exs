defmodule Platform.Memory.Insights.GroundingTest do
  @moduledoc """
  Task 01a13867 stage 2: the closed source grammar, and the ingest-time
  downgrade of an ungrounded `page_edit` to a question to the fact's owner.

  Each downgrade assertion sits beside its positive control: the SAME edit
  with a source that resolves stays a `page_edit`. Mutation probe (a) in the
  stage text (`grounded?/1` always true) turns the downgrade test red.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Grounding
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo

  @journal "org/journal/2026-10-18.md"

  defp n, do: System.unique_integer([:positive])

  defp user! do
    i = n()
    Repo.insert!(%User{email: "gr-#{i}@example.com", name: "GR #{i}", oidc_sub: "gr-#{i}"})
  end

  defp agent_with_owner!(owner) do
    i = n()

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "gr-agent-#{i}", name: "GR agent #{i}", status: "active"})
      |> Repo.insert!()

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "gr-rt-#{i}",
      owner_user_id: owner.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active"
    })
    |> Repo.insert!()

    agent
  end

  defp page_edit(target, source) do
    source_attr = if source, do: ~s( source="#{source}"), else: ""

    ~s(<synthesis-insight action="page_edit" confidence="high" target="#{target}"#{source_attr}>
    The runbook still names the old deploy host.
    <old>deploy to host-a</old><new>deploy to host-b</new>
    </synthesis-insight>)
  end

  defp ingest_one!(content) do
    {:ok, 1} = Insights.ingest_from_journal(nil, @journal, content)
    [insight] = Repo.all(Insight)
    insight
  end

  setup do
    _root = acme_org_id()
    :ok
  end

  describe "the downgrade" do
    test "an ungrounded page_edit downgrades to a question to the page owner" do
      owner = user!()
      target = "org/page/runbook-#{n()}.md"

      {:ok, _} =
        Wiki.upsert_page(target, %{content: "Steps: deploy to host-a.", updated_by: owner.id})

      # Positive control: the same edit citing the page itself stays a page_edit.
      grounded = ingest_one!(page_edit(target, "page:#{target}"))
      assert grounded.action_type == "page_edit"
      assert grounded.downgraded_from == nil
      assert [%{"old" => "deploy to host-a"}] = grounded.action["hunks"]
      Repo.delete_all(Insight)

      for source <- [nil, "page:org/page/nowhere-#{n()}.md", "rumour:hallway", "query:select 1"] do
        q = ingest_one!(page_edit(target, source))

        assert q.action_type == "question", "source #{inspect(source)}"
        assert q.downgraded_from == "page_edit"
        assert q.body == "Is this still true? The runbook still names the old deploy host."
        refute Map.has_key?(q.action, "hunks")
        assert q.action["target"] == target
        assert q.addressee_user_id == owner.id
        assert q.addressee_reason == "page owner"
        Repo.delete_all(Insight)
      end
    end

    test "an agent-written page routes the question to the agent's runtime owner" do
      owner = user!()
      agent = agent_with_owner!(owner)
      target = "org/page/agents-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(target, %{content: "deploy to host-a", updated_by: agent.id})

      q = ingest_one!(page_edit(target, nil))
      assert q.action_type == "question"
      assert q.addressee_user_id == owner.id
      assert q.addressee_reason == "page owner (owning agent's owner)"
    end

    test "a page with no author leaves the question unrouted" do
      target = "org/page/orphan-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(target, %{content: "deploy to host-a", updated_by: nil})

      q = ingest_one!(page_edit(target, nil))
      assert q.action_type == "question"
      assert q.addressee_user_id == nil
      assert q.addressee_reason == "unrouted"
    end

    test "a non-page_edit insight is never rewritten, grounded or not" do
      q =
        ingest_one!(~s(<synthesis-insight action="briefing" confidence="high" source="rumour:x">
        Deploys moved to host-b.
        </synthesis-insight>))

      assert q.action_type == "briefing"
      assert q.downgraded_from == nil
    end
  end

  describe "query:agent_runtimes.last_connected_at" do
    test "query:agent_runtimes.last_connected_at grounds an agents.md edit" do
      owner = user!()
      agent = agent_with_owner!(owner)
      connected = ~U[2026-10-17 09:00:00.000000Z]

      Repo.update_all(AgentRuntime, set: [last_connected_at: connected])

      target = "org/page/agents.md"

      {:ok, _} =
        Wiki.upsert_page(target, %{
          content: "#{agent.slug} last connected: never",
          updated_by: owner.id
        })

      edit =
        ~s(<synthesis-insight action="page_edit" confidence="high" target="#{target}" source="query:agent_runtimes.last_connected_at">
      #{agent.slug} has connected since the page was written.
      <old>last connected: never</old><new>last connected: 2026-10-17</new>
      </synthesis-insight>)

      insight = ingest_one!(edit)
      assert insight.action_type == "page_edit"
      assert insight.downgraded_from == nil

      # The rows a preview cites carry the slug and the timestamp.
      assert "agent_runtimes.last_connected_at" in Grounding.queries()
      assert {:ok, rows} = Grounding.run_query("agent_runtimes.last_connected_at")

      assert %{slug: slug, last_connected_at: ^connected} =
               Enum.find(rows, &(&1.slug == agent.slug))

      assert slug == agent.slug

      # Negative: an unlisted name does not ground the same edit.
      Repo.delete_all(Insight)
      ungrounded = String.replace(edit, "query:agent_runtimes.last_connected_at", "query:agents")
      assert ingest_one!(ungrounded).action_type == "question"
      assert Grounding.run_query("agents") == :error
    end
  end

  describe "grounded?/1" do
    test "each form resolves only when its row exists" do
      page = "org/page/g-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(page, %{content: "x"})
      assert Grounding.grounded?("page:#{page}")
      refute Grounding.grounded?("page:org/page/missing-#{n()}.md")

      {:ok, _} = Journal.append(%{content: "an entry", date: ~D[2026-10-16]})
      assert Grounding.grounded?("journal:org/journal/2026-10-16.md")
      refute Grounding.grounded?("journal:org/journal/2026-10-15.md")
      refute Grounding.grounded?("journal:org/page/not-a-journal.md")

      {:ok, project} = Platform.Tasks.create_project(%{name: "gr-#{n()}", org_id: acme_org_id()})
      {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: "gr task"})
      assert Grounding.grounded?("task:#{task.id}")
      refute Grounding.grounded?("task:#{Ecto.UUID.generate()}")
      refute Grounding.grounded?("task:higginshigginsxx")

      refute Grounding.grounded?("message:#{Ecto.UUID.generate()}")
      refute Grounding.grounded?("message:not-a-uuid")

      assert Grounding.grounded?("query:agent_runtimes.last_connected_at")
      refute Grounding.grounded?("query:")
      refute Grounding.grounded?(nil)
      refute Grounding.grounded?("")
      refute Grounding.grounded?("url:https://example.com")
    end
  end
end
