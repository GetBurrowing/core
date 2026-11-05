defmodule Platform.People.PagesTest do
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.{Pages, Visibility}
  alias Platform.Repo

  @updated_by "0193a1b2-0000-7000-8000-00000000aaaa"
  @subject_id "0193a1b2-0000-7000-8000-000000000001"

  @card """
  ---
  name: Marisol Tennebrook
  aliases: Mari
  user_id: #{@subject_id}
  relation: team
  organisation: the org
  role: platform lead
  last_seen: 2026-10-03
  ---

  ## Role
  Platform lead for the deploy pipeline. Call 904-555-0100 for pages.

  ## Current projects
  - Deploy pipeline
  """

  @private """
  ---
  name: Marisol Tennebrook
  user_id: #{@subject_id}
  relation: team
  ---

  ## Role
  Platform lead. Reach her on 904-555-0100.

  ## Interactions
  - 2026-10-02 meeting: Deploy review [cite: msg-1]

  ## Perspectives
  - I prefer small PRs — own words [cite: msg-3]
  """

  @legacy_index """
  ---
  title: People
  ---

  # People

  ## Contacts

  | Person | Phone |
  | --- | --- |
  | **Oskar Vellinghausen** | 904-555-0100 |

  Some free text about who to call when the pager goes off.
  """

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  defp card!(slug, name, relation, extra \\ "") do
    {:ok, _page, _counts} =
      Pages.write_card(
        nil,
        slug,
        "---\nname: #{name}\nrelation: #{relation}\n#{extra}---\n\n## Role\nSomething.\n",
        @updated_by
      )
  end

  test "write_private sets readers subject and admins and subject_user_id, write_card sets neither" do
    {:ok, private, _} = Pages.write_private(nil, "marisol-tennebrook", @private, @updated_by)
    {:ok, card, _} = Pages.write_card(nil, "marisol-tennebrook", @card, @updated_by)

    assert private.file_key == "org/page/people/marisol-tennebrook/private.md"
    assert Visibility.private_path?(private.file_key)
    assert private.frontmatter["tier"] == "private"
    assert private.frontmatter["readers"] == ["subject", "admins"]
    assert private.frontmatter["subject_user_id"] == @subject_id
    assert private.updated_by == @updated_by

    assert card.file_key == "org/page/people/marisol-tennebrook.md"
    assert card.frontmatter["tier"] == "card"
    refute Map.has_key?(card.frontmatter, "readers")
    refute Map.has_key?(card.frontmatter, "subject_user_id")

    # no account: admins (and agents) only, no subject key
    {:ok, no_account, _} =
      Pages.write_private(
        nil,
        "priya-kalloway",
        "---\nname: Priya Kalloway\nrelation: client\n---\n\n## Role\nBuyer.\n",
        @updated_by
      )

    assert no_account.frontmatter["readers"] == ["admins"]
    assert no_account.frontmatter["subject_user_id"] in [nil, ""]
  end

  test "write_card and write_private enforce the guard and scrub a phone number" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "pages-test-#{inspect(ref)}",
      [:platform, :people, :page_written],
      fn _event, _measurements, meta, _ -> send(parent, {:page_written, meta.paths}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pages-test-#{inspect(ref)}") end)

    {:ok, card, card_counts} = Pages.write_card(nil, "marisol-tennebrook", @card, @updated_by)

    {:ok, private, private_counts} =
      Pages.write_private(nil, "marisol-tennebrook", @private, @updated_by)

    refute card.content =~ "904-555"
    assert card.content =~ "[REDACTED: phone]"
    assert card_counts.redactions == 1

    refute private.content =~ "904-555"
    assert private.content =~ "[REDACTED: phone]"
    assert private_counts.redactions == 1

    # the card tier never carries the private sections
    refute card.content =~ "## Perspectives"
    assert private.content =~ "## Perspectives\n- I prefer small PRs — own words [cite: msg-3]"

    assert_receive {:page_written, ["org/page/people/marisol-tennebrook.md"]}
    assert_receive {:page_written, ["org/page/people/marisol-tennebrook/private.md"]}
  end

  test "regenerate_index groups cards by relation and drops free text from the old index" do
    {:ok, _} = Wiki.upsert_page(Visibility.index_path(), %{content: @legacy_index})
    assert %{names: ["Oskar Vellinghausen"], paths: []} = Pages.index_names(nil)

    card!(
      "marisol-tennebrook",
      "Marisol Tennebrook",
      "team",
      "role: platform lead\norganisation: the org\nlast_seen: 2026-10-03\n"
    )

    card!(
      "oskar-vellinghausen",
      "Oskar Vellinghausen",
      "client",
      "organisation: Vellinghausen GmbH\n"
    )

    card!("priya-kalloway", "Priya Kalloway", "Client")
    # a private page must never reach the index
    {:ok, _, _} = Pages.write_private(nil, "marisol-tennebrook", @private, @updated_by)

    assert {:ok, %WikiPage{} = index} = Pages.regenerate_index(nil, @updated_by)
    content = index.content

    refute content =~ "904-555"
    refute content =~ "Contacts"
    refute content =~ "pager goes off"

    assert content =~
             "## Team\n\n| Person | Role / organisation | Last seen |\n| --- | --- | --- |\n"

    assert content =~
             "| **Marisol Tennebrook** [[org/page/people/marisol-tennebrook.md]] | platform lead / the org | 2026-10-03 |"

    assert content =~ "## Clients"

    assert content =~
             "| **Oskar Vellinghausen** [[org/page/people/oskar-vellinghausen.md]] | Vellinghausen GmbH |  |"

    assert content =~ "| **Priya Kalloway** [[org/page/people/priya-kalloway.md]] |  |  |"
    refute content =~ "## Prospects"
    refute content =~ "private.md"

    assert String.ends_with?(
             content,
             "_Generated from the person cards by HR; edit the card, not this index._\n"
           )

    # Team precedes Clients
    {team_at, _} = :binary.match(content, "## Team")
    {clients_at, _} = :binary.match(content, "## Clients")
    assert team_at < clients_at

    assert %{names: names, paths: paths} = Pages.index_names(nil)
    assert Enum.sort(names) == ["Marisol Tennebrook", "Oskar Vellinghausen", "Priya Kalloway"]
    assert "org/page/people/marisol-tennebrook.md" in paths
  end

  test "regenerate_index is idempotent" do
    card!("marisol-tennebrook", "Marisol Tennebrook", "team")

    assert {:ok, %WikiPage{version: v1}} = Pages.regenerate_index(nil, @updated_by)
    assert {:ok, :unchanged} = Pages.regenerate_index(nil, @updated_by)
    assert %WikiPage{version: ^v1} = Wiki.get_page(Visibility.index_path())

    # a new card changes the roster, so the index is written once more
    card!("priya-kalloway", "Priya Kalloway", "prospect")
    assert {:ok, %WikiPage{version: v2}} = Pages.regenerate_index(nil, @updated_by)
    assert v2 > v1
    assert {:ok, :unchanged} = Pages.regenerate_index(nil, @updated_by)
  end

  test "roster skips private pages and flags legacy cards" do
    card!(
      "marisol-tennebrook",
      "Marisol Tennebrook",
      "team",
      "aliases: Mari, M.T.\nuser_id: #{@subject_id}\n"
    )

    {:ok, _, _} = Pages.write_private(nil, "marisol-tennebrook", @private, @updated_by)

    # a legacy card written before the tier key existed
    {:ok, _} =
      Wiki.upsert_page("org/page/people/oskar-vellinghausen.md", %{
        content: "---\nname: Oskar Vellinghausen\n---\n\n## Role\nFounder.\n"
      })

    # the index and a private-tier page at a card path are not cards
    {:ok, _} = Wiki.upsert_page(Visibility.index_path(), %{content: @legacy_index})

    {:ok, _} =
      Wiki.upsert_page("org/page/people/stray.md", %{content: "---\ntier: private\n---\n"})

    roster = Pages.roster(nil)
    assert Enum.map(roster, & &1.slug) == ["marisol-tennebrook", "oskar-vellinghausen"]

    marisol = Enum.at(roster, 0)
    assert marisol.path == "org/page/people/marisol-tennebrook.md"
    assert marisol.name == "Marisol Tennebrook"
    assert marisol.aliases == ["Mari", "M.T."]
    assert marisol.user_id == @subject_id
    assert marisol.relation == "team"
    assert %DateTime{} = marisol.updated_at
    refute marisol.legacy

    oskar = Enum.at(roster, 1)
    assert oskar.legacy
    assert oskar.relation == "unknown"
    assert oskar.aliases == []

    refute Enum.any?(roster, &Visibility.private_path?(&1.path))
    assert Visibility.tier_of("org/page/people/marisol-tennebrook/private.md") == :private
    assert Visibility.tier_of(Visibility.index_path()) == :index
    assert Visibility.tier_of("org/page/other.md") == :unknown
  end
end
