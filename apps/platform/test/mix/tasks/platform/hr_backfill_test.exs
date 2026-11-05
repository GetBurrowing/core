defmodule Mix.Tasks.Platform.HrBackfillTest do
  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.HrBackfill
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.Visibility
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

    # the still-good card is untouched
    assert Wiki.get_page(Visibility.card_path("marisol-tennebrook")).version == 1

    assert [entry] = Journal.get_for_date(Date.utc_today())

    assert entry.content =~
             "HR backfill: rewrote legacy cards org/page/people/oskar-vellinghausen.md"

    assert entry.content =~ "index-only names Priya Kalloway"
    assert entry.metadata["source"] == "people:hr_backfill"

    # idempotent: a second run finds nothing and writes nothing
    again = HrBackfill.backfill()
    assert again.legacy_cards == []
    assert again.rewritten == []
    assert again.index == :unchanged
    assert length(Journal.get_for_date(Date.utc_today())) == 1

    lines = HrBackfill.lines(report)
    assert Enum.any?(lines, &(&1 =~ "Legacy cards (1)"))
    assert Enum.any?(lines, &(&1 =~ "Priya Kalloway"))
  end
end
