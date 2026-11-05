defmodule Platform.People.ToolGuardTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.{Pages, ToolGuard, Visibility}
  alias Platform.Repo

  @subject_id "0193a1b2-0000-7000-8000-000000000001"

  @private """
  ---
  name: Marisol Tennebrook
  user_id: #{@subject_id}
  relation: team
  ---

  ## Role
  Platform lead.

  ## Interactions
  - 2026-10-02 meeting: Deploy review [cite: msg-1]

  ## Perspectives
  - I prefer small PRs — own words [cite: msg-3]
  - Seems to dislike meetings
  - She is difficult to work with and a bit flaky under pressure
  """

  @card """
  ---
  name: Oskar Vellinghausen
  relation: client
  ---

  ## Role
  Buyer. Reach him on 904-555-0100.
  """

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "hr-guard-#{System.unique_integer([:positive, :monotonic])}",
        name: "HR",
        status: "active"
      })
      |> Repo.insert()

    %{agent: agent}
  end

  test "before_write on a private profile drops an uncited perspective and a trait line and reports the counts",
       %{agent: agent} do
    path = Visibility.private_path("marisol-tennebrook")

    assert {:ok, body, counts} = ToolGuard.before_write(path, @private, agent, nil)

    assert body =~ "own words [cite: msg-3]"
    refute body =~ "dislike meetings"
    refute body =~ "difficult"
    assert body =~ "tier: private"
    assert body =~ "readers: [subject, admins]"

    assert counts.dropped_uncited_perspectives >= 1
    assert counts.dropped_trait_lines >= 1
    assert counts.dropped_uncited_perspectives + counts.dropped_trait_lines == 2
  end

  test "before_write on a card scrubs a phone number", %{agent: agent} do
    path = Visibility.card_path("oskar-vellinghausen")

    assert {:ok, body, counts} = ToolGuard.before_write(path, @card, agent, nil)

    refute body =~ "904-555-0100"
    assert body =~ "[REDACTED: phone]"
    assert body =~ "tier: card"
    assert counts.redactions == 1
  end

  test "before_write leaves a page outside org/page/people/ untouched", %{agent: agent} do
    body = "# Deploys\n\nCall 904-555-0100 when the pager fires.\n\n## Perspectives\n- whatever\n"

    assert {:ok, ^body, %{}} = ToolGuard.before_write("org/page/deploys.md", body, agent, nil)

    assert {:ok, ^body, %{}} =
             ToolGuard.before_write("org/journal/2026-10-03.md", body, agent, nil)
  end

  test "after_write regenerates the index and journals the paths once per ten minutes",
       %{agent: agent} do
    {:ok, _page, _} =
      Pages.write_card(
        nil,
        "priya-kalloway",
        "---\nname: Priya Kalloway\nrelation: team\n---\n\n## Role\nBuyer.\n",
        agent.id
      )

    assert Wiki.get_page(Visibility.index_path()) == nil

    assert :ok = ToolGuard.after_write(Visibility.card_path("priya-kalloway"), agent, nil)

    index = Wiki.get_page(Visibility.index_path())
    assert index.content =~ "**Priya Kalloway**"

    # a second write inside the window: index unchanged, journal line not repeated
    assert :ok = ToolGuard.after_write(Visibility.private_path("priya-kalloway"), agent, nil)

    lines =
      Date.utc_today()
      |> Journal.get_for_date()
      |> Enum.filter(&String.starts_with?(&1.content, "HR updated profiles:"))

    assert [line] = lines
    assert line.content == "HR updated profiles: org/page/people/priya-kalloway.md"
    assert line.metadata["agent_id"] == agent.id

    # the index itself is not a people write
    assert :ok = ToolGuard.after_write(Visibility.index_path(), agent, nil)
    assert :ok = ToolGuard.after_write("org/page/deploys.md", agent, nil)
    assert length(Journal.get_for_date(Date.utc_today())) == 1
  end
end
