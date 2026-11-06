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
  Buyer. Reach them on 904-555-0100.

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

    # the index-only person stays on the index through a minimal card that
    # carries her name only: never the phone column
    assert report.created == [Visibility.card_path("priya-kalloway")]
    assert index.content =~ "**Priya Kalloway** [[org/page/people/priya-kalloway.md]]"
    priya = Wiki.get_page(Visibility.card_path("priya-kalloway"))
    assert priya.content == "---\ntier: card\nname: \"Priya Kalloway\"\n---\n\n# Priya Kalloway\n"

    # the already-tiered card gains only the role its own body states; the
    # body and the existing keys are untouched
    marisol = Wiki.get_page(Visibility.card_path("marisol-tennebrook"))
    assert marisol.frontmatter["role"] == "Lead."
    assert marisol.frontmatter["relation"] == "team"
    assert marisol.content =~ "## Role\nLead.\n"

    # the legacy card's role comes from its scrubbed body, never the phone column
    assert card.frontmatter["role"] == "Buyer"
    refute card.frontmatter["role"] =~ "REDACTED"

    assert Enum.sort_by(report.enriched, & &1.path) == [
             %{path: Visibility.card_path("marisol-tennebrook"), added: ["role"]},
             %{path: Visibility.card_path("oskar-vellinghausen"), added: ["role"]}
           ]

    assert index.content =~ "| Lead. |"

    assert [entry] = Journal.get_for_date(Date.utc_today())

    assert entry.content =~
             "HR backfill: rewrote legacy cards org/page/people/oskar-vellinghausen.md"

    assert entry.content =~ "index-only names Priya Kalloway"
    assert entry.content =~ "created org/page/people/priya-kalloway.md"
    assert entry.metadata["created"] == [Visibility.card_path("priya-kalloway")]
    assert entry.metadata["source"] == "people:hr_backfill"
    assert length(entry.metadata["enriched"]) == 2

    # idempotent: a second run finds nothing and writes nothing
    again = HrBackfill.backfill()
    assert again.legacy_cards == []
    assert again.rewritten == []
    assert again.enriched == []
    assert again.created == []
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

  defp snapshot do
    WikiPage
    |> Repo.all()
    |> Enum.map(&{&1.file_key, &1.content, &1.version, &1.updated_at})
    |> Enum.sort()
  end

  defp card_paths do
    nil |> Pages.roster() |> Enum.map(& &1.path) |> Enum.sort()
  end

  test "an index-only person becomes a minimal card and stays on the index" do
    report = HrBackfill.backfill(previous_index: @previous_index)

    assert report.created == [
             Visibility.card_path("avery-example"),
             Visibility.card_path("casey-placeholder"),
             Visibility.card_path("robin-sample")
           ]

    # only the Person name, the heading's relation, the Role column and the
    # Last seen column: no phone, no other section
    assert Wiki.get_page(Visibility.card_path("avery-example")).content ==
             "---\ntier: card\nname: \"Avery Example\"\nrelation: team\nrole: \"Index role\"\nlast_seen: \"2026-10-02\"\n---\n\n# Avery Example\n"

    assert Wiki.get_page(Visibility.card_path("casey-placeholder")).content ==
             "---\ntier: card\nname: \"CASEY PLACEHOLDER\"\nrelation: client\nrole: \"Buyer / Example Freight\"\nlast_seen: \"2026-09-21\"\n---\n\n# CASEY PLACEHOLDER\n"

    # a heading that is not a relation leaves the relation key out entirely
    assert Wiki.get_page(Visibility.card_path("robin-sample")).content ==
             "---\ntier: card\nname: \"Robin Sample\"\n---\n\n# Robin Sample\n"

    roster = Map.new(Pages.roster(nil), &{&1.slug, &1})
    assert roster["avery-example"].relation == "team"
    assert roster["casey-placeholder"].name == "CASEY PLACEHOLDER"
    assert roster["robin-sample"].relation == "unknown"

    index = Wiki.get_page(Visibility.index_path())

    assert index.content =~
             "| **Avery Example** [[org/page/people/avery-example.md]] | Index role | 2026-10-02 |"

    assert index.content =~ "**CASEY PLACEHOLDER** [[org/page/people/casey-placeholder.md]]"
    assert index.content =~ "**Robin Sample** [[org/page/people/robin-sample.md]]"
    refute index.content =~ "904-555"

    # the card makes the person durable for every other index writer
    assert {:ok, :unchanged} = Pages.regenerate_index(nil, nil)
  end

  test "a bold-and-linked index-only row creates exactly one card" do
    {:ok, _} =
      Wiki.upsert_page(Visibility.index_path(), %{
        content: """
        # People

        ## Team

        | Person | Role |
        | --- | --- |
        | **Avery Example** [[org/page/people/avery-example.md]] | Platform engineer |

        ## Contacts

        | Person | Phone |
        | --- | --- |
        | **avery example** | 904-555-0142 |
        """
      })

    before = card_paths()
    report = HrBackfill.backfill()

    # the name and the link slug are reported separately, as before
    assert report.index_only_names == ["Avery Example", "avery example", "avery-example"]

    assert report.created == [Visibility.card_path("avery-example")]
    assert card_paths() -- before == [Visibility.card_path("avery-example")]

    avery = Wiki.get_page(Visibility.card_path("avery-example"))
    assert avery.frontmatter["relation"] == "team"
    assert avery.frontmatter["role"] == "Platform engineer"
    refute avery.content =~ "904-555"
  end

  test "an existing private page blocks minimal-card creation" do
    private = "---\ntier: private\nreaders: [admins]\n---\n\n# Robin Sample\n\nNotes.\n"
    {:ok, _} = Wiki.upsert_page(Visibility.private_path("robin-sample"), %{content: private})

    report = HrBackfill.backfill(previous_index: @previous_index)

    refute Visibility.card_path("robin-sample") in report.created
    assert Visibility.card_path("avery-example") in report.created
    assert Wiki.get_page(Visibility.card_path("robin-sample")) == nil
    assert Wiki.get_page(Visibility.private_path("robin-sample")).content == private
  end

  test "dry run prints the index diff and writes nothing" do
    before = snapshot()

    report = HrBackfill.backfill(previous_index: @previous_index, dry_run: true)

    assert snapshot() == before
    assert Journal.get_for_date(Date.utc_today()) == []

    assert report.created == [
             Visibility.card_path("avery-example"),
             Visibility.card_path("casey-placeholder"),
             Visibility.card_path("robin-sample")
           ]

    assert Enum.map(report.rewritten, & &1.path) == [Visibility.card_path("oskar-vellinghausen")]
    assert Enum.any?(report.enriched, &(&1.path == Visibility.card_path("marisol-tennebrook")))

    # a removed line echoes the stored index, scrubbed: no phone digits
    assert "- | **Priya Kalloway** | [REDACTED: phone] |" in report.index_diff
    refute Enum.any?(report.index_diff, &(&1 =~ "904-555"))
    assert "- Some free text about who to call when the pager goes off." in report.index_diff

    assert "+ | **Avery Example** [[org/page/people/avery-example.md]] | Index role | 2026-10-02 |" in report.index_diff

    assert "+ | **Marisol Tennebrook** [[org/page/people/marisol-tennebrook.md]] | Lead. |  |" in report.index_diff

    refute Enum.any?(report.index_diff, &(String.starts_with?(&1, "+ ") and &1 =~ "904-555"))

    # the in-memory roster renders exactly what the real run then stores
    expected_added =
      for line <- report.index_diff,
          String.starts_with?(line, "+ "),
          do: String.trim_leading(line, "+ ")

    real = HrBackfill.backfill(previous_index: @previous_index)
    assert real.created == report.created
    stored = Wiki.get_page(Visibility.index_path()).content
    for line <- expected_added, do: assert(stored =~ line)

    lines = HrBackfill.lines(report)
    assert "Index diff:" in lines

    assert "  + | **Avery Example** [[org/page/people/avery-example.md]] | Index role | 2026-10-02 |" in lines

    assert "  created org/page/people/robin-sample.md" in lines
    assert List.last(lines) == "Dry run: nothing written."
  end

  test "second run writes nothing" do
    first = HrBackfill.backfill(previous_index: @previous_index)
    assert first.created != []
    assert [_] = Journal.get_for_date(Date.utc_today())
    cards = card_paths()
    before = snapshot()

    # the stored index is now the generated one: every row links to a card
    again = HrBackfill.backfill()

    assert again.rewritten == []
    assert again.enriched == []
    assert again.created == []
    assert again.index == :unchanged
    assert snapshot() == before
    assert card_paths() == cards
    assert [_] = Journal.get_for_date(Date.utc_today())

    # handing the same previous index in again creates no duplicate card and
    # enriches nothing: the minimal cards already carry the row's last seen
    same = HrBackfill.backfill(previous_index: @previous_index)
    assert same.created == []
    assert same.enriched == []
    assert snapshot() == before
    assert card_paths() == cards
  end
end
