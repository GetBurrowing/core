defmodule Mix.Tasks.Platform.HrBackfillTest do
  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.HrBackfill
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.{Pages, Visibility}
  alias Platform.Repo

  @legacy_card """
  ---
  name: Oskar Vellinghausen
  relation: client
  organisation: Vellinghausen Logistics
  ---

  ## Role
  Buyer. Reach him on 904-555-0100.

  ## Interactions
  - 2026-09-30 call: Pricing [cite: msg-9]

  ## Perspectives
  - Seems to dislike long meetings
  - Wants quarterly invoices — own words [cite: msg-10]
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
  | **Priya Kalloway** | 904-555-0199 |

  Some free text about who to call when the pager goes off.
  """

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    {:ok, _} =
      Wiki.upsert_page(Visibility.card_path("oskar-vellinghausen"), %{content: @legacy_card})

    {:ok, _} = Wiki.upsert_page(Visibility.index_path(), %{content: @legacy_index})

    {:ok, _} =
      Wiki.upsert_page(Visibility.card_path("marisol-tennebrook"), %{
        content:
          "---\ntier: card\nname: Marisol Tennebrook\nrelation: team\n---\n\n## Role\nLead.\n"
      })

    :ok
  end

  test "rewrites legacy cards through the guard and regenerates the index without the contacts row" do
    assert Code.ensure_loaded?(HrBackfill)

    dry = HrBackfill.backfill(dry_run: true)
    assert dry.legacy_cards == [Visibility.card_path("oskar-vellinghausen")]
    assert dry.index_only_names == ["Priya Kalloway"]
    assert Wiki.get_page(Visibility.card_path("oskar-vellinghausen")).content == @legacy_card

    report = HrBackfill.backfill()

    assert report.legacy_cards == [Visibility.card_path("oskar-vellinghausen")]
    assert report.index_only_names == ["Priya Kalloway"]
    assert [%{path: path, counts: counts}] = report.rewritten
    assert path == Visibility.card_path("oskar-vellinghausen")
    assert counts.dropped_card_sections == 2
    assert counts.redactions == 1
    assert report.index == :regenerated

    card = Wiki.get_page(path)
    assert card.frontmatter["tier"] == "card"
    assert card.frontmatter["name"] == "Oskar Vellinghausen"
    refute card.content =~ "904-555-0100"
    refute card.content =~ "## Perspectives"
    refute card.content =~ "## Interactions"
    refute card.content =~ "dislike"
    assert card.content =~ "## Role"

    index = Wiki.get_page(Visibility.index_path())
    assert index.frontmatter["tier"] == "index"
    refute index.content =~ "Contacts"
    refute index.content =~ "904-555"
    refute index.content =~ "pager"
    assert index.content =~ "**Oskar Vellinghausen**"
    assert index.content =~ "**Marisol Tennebrook**"
    refute index.content =~ "Priya Kalloway"

    # the already-tiered card gains only the role its own body states; the
    # body and the existing keys are untouched
    marisol = Wiki.get_page(Visibility.card_path("marisol-tennebrook"))
    assert marisol.frontmatter["role"] == "Lead."
    assert marisol.frontmatter["relation"] == "team"
    assert marisol.content =~ "## Role\nLead.\n"

    # the legacy card's role comes from its scrubbed body, never the phone column
    assert card.frontmatter["role"] == "Buyer. Reach him on [REDACTED: phone]."

    assert Enum.sort_by(report.enriched, & &1.path) == [
             %{path: Visibility.card_path("marisol-tennebrook"), added: ["role"]},
             %{path: Visibility.card_path("oskar-vellinghausen"), added: ["role"]}
           ]

    assert index.content =~ "| Lead. |"

    assert [entry] = Journal.get_for_date(Date.utc_today())

    assert entry.content =~
             "HR backfill: rewrote legacy cards org/page/people/oskar-vellinghausen.md"

    assert entry.content =~ "index-only names Priya Kalloway"
    assert entry.metadata["source"] == "people:hr_backfill"
    assert length(entry.metadata["enriched"]) == 2

    # idempotent: a second run finds nothing and writes nothing
    again = HrBackfill.backfill()
    assert again.legacy_cards == []
    assert again.rewritten == []
    assert again.enriched == []
    assert again.index == :unchanged
    assert length(Journal.get_for_date(Date.utc_today())) == 1

    lines = HrBackfill.lines(report)
    assert Enum.any?(lines, &(&1 =~ "Legacy cards (1)"))
    assert Enum.any?(lines, &(&1 =~ "Priya Kalloway"))
  end

  @previous_index """
  ---
  title: People
  ---

  # People

  ## Team

  | Person | Role | Phone | Last seen |
  | --- | --- | --- | --- |
  | **Avery Example** [[org/page/people/avery-example.md]] | Index role | 904-555-0142 | 2026-10-02 |

  ## Clients

  | Person | Role / organisation | Last seen |
  | --- | --- | --- |
  | **CASEY PLACEHOLDER** | Buyer / Example Freight | 2026-09-21 |

  ## Contacts

  | Person | Phone |
  | --- | --- |
  | **Robin Sample** | 904-555-0177 |
  """

  test "derives relation and role for already-tiered cards from the previous index" do
    {:ok, _} =
      Wiki.upsert_page(Visibility.card_path("avery-example"), %{
        content: "---\ntier: card\n---\n\n# Avery Example\n\n## Role\n- Platform engineer\n"
      })

    {:ok, _} =
      Wiki.upsert_page(Visibility.card_path("casey-placeholder"), %{
        content: "---\ntier: card\n---\n\n# Casey Placeholder\n\n## Current projects\n- Pilot\n"
      })

    {:ok, _} =
      Wiki.upsert_page(Visibility.card_path("robin-sample"), %{
        content: "---\ntier: card\n---\n\n# Robin Sample\n"
      })

    report = HrBackfill.backfill(previous_index: @previous_index)

    roster = Map.new(Pages.roster(nil), &{&1.slug, &1})

    avery = roster["avery-example"]
    assert avery.relation == "team"
    assert avery.role == "Platform engineer"
    assert avery.last_seen == "2026-10-02"
    assert avery.name == "Avery Example"

    casey = roster["casey-placeholder"]
    assert casey.relation == "client"
    assert casey.role == "Buyer / Example Freight"
    assert casey.last_seen == "2026-09-21"
    assert casey.name == "Casey Placeholder"

    # an index heading that is not a relation leaves the relation unknown
    robin = roster["robin-sample"]
    assert robin.relation == "unknown"
    assert robin.role == nil

    for slug <- ["avery-example", "casey-placeholder", "robin-sample"] do
      page = Wiki.get_page(Visibility.card_path(slug))
      refute page.content =~ "904-555"
      assert page.frontmatter["tier"] == "card"
    end

    assert %{added: ["last_seen", "name", "relation", "role"]} =
             Enum.find(report.enriched, &(&1.path == Visibility.card_path("casey-placeholder")))

    index = Wiki.get_page(Visibility.index_path())
    assert index.content =~ "## Team"
    assert index.content =~ "## Clients"
    assert index.content =~ "**Avery Example**"
    refute index.content =~ "904-555"

    again = HrBackfill.backfill(previous_index: @previous_index)
    assert again.enriched == []
  end
end
