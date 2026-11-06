defmodule Platform.People.LegacyIndexTest do
  use ExUnit.Case, async: true

  alias Platform.People.LegacyIndex

  @index """
  ---
  title: People
  ---

  # People

  Free text before any section that must never be carried.

  ## Team

  | Person | Role | Last seen |
  | --- | --- | --- |
  | **Avery Example** [[org/page/people/avery-example.md]] | Platform engineer | 2026-10-02 |
  | **Quinn Example** | | |

  ## clients

  | Person | Phone | Role / organisation | Email |
  | --- | --- | --- | --- |
  | **Casey Placeholder** [[org/page/people/casey-placeholder.md]] | 904-555-0142 | Buyer / Example Freight | casey@example.com |

  ## Investors

  | Person | Notes |
  | --- | --- |
  | **Drew Sample** | met at the offsite, prefers mornings |

  ## Contacts

  | Person | Phone |
  | --- | --- |
  | **Robin Sample** | 904-555-0177 |
  """

  describe "parse/1" do
    test "one row per person with relation from the section heading" do
      rows = LegacyIndex.parse(@index)

      assert Enum.map(rows, & &1.name) ==
               [
                 "Avery Example",
                 "Quinn Example",
                 "Casey Placeholder",
                 "Drew Sample",
                 "Robin Sample"
               ]

      assert [avery, quinn, casey, drew, _robin] = rows

      assert avery == %{
               name: "Avery Example",
               path: "org/page/people/avery-example.md",
               relation: "team",
               role: "Platform engineer",
               last_seen: "2026-10-02"
             }

      assert quinn == %{
               name: "Quinn Example",
               path: nil,
               relation: "team",
               role: nil,
               last_seen: nil
             }

      assert casey.relation == "client"
      assert casey.path == "org/page/people/casey-placeholder.md"
      assert casey.role == "Buyer / Example Freight"
      assert drew.relation == "investor"
    end

    test "a phone column is never read" do
      rows = LegacyIndex.parse(@index)

      for row <- rows, value <- Map.values(row), is_binary(value) do
        refute value =~ "904-555", "row #{inspect(row)} carried a phone number"
        refute value =~ "@example.com"
        refute value =~ "mornings"
      end

      robin = Enum.find(rows, &(&1.name == "Robin Sample"))
      assert robin.role == nil
      assert robin.last_seen == nil
    end

    test "an unknown heading maps to unknown, not a guess" do
      rows = LegacyIndex.parse(@index)
      assert %{relation: "unknown"} = Enum.find(rows, &(&1.name == "Robin Sample"))

      before_heading = LegacyIndex.parse("| Person |\n| --- |\n| **Avery Example** |\n")
      assert [%{relation: "unknown"}] = before_heading
    end

    test "reads the generated index back, titles and escaped pipes included" do
      generated =
        Platform.People.Pages.render_index([
          %{
            name: "Avery Example",
            path: "org/page/people/avery-example.md",
            relation: "collaborator",
            role: "Design | research",
            organisation: "Example Studio",
            last_seen: "2026-10-02"
          }
        ])

      assert [row] = LegacyIndex.parse(generated)
      assert row.relation == "collaborator"
      assert row.path == "org/page/people/avery-example.md"
      assert row.role == "Design | research / Example Studio"
      assert row.last_seen == "2026-10-02"
    end

    test "rows without a bold name are skipped and nil/empty input is empty" do
      assert LegacyIndex.parse("## Team\n\n| Person |\n| --- |\n| plain text |\n") == []
      assert LegacyIndex.parse("") == []
      assert LegacyIndex.parse(nil) == []
    end
  end

  describe "derive_frontmatter/3" do
    @row %{
      name: "Avery Example",
      path: "org/page/people/avery-example.md",
      relation: "team",
      role: "Index role",
      last_seen: "2026-10-02"
    }

    test "the card body wins over the index row, existing keys win over both" do
      body =
        "# Avery Example\n\n## Role\n\n- Platform engineer\n- second line\n\n## Last seen\n2026-11-01\n"

      assert LegacyIndex.derive_frontmatter(body, %{}, @row) == %{
               "name" => "Avery Example",
               "relation" => "team",
               "role" => "Platform engineer",
               "last_seen" => "2026-11-01"
             }

      existing = %{"name" => "A. Example", "relation" => "client", "role" => "Kept"}

      assert LegacyIndex.derive_frontmatter(body, existing, @row) == %{
               "last_seen" => "2026-11-01"
             }
    end

    test "falls back to the index row when the body has nothing" do
      assert LegacyIndex.derive_frontmatter("## Current projects\n- Pilot\n", %{}, @row) == %{
               "name" => "Avery Example",
               "relation" => "team",
               "role" => "Index role",
               "last_seen" => "2026-10-02"
             }
    end

    test "an unknown relation stays unknown and unsourced keys are omitted" do
      row = %{@row | relation: "unknown", role: nil, last_seen: nil}

      assert LegacyIndex.derive_frontmatter("# Avery Example\n", %{}, row) == %{
               "name" => "Avery Example"
             }

      assert LegacyIndex.derive_frontmatter("", %{}, nil) == %{}
    end

    test "a blank existing value is treated as missing" do
      assert %{"role" => "Platform engineer"} =
               LegacyIndex.derive_frontmatter(
                 "## Role\nPlatform engineer\n",
                 %{"role" => " "},
                 nil
               )
    end

    test "an empty Role section does not borrow the next section's line" do
      body = "## Role\n\n## Current projects\n- Pilot\n"
      assert LegacyIndex.derive_frontmatter(body, %{}, nil) == %{}
    end
  end
end
