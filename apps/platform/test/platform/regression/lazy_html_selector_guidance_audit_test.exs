defmodule Platform.Regression.LazyHtmlSelectorGuidanceAuditTest do
  @moduledoc """
  Docs-scan guard that keeps the agent-facing LazyHTML selector guidance from
  recommending `LazyHTML.filter/2` again (task `01a04a6f`).

  THE BUG BEING PINNED: `CLAUDE.md` — the file loaded into *every* agent
  working in this repo — told readers to "Debug selectors with
  `LazyHTML.from_fragment(html) |> LazyHTML.filter("selector")`", and
  `apps/platform/AGENTS.md` carried the same call in a worked example.

  `filter/2` matches only the fragment's **root nodes**. `query/2` descends.
  Measured against `lazy_html 0.1.10` on a fragment with `#deep` nested two
  divs down and `#root` at the top level:

      filter(doc, "#deep")   -> 0 nodes
      query(doc,  "#deep")   -> 1 node
      filter(doc, "#root")   -> 1 node     # filter is not broken, just root-scoped
      filter(doc, ".target") -> 1 node     # the root one only
      query(doc,  ".target") -> 2 nodes

  So an agent debugging a selector for a nested element got `[]` and had no way
  to tell that apart from "the element is not rendered". That is a false
  absence *manufactured by our own documentation*: the reader goes on to fix a
  defect that does not exist, or writes a test asserting absence that passes
  for the wrong reason.

  ## What is enforced, over every `*.md` in the repo

    1. **No `LazyHTML.filter(` call form in any markdown.** A call example is
       how the guidance propagates — a reader copies it. The arity form
       (`LazyHTML.filter/2`) in prose is deliberately still allowed, because
       `filter/2` has a legitimate narrow use and banning the name outright
       would make the docs unable to explain the distinction.

    2. **The caveat travels with the name.** Any blank-line-delimited paragraph
       mentioning `LazyHTML.filter` must also say `root node`. A reader who
       meets the name without the reason will reach for it again the moment it
       looks shorter; naming `query` alone is not a durable correction.

  ## What is deliberately NOT enforced

  **`LazyHTML.filter/2` in Elixir source.** There are zero call sites today
  (`LazyHTML.query` appears 287 times across 52 files in `test/`), and
  `filter/2` is *correct* for narrowing a node list you already hold. A source
  ban would contradict the guidance this audit exists to protect.

  ## Anti-vacuity

  `the docs scan is not vacuous` is the control: it fails if the markdown walk
  stops finding the corpus, or if either agent-facing doc loses the
  `LazyHTML.query(` recommendation this audit was written to keep in place. An
  empty offender list means nothing without it — the scan could simply have
  found no files.

  Cheap by construction (`File.read!` + `String` splits, no DB, no PubSub) and
  carries no `@moduletag`, so it runs in the default `mix test` set. Peer of
  `adr_citation_audit_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Platform.TestSupport.SourceIndex

  @repo_root Path.expand("../../../../..", __DIR__)

  # The CALL form. `LazyHTML.filter/2` (the arity form used in prose) does not
  # match — see rule 1 in the moduledoc.
  @call_form "LazyHTML.filter("

  # Any mention of the function at all, call form or arity form.
  @any_mention "LazyHTML.filter"

  @caveat "root node"

  @agent_facing ["CLAUDE.md", "apps/platform/AGENTS.md"]

  describe "LazyHTML selector guidance" do
    test "no markdown file shows a LazyHTML.filter/2 call example" do
      offenders =
        for {path, body} <- markdown_corpus(),
            {line, index} <- Enum.with_index(String.split(body, "\n"), 1),
            String.contains?(line, @call_form),
            do: "#{path}:#{index}: #{String.trim(line)}"

      assert offenders == [],
             """
             A markdown file shows `#{@call_form}...)` as a call example.

             `filter/2` matches only the fragment's root nodes, so a nested
             element returns `[]` — a false absence. Use `LazyHTML.query/2`,
             which descends the tree.

             #{Enum.join(offenders, "\n")}
             """
    end

    test "every paragraph naming LazyHTML.filter also states the root-node caveat" do
      offenders =
        for {path, body} <- markdown_corpus(),
            paragraph <- String.split(body, ~r/\n[ \t]*\n/),
            String.contains?(paragraph, @any_mention),
            not String.contains?(paragraph, @caveat),
            do: "#{path}: #{paragraph |> String.trim() |> String.slice(0, 200)}"

      assert offenders == [],
             """
             `LazyHTML.filter` is named without the words "#{@caveat}" nearby.

             The name alone is not a durable correction: a reader who does not
             know *why* `query/2` is required will reach for `filter/2` again.
             Keep "matches only the fragment's root nodes" in the same
             paragraph as the name.

             #{Enum.join(offenders, "\n")}
             """
    end

    test "the docs scan is not vacuous" do
      corpus = markdown_corpus()

      assert length(corpus) >= 50,
             "expected the markdown walk to find the repo's docs corpus, found #{length(corpus)} files"

      for relative <- @agent_facing do
        body = Enum.find_value(corpus, fn {path, body} -> path == relative && body end)

        assert body, "#{relative} was not found by the markdown walk"

        assert String.contains?(body, "LazyHTML.query("),
               "#{relative} no longer recommends a `LazyHTML.query(...)` call — " <>
                 "this audit only guards guidance that is actually present"
      end
    end
  end

  defp markdown_corpus do
    @repo_root
    |> Path.join("**/*.md")
    |> SourceIndex.wildcard()
    |> Enum.reject(
      &(String.contains?(&1, "/_build/") or String.contains?(&1, "/deps/") or
          String.contains?(&1, "/node_modules/") or String.contains?(&1, "/.git/"))
    )
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, @repo_root), SourceIndex.read!(&1)})
  end
end
