defmodule Mix.Tasks.Platform.HrBackfillIndexRepairTest do
  @moduledoc """
  End to end: a people index flattened by a first backfill (every row under
  `## Unknown relation`, names lowercased, index-only people dropped) is
  repaired in place by a second backfill handed the saved hand-written index.
  Every name in the fixture is invented.
  """
  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.HrBackfill
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.{PageGuard, Pages, Privacy, Visibility}
  alias Platform.Repo

  # The hand-written index as it stood before the first backfill.
  @v7_index """
  ---
  title: People
  ---

  # People

  ## Team

  | Person | Role / organisation | Last seen |
  | --- | --- | --- |
  | **Avery Example** [[org/page/people/avery-example.md]] | Platform engineer | 2026-10-02 |
  | **Dana McAllister-Ruiz** [[org/page/people/dana-mcallister-ruiz.md]] |  | 2026-10-05 |
  | **Quinn Sample** [[org/page/people/quinn-sample.md]] | Designer |  |
  | **Rowan Fixture** [[org/page/people/rowan-fixture.md]] | Support lead | 2026-10-01 |

  ## Clients

  | Person | Role / organisation | Last seen |
  | --- | --- | --- |
  | **Casey Placeholder** [[org/page/people/casey-placeholder.md]] | Buyer / Example Freight | 2026-09-21 |
  | **Morgan Testwell** [[org/page/people/morgan-testwell.md]] | Operations / Sample Mills |  |
  | **Taylor Mockridge** | Founder / Mockridge Goods | 2026-09-30 |
  | **Emery Stub** [[org/page/people/emery-stub.md]] | Finance / Stub Holdings | 2026-09-15 |

  ## Collaborators

  | Person | Role / organisation | Last seen |
  | --- | --- | --- |
  | **Harper Dummyson** [[org/page/people/harper-dummyson.md]] | Illustrator |  |
  | **Sky Notreal** [[org/page/people/sky-notreal.md]] | Researcher | 2026-08-11 |
  | **Lane Imaginary** |  |  |
  | **Reese Pretend** [[org/page/people/reese-pretend.md]] | Editor |  |

  ## Contacts

  | Person | Phone |
  | --- | --- |
  | **Avery Example** | 904-555-0111 |
  | **Taylor Mockridge** | 904-555-0122 |
  | **Lane Imaginary** | 904-555-0133 |

  Call the front desk after hours.
  """

  # {name, slug, section, role, last seen}: what the repaired index must say.
  @people [
    {"Avery Example", "avery-example", "Team", "Platform engineer", "2026-10-02"},
    {"Dana McAllister-Ruiz", "dana-mcallister-ruiz", "Team", "Account manager", "2026-10-05"},
    {"Quinn Sample", "quinn-sample", "Team", "Designer", ""},
    {"Rowan Fixture", "rowan-fixture", "Team", "Support lead", "2026-10-01"},
    {"Casey Placeholder", "casey-placeholder", "Clients", "Buyer", "2026-09-21"},
    {"Morgan Testwell", "morgan-testwell", "Clients", "Operations lead", ""},
    {"Taylor Mockridge", "taylor-mockridge", "Clients", "Founder / Mockridge Goods",
     "2026-09-30"},
    {"Emery Stub", "emery-stub", "Clients", "Finance / Stub Holdings", "2026-09-15"},
    {"Harper Dummyson", "harper-dummyson", "Collaborators", "Illustrator", ""},
    {"Sky Notreal", "sky-notreal", "Collaborators", "Researcher", "2026-08-11"},
    {"Lane Imaginary", "lane-imaginary", "Collaborators", "", ""},
    {"Reese Pretend", "reese-pretend", "Collaborators", "Editor", ""}
  ]

  # Cards in the shape the first backfill left them: `tier: card`, an H1 and
  # the body's own `## Role` line, which wins over the index row and is cut
  # to its label.
  @cards %{
    "avery-example" => {"Avery Example", "Platform engineer"},
    "dana-mcallister-ruiz" => {"Dana McAllister-Ruiz", "Account manager"},
    "quinn-sample" => {"Quinn Sample", "Designer"},
    "casey-placeholder" => {"Casey Placeholder", "Buyer. Reach them on [REDACTED: phone]."},
    "morgan-testwell" => {"Morgan Testwell", "Operations lead - they run the depot"},
    "harper-dummyson" => {"Harper Dummyson", "Illustrator"},
    "sky-notreal" => {"Sky Notreal", "Researcher; they publish quarterly"}
  }

  @restored ["Rowan Fixture", "Taylor Mockridge", "Emery Stub", "Lane Imaginary", "Reese Pretend"]

  @phone_digits ["904-555", "0111", "0122", "0133"]

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    for {slug, {name, role}} <- @cards do
      role_section = if role, do: "\n## Role\n#{role}\n", else: ""

      {:ok, _} =
        Wiki.upsert_page(Visibility.card_path(slug), %{
          content: "---\ntier: card\n---\n\n# #{name}\n" <> role_section
        })
    end

    {:ok, _} = Wiki.upsert_page(Visibility.index_path(), %{content: v8_index()})
    :ok
  end

  # The index the first backfill stored: the 7 cards only, all under
  # `## Unknown relation`, names lowercased, roles and last seen empty.
  defp v8_index do
    rows =
      @cards
      |> Enum.sort_by(fn {_slug, {name, _}} -> String.downcase(name) end)
      |> Enum.map(fn {slug, {name, _}} ->
        "| **#{String.downcase(name)}** [[#{Visibility.card_path(slug)}]] |  |  |"
      end)

    Enum.join(
      [
        "---",
        "tier: index",
        "---",
        "",
        "# People",
        "",
        "## Unknown relation",
        "",
        "| Person | Role / organisation | Last seen |",
        "| --- | --- | --- |"
      ] ++
        rows ++
        ["", "_Generated from the person cards by HR; edit the card, not this index._", ""],
      "\n"
    )
  end

  defp snapshot do
    WikiPage
    |> Repo.all()
    |> Enum.map(&{&1.file_key, &1.content, &1.version, &1.updated_at})
    |> Enum.sort()
  end

  # The `## ` heading in force on the line naming `name` in bold.
  defp section_of(content, name) do
    content
    |> String.split("\n")
    |> Enum.reduce_while(nil, fn line, section ->
      cond do
        String.starts_with?(line, "## ") -> {:cont, String.trim_leading(line, "## ")}
        String.contains?(line, "**#{name}**") -> {:halt, {:found, section}}
        true -> {:cont, section}
      end
    end)
    |> case do
      {:found, section} -> section
      _ -> nil
    end
  end

  defp people_pages do
    Wiki.list_pages_under(Visibility.prefix(), workspace_id: nil)
  end

  test "backfill with the saved v7 index repairs a v8 index in place" do
    report = HrBackfill.backfill(previous_index: @v7_index)

    index = Wiki.get_page(Visibility.index_path()).content

    for {name, slug, section, role, last_seen} <- @people do
      row = "| **#{name}** [[#{Visibility.card_path(slug)}]] | #{role} | #{last_seen} |"
      assert index =~ row, "missing or wrong row for #{name}: #{row}\n#{index}"
      assert section_of(index, name) == section, "#{name} not under ## #{section}"
      refute index =~ "**#{String.downcase(name)}**"
    end

    refute index =~ "## Unknown relation"

    # no phone column and none of its digits on any people page
    pages = people_pages()
    assert length(pages) == 13

    for page <- pages do
      for digits <- @phone_digits, do: refute(page.content =~ digits, page.file_key)
      refute page.content =~ "Phone"
      refute page.content =~ "front desk"
      assert {_text, []} = Privacy.scrub(page.content), page.file_key
    end

    # nothing the backfill wrote needed the guard to act
    for %{counts: counts} <- report.rewritten,
        do: assert(Enum.all?(Map.values(counts), &(&1 == 0)))

    written = Enum.map(report.enriched, & &1.path) ++ report.created
    assert length(written) == 12

    for path <- written do
      {_content, counts} = PageGuard.enforce(:card, Wiki.get_page(path).content)
      assert Enum.all?(Map.values(counts), &(&1 == 0)), "#{path}: #{inspect(counts)}"
    end

    assert Enum.sort(report.created) ==
             @restored
             |> Enum.map(fn name ->
               {^name, slug, _, _, _} = List.keyfind(@people, name, 0)
               Visibility.card_path(slug)
             end)
             |> Enum.sort()

    roster = Pages.roster(nil)
    assert length(roster) == 12

    assert Enum.sort(Enum.map(roster, & &1.name)) ==
             Enum.sort(for {n, _, _, _, _} <- @people, do: n)

    assert Enum.all?(roster, &(&1.relation != "unknown"))
  end

  test "re-running the repair is idempotent" do
    first = HrBackfill.backfill(previous_index: @v7_index)
    assert first.index == :regenerated
    before = snapshot()
    journal = length(Journal.get_for_date(Date.utc_today()))
    assert journal == 1

    again = HrBackfill.backfill(previous_index: @v7_index)

    assert again.index == :unchanged
    assert again.enriched == []
    assert again.created == []
    assert again.rewritten == []
    assert snapshot() == before
    assert length(Journal.get_for_date(Date.utc_today())) == journal
  end

  test "dry run diff names the five restored people" do
    before = snapshot()

    dry = HrBackfill.backfill(previous_index: @v7_index, dry_run: true)

    assert snapshot() == before
    assert Journal.get_for_date(Date.utc_today()) == []

    added = Enum.filter(dry.index_diff, &String.starts_with?(&1, "+ "))

    for {name, _slug, _section, _role, _last_seen} <- @people do
      assert Enum.any?(added, &(&1 =~ "**#{name}**")), "no + line for #{name}"
    end

    for {_slug, {name, _}} <- @cards do
      assert Enum.any?(dry.index_diff, &(&1 =~ "- | **#{String.downcase(name)}**"))
    end

    for line <- dry.index_diff, digits <- @phone_digits, do: refute(line =~ digits)

    assert length(dry.created) == 5

    # the dry run's diff is what the real run stores
    HrBackfill.backfill(previous_index: @v7_index)
    stored = Wiki.get_page(Visibility.index_path()).content
    for "+ " <> line <- added, do: assert(stored =~ line)
  end
end
