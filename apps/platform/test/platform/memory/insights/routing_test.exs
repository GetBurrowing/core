defmodule Platform.Memory.Insights.RoutingTest do
  @moduledoc """
  Task 01a13867 stage 2: `Routing.resolve/1`, rung by rung, with the reason
  string each rung reports. Each rung is shown to WIN over the ones below it
  (the next rung's evidence is present in the same fixture), so a resolver
  that reorders the rungs fails here.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Routing
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo

  defp n, do: System.unique_integer([:positive])

  defp user! do
    i = n()
    Repo.insert!(%User{email: "Rt-#{i}@Example.com", name: "RT #{i}", oidc_sub: "rt-#{i}"})
  end

  defp agent_with_owner!(owner) do
    i = n()

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "rt-agent-#{i}", name: "RT agent #{i}", status: "active"})
      |> Repo.insert!()

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "rt-rt-#{i}",
      owner_user_id: owner.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active"
    })
    |> Repo.insert!()

    agent
  end

  defp insight(attrs),
    do:
      struct(
        Insight,
        Map.merge(%{action_type: "briefing", action: %{}, workspace_id: nil}, attrs)
      )

  setup do
    _ = acme_org_id()

    page_editor = user!()
    page = "org/page/rt-#{n()}.md"
    {:ok, _} = Wiki.upsert_page(page, %{content: "x", updated_by: page_editor.id})

    sponsor = user!()
    {:ok, project} = Platform.Tasks.create_project(%{name: "rt-#{n()}", org_id: acme_org_id()})

    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: project.id,
        title: "rt",
        sponsor_user_id: sponsor.id
      })

    author = user!()
    {:ok, _} = Journal.append(%{content: "saw it", date: ~D[2026-10-16], authored_by: author.id})

    %{
      page: page,
      page_editor: page_editor,
      task: task,
      sponsor: sponsor,
      author: author,
      journal: "org/journal/2026-10-16.md"
    }
  end

  test "an explicit email addressee wins: named addressee", ctx do
    named = user!()

    i =
      insight(%{
        action: %{"addressee" => String.upcase(named.email), "target" => ctx.page},
        source_ref: "journal:#{ctx.journal}"
      })

    assert Routing.resolve(i) == {named.id, "named addressee"}
  end

  test "an explicit agent slug resolves to its runtime's owner: named agent's owner", ctx do
    owner = user!()
    agent = agent_with_owner!(owner)

    i = insight(%{action: %{"addressee" => agent.slug, "target" => ctx.page}})
    assert Routing.resolve(i) == {owner.id, "named agent's owner"}
  end

  test "an addressee that names nobody falls through to the next rung", ctx do
    i =
      insight(%{
        action: %{"addressee" => "no-such-agent-#{n()}", "target" => ctx.page},
        source_ref: "journal:#{ctx.journal}"
      })

    assert Routing.resolve(i) == {ctx.author.id, "journal author"}
  end

  test "the journal source's author: journal author", ctx do
    i = insight(%{action: %{"target" => ctx.page}, source_ref: "journal:#{ctx.journal}"})
    assert Routing.resolve(i) == {ctx.author.id, "journal author"}

    # The evidence pointer is read when the source is not a journal ref.
    by_evidence = insight(%{action: %{}, evidence: "#{ctx.journal}:12, org/page/other.md"})
    assert Routing.resolve(by_evidence) == {ctx.author.id, "journal author"}
  end

  test "an agent-authored journal entry maps to the agent's runtime owner", ctx do
    owner = user!()
    agent = agent_with_owner!(owner)

    {:ok, _} =
      Journal.append(%{content: "agent saw it", date: ~D[2026-10-14], authored_by: agent.id})

    i =
      insight(%{action: %{"target" => ctx.page}, source_ref: "journal:org/journal/2026-10-14.md"})

    assert Routing.resolve(i) == {owner.id, "owning agent's owner"}
  end

  test "a cited task's sponsor: task sponsor", ctx do
    i = insight(%{action: %{"target" => ctx.page}, source_ref: "task:#{ctx.task.id}"})
    assert Routing.resolve(i) == {ctx.sponsor.id, "task sponsor"}
  end

  test "the target page's updated_by: page editor", ctx do
    i = insight(%{action: %{"target" => ctx.page}, source_ref: "task:#{Ecto.UUID.generate()}"})
    assert Routing.resolve(i) == {ctx.page_editor.id, "page editor"}
  end

  test "nobody: unrouted" do
    assert Routing.resolve(insight(%{})) == {nil, "unrouted"}

    assert Routing.resolve(insight(%{action: %{"target" => "org/page/none-#{n()}.md"}})) ==
             {nil, "unrouted"}

    assert Routing.unrouted() == "unrouted"
  end
end
