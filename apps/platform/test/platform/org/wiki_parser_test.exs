defmodule Platform.Org.WikiParserTest do
  @moduledoc """
  Table-driven tests for the pure parsers exposed by `Platform.Org.Wiki`:

    * `parse_frontmatter/1` — YAML frontmatter detection + parsing
    * `parse_wikilinks/1`   — `[[wikilink]]` extraction with code-region
      stripping

  Both are pure functions with no DB / process dependencies, so we run
  `async: true`.
  """
  use ExUnit.Case, async: true

  alias Platform.Org.Wiki

  # ── parse_frontmatter/1 ─────────────────────────────────────────────

  describe "parse_frontmatter/1" do
    @frontmatter_fixtures [
      {
        "no frontmatter — plain text returns {%{}, body}",
        "Just some markdown.\n\nWith a paragraph.\n",
        {%{}, "Just some markdown.\n\nWith a paragraph.\n"}
      },
      {
        "valid frontmatter with preamble: true",
        "---\npreamble: true\nowner: alice\n---\n# Body\n\ntext\n",
        {%{"preamble" => true, "owner" => "alice"}, "# Body\n\ntext\n"}
      },
      {
        "multiline string value (YAML > folded scalar)",
        "---\ntitle: An Org Page\ndescription: >\n  one long line\n  continued\n---\nbody here\n",
        {%{"title" => "An Org Page", "description" => "one long line continued\n"}, "body here\n"}
      },
      {
        "unclosed delimiter degrades to {%{}, original_body}",
        "---\npreamble: true\nno close here\nbody continues\n",
        {%{}, "---\npreamble: true\nno close here\nbody continues\n"}
      },
      {
        "second `---` later in body is body content, not a closer",
        "---\npreamble: true\n---\nfirst paragraph\n\n---\n\nsecond paragraph\n",
        {%{"preamble" => true}, "first paragraph\n\n---\n\nsecond paragraph\n"}
      },
      {
        "empty body returns {%{}, \"\"}",
        "",
        {%{}, ""}
      },
      {
        "frontmatter with list of strings",
        "---\ntags:\n  - alpha\n  - beta\n---\nbody\n",
        {%{"tags" => ["alpha", "beta"]}, "body\n"}
      },
      {
        "frontmatter that closes at EOF without trailing newline",
        "---\npreamble: true\n---",
        {%{"preamble" => true}, ""}
      }
    ]

    for {label, input, expected} <- @frontmatter_fixtures do
      test "#{label}" do
        assert Wiki.parse_frontmatter(unquote(input)) == unquote(Macro.escape(expected))
      end
    end

    test "non-string input returns {%{}, \"\"}" do
      assert Wiki.parse_frontmatter(nil) == {%{}, ""}
    end
  end

  # ── parse_wikilinks/1 ───────────────────────────────────────────────

  describe "parse_wikilinks/1" do
    @wikilink_fixtures [
      {
        "zero links",
        "Some text with no links at all.",
        []
      },
      {
        "one plain link",
        "See [[org/values]] for details.",
        [%{target_path: "org/values", display_text: nil, position: 0}]
      },
      {
        "one aliased link",
        "Refer to [[org/identity|the identity page]].",
        [%{target_path: "org/identity", display_text: "the identity page", position: 0}]
      },
      {
        "two of the same target produce distinct positions",
        "Link to [[a.md]] and again to [[a.md]].",
        [
          %{target_path: "a.md", display_text: nil, position: 0},
          %{target_path: "a.md", display_text: nil, position: 1}
        ]
      },
      {
        "link inside fenced code block is skipped",
        "Outside [[outside]] and:\n\n```\ninside the fence [[inside]]\n```\n\nback [[after]].",
        [
          %{target_path: "outside", display_text: nil, position: 0},
          %{target_path: "after", display_text: nil, position: 1}
        ]
      },
      {
        "link inside inline code is skipped",
        "A real link [[real]] and an inline `code [[fake]] thing` and [[also-real]].",
        [
          %{target_path: "real", display_text: nil, position: 0},
          %{target_path: "also-real", display_text: nil, position: 1}
        ]
      },
      {
        "empty target is silently skipped",
        "Bad [[]] and good [[good]].",
        [%{target_path: "good", display_text: nil, position: 0}]
      },
      {
        "whitespace-only target is silently skipped",
        "Bad [[   ]] and good [[good]].",
        [%{target_path: "good", display_text: nil, position: 0}]
      },
      {
        "display text containing pipe: only first pipe splits",
        "Tricky [[a|b|c]] link.",
        [%{target_path: "a", display_text: "b|c", position: 0}]
      },
      {
        "target with slash/hyphen/dot is fine",
        "Path-style [[project/abc-123/decisions.v2.md]] link.",
        [
          %{target_path: "project/abc-123/decisions.v2.md", display_text: nil, position: 0}
        ]
      }
    ]

    for {label, input, expected} <- @wikilink_fixtures do
      test "#{label}" do
        assert Wiki.parse_wikilinks(unquote(input)) == unquote(Macro.escape(expected))
      end
    end

    test "non-string input returns []" do
      assert Wiki.parse_wikilinks(nil) == []
    end
  end
end
