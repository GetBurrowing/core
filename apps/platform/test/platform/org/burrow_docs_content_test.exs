defmodule Platform.Org.BurrowDocsContentTest do
  @moduledoc """
  Content checks for the Burrow Docs corpus, `docs/burrow/*.md` (task 01a10a44
  stages 3 and 4).

  Every check is a pure function from a content string to a list of error
  strings, so each one is exercised twice: against every real doc (which must
  return `[]`), and against a fixture built to violate it (which must return a
  non-empty list naming the violation). The corpus is found by globbing
  `docs/burrow`; no file name is listed here, so a doc added later is covered
  without editing this file.
  """

  use ExUnit.Case, async: true

  alias Platform.Federation.ToolSurface
  alias Platform.Org.BurrowDocs.Source
  alias Platform.Org.Wiki

  @docs_dir Path.expand("../../../../../docs/burrow", __DIR__)

  # `index.md` is the corpus's table of contents, not a topic page. The
  # four-section check applies to every OTHER page; check 5 (the index lists
  # every topic) applies to the index alone. The other checks apply to all.
  @index_basename "index.md"

  @sections ["## What it is", "## When to use it", "## How agents use it", "## Common mistakes"]

  # Tools that agents call but that are NOT served by core's tool surface: they
  # come from the channel plugin each runtime installs, so they never appear in
  # `ToolSurface.tool_definitions/0`.
  @channel_plugin_tools ~w(suite_reply suite_reply_chunk suite_reply_with_media suite_typing)

  # Tools defined by an optional build-time module rather than by core. Core
  # may not reference that module's code (see extension_boundary_test.exs), and
  # its bundle lists no tools while the module is switched off, which it is in
  # this suite, so these names never appear in `ToolSurface.tool_definitions/0`
  # here. Listing them keeps the check able to fire on the `play` family: a
  # misspelt `play_*` name is still rejected.
  #   play_session_*: the `play` bundle of the Play module (apps/game_stream)
  @extension_tools ~w(play_session_start play_session_stop play_session_status)

  # Backticked words that have the shape of a tool name AND begin with a tool
  # family prefix, but name something else. Each entry says what it is.
  @non_tool_terms [
    # task status: a stack member waiting for its in-stack dependencies
    "stack_pending"
  ]

  # ── The tool-token shape rule ─────────────────────────────────────────────
  #
  # A backticked span is treated as a TOOL REFERENCE when all of these hold:
  #
  #   1. after dropping a trailing argument list (`foo(...)` -> `foo`), it is
  #      lowercase words joined by `_` or `.`, at least two words
  #      (`task_ack`, `canvas.create`). One-word spans (`react`, `degraded`)
  #      are never checked: the shape cannot tell a tool from an English word.
  #   2. its first word is the first word of some real tool name (`task`,
  #      `canvas`, `memory`, `stack`, `suite`, ...), derived from
  #      `ToolSurface.tool_definitions/0` plus the channel-plugin list. This is
  #      what keeps field names and statuses such as `verified_at`, `in_review`,
  #      `manual_approval` or `auto_approve_plan` out of the check.
  #   3. it does not end in `_id` or `_ids` (`task_id`, `space_id`): no tool
  #      name ends that way, and these are the parameter names docs cite most.
  #   4. it is not on `@non_tool_terms`.
  #
  # A tool reference must then EXACTLY equal a tool name. Dots are not
  # normalised to underscores: the server registers `canvas.create`, and a
  # `canvas_create` call is refused as "not in allowed bundles", so a doc that
  # spells it with an underscore is teaching a name that does not work.

  @tool_shape ~r/\A[a-z][a-z0-9]*(?:[._][a-z0-9]+)+\z/
  @banned_words ~r/\b(fabrikam|ellis|hive|moon)\b/i
  @sha ~r/\A[0-9a-f]{8,40}\z/
  # A page that documents the separately released `suite` CLI also stamps the
  # CLI commit it was checked against: `_Last verified at <core>; suite CLI at
  # <cli>._`, matching its `verified_at_suite_cli` frontmatter key.
  @last_line ~r/\A_Last verified at ([0-9a-f]{8,40})(?:; suite CLI at ([0-9a-f]{8,40}))?\._\z/

  # ── The four checks ───────────────────────────────────────────────────────

  @doc "Check 1: frontmatter keys, summary length, verified_at shape."
  def frontmatter_errors(content) do
    {fm, _body} = Wiki.parse_frontmatter(content)

    missing =
      for key <- ~w(title summary order verified_at), not Map.has_key?(fm, key) do
        "frontmatter is missing #{key}"
      end

    summary =
      case Map.get(fm, "summary") do
        s when is_binary(s) ->
          cond do
            String.contains?(s, "\n") -> ["summary must be one line"]
            String.length(s) > 90 -> ["summary is #{String.length(s)} chars, over 90"]
            true -> []
          end

        nil ->
          []

        other ->
          ["summary must be a string, got #{inspect(other)}"]
      end

    order =
      case Map.fetch(fm, "order") do
        {:ok, n} when is_integer(n) -> []
        {:ok, other} -> ["order must be an integer, got #{inspect(other)}"]
        :error -> []
      end

    # An unquoted all-digit sha parses as an integer, so a non-string value is
    # an error rather than something to coerce.
    verified =
      case Map.fetch(fm, "verified_at") do
        {:ok, sha} when is_binary(sha) ->
          if Regex.match?(@sha, sha),
            do: [],
            else: ["verified_at #{inspect(sha)} is not 8-40 hex"]

        {:ok, other} ->
          ["verified_at must be a quoted string, got #{inspect(other)}"]

        :error ->
          []
      end

    # Optional: present only on a page that documents the `suite` CLI.
    cli =
      case Map.fetch(fm, "verified_at_suite_cli") do
        {:ok, sha} when is_binary(sha) ->
          if Regex.match?(@sha, sha),
            do: [],
            else: ["verified_at_suite_cli #{inspect(sha)} is not 8-40 hex"]

        {:ok, other} ->
          ["verified_at_suite_cli must be a quoted string, got #{inspect(other)}"]

        :error ->
          []
      end

    missing ++ summary ++ order ++ verified ++ cli
  end

  @doc "Check 2: exactly the four H2s in order, then the `_Last verified at` line."
  def section_errors(content) do
    {fm, body} = Wiki.parse_frontmatter(content)
    lines = String.split(body, "\n")
    h2s = Enum.filter(lines, &String.starts_with?(&1, "## "))

    sections =
      if h2s == @sections,
        do: [],
        else: ["H2s are #{inspect(h2s)}, expected exactly #{inspect(@sections)}"]

    last = lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> List.last()

    last_line =
      case last && Regex.run(@last_line, last) do
        [_ | shas] ->
          [sha | cli] = shas

          core =
            if sha == Map.get(fm, "verified_at"),
              do: [],
              else: [
                "last line sha #{sha} differs from verified_at #{inspect(fm["verified_at"])}"
              ]

          # The CLI sha is in the last line exactly when it is in the
          # frontmatter, and the two agree.
          cli_sha =
            case cli do
              [cli_sha] when cli_sha != "" -> cli_sha
              _ -> nil
            end

          fm_cli = Map.get(fm, "verified_at_suite_cli")

          core ++
            if cli_sha == fm_cli,
              do: [],
              else: [
                "last line suite CLI sha #{inspect(cli_sha)} differs from " <>
                  "verified_at_suite_cli #{inspect(fm_cli)}"
              ]

        _ ->
          ["last line is #{inspect(last)}, expected `_Last verified at <sha>._`"]
      end

    sections ++ last_line
  end

  @doc "Check 3: every tool-shaped backticked token names a real tool."
  def tool_name_errors(content, known_tools) do
    known = MapSet.new(known_tools)
    prefixes = MapSet.new(known_tools, &first_word/1)

    Regex.scan(~r/`([^`\n]+)`/, content, capture: :all_but_first)
    |> Enum.map(fn [span] -> span |> String.replace(~r/\(.*\)\z/, "") |> String.trim() end)
    |> Enum.filter(&tool_reference?(&1, prefixes))
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.uniq()
    |> Enum.map(&"unknown tool name `#{&1}`")
  end

  defp tool_reference?(token, prefixes) do
    Regex.match?(@tool_shape, token) and
      MapSet.member?(prefixes, first_word(token)) and
      not String.ends_with?(token, ["_id", "_ids"]) and
      token not in @non_tool_terms
  end

  defp first_word(name), do: name |> String.split(["_", "."], parts: 2) |> hd()

  @doc "Check 4: banned substrings."
  def banned_errors(content) do
    mention =
      if String.contains?(content, "@["), do: ["contains an at-bracket mention token"], else: []

    words =
      @banned_words
      |> Regex.scan(content, capture: :all_but_first)
      |> Enum.map(fn [w] -> "contains banned word #{inspect(w)}" end)
      |> Enum.uniq()

    mention ++ words
  end

  @doc """
  Check 5: the index lists every topic exactly once, in product order.

  `topics` is `[{basename, title, order}]` for every page except the index.
  Each topic must have exactly one `burrow/page/<basename>` reference, on a
  line `- <title>: burrow/page/<basename> - <summary>`; the index may name no
  file that is not a topic; and the topic lines run in `order`.
  """
  def index_errors(index, topics) do
    refs =
      ~r{burrow/page/([A-Za-z0-9_.-]+\.md)}
      |> Regex.scan(index, capture: :all_but_first)
      |> List.flatten()

    names = Enum.map(topics, &elem(&1, 0))

    counts =
      for {name, title, _order} <- topics do
        case Enum.count(refs, &(&1 == name)) do
          1 ->
            line = "- #{title}: burrow/page/#{name} - "

            if String.contains?(index, line),
              do: [],
              else: ["index line for #{name} is not `#{line}<summary>`"]

          0 ->
            ["index does not list #{name}"]

          n ->
            ["index lists #{name} #{n} times"]
        end
      end
      |> List.flatten()

    unknown =
      for ref <- Enum.uniq(refs), ref not in names, do: "index lists #{ref}, which is not a topic"

    listed = Enum.filter(refs, &(&1 in names)) |> Enum.uniq()

    expected =
      topics
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(&1 in listed))

    order =
      if listed == expected,
        do: [],
        else: ["index lists topics as #{inspect(listed)}, product order is #{inspect(expected)}"]

    counts ++ unknown ++ order
  end

  # ── Corpus ────────────────────────────────────────────────────────────────

  defp docs do
    @docs_dir
    |> Source.markdown_files()
    |> Enum.map(&{Path.basename(&1), File.read!(&1)})
  end

  defp known_tools do
    Enum.map(ToolSurface.tool_definitions(), & &1.name) ++
      @channel_plugin_tools ++ @extension_tools
  end

  defp topics(docs) do
    for {name, content} <- docs, name != @index_basename do
      {fm, _body} = Wiki.parse_frontmatter(content)
      {name, fm["title"], fm["order"]}
    end
  end

  defp index_content(docs) do
    {_, content} = Enum.find(docs, fn {name, _} -> name == @index_basename end)
    content
  end

  defp failures(check, docs) do
    docs
    |> Enum.map(fn {name, content} -> {name, check.(content)} end)
    |> Enum.reject(fn {_name, errors} -> errors == [] end)
  end

  # A minimal page that passes every check; each positive control breaks one.
  defp valid_fixture do
    """
    ---
    title: Fixture
    summary: A page that passes every check.
    order: 99
    verified_at: "0123abcd"
    ---

    # Fixture

    ## What it is

    Text that cites `task_ack`, `canvas.create`, `suite_reply`, `task_id` and `verified_at`.

    ## When to use it

    Text.

    ## How agents use it

    Text.

    ## Common mistakes

    Text.

    _Last verified at 0123abcd._
    """
  end

  describe "the corpus" do
    test "globbing docs/burrow finds the index and at least seven topic pages" do
      names = Enum.map(docs(), &elem(&1, 0))
      assert @index_basename in names
      assert length(names -- [@index_basename]) >= 7
    end

    test "every page has valid frontmatter" do
      assert failures(&frontmatter_errors/1, docs()) == []
    end

    test "every topic page has the four sections in order and ends with the verified line" do
      topics = Enum.reject(docs(), fn {name, _} -> name == @index_basename end)
      assert failures(&section_errors/1, topics) == []
    end

    test "every tool-shaped backticked token is a real tool" do
      tools = known_tools()
      assert failures(&tool_name_errors(&1, tools), docs()) == []
    end

    test "no page carries a banned substring" do
      assert failures(&banned_errors/1, docs()) == []
    end

    test "the index lists every topic exactly once, with its title, in product order" do
      docs = docs()
      assert index_errors(index_content(docs), topics(docs)) == []
    end
  end

  describe "positive controls: each check rejects a fixture that violates it" do
    test "the valid fixture passes all four checks" do
      content = valid_fixture()
      assert frontmatter_errors(content) == []
      assert section_errors(content) == []
      assert tool_name_errors(content, known_tools()) == []
      assert banned_errors(content) == []
    end

    test "check 1 rejects a missing key, a long summary and a bad verified_at" do
      no_summary =
        String.replace(valid_fixture(), "summary: A page that passes every check.\n", "")

      assert frontmatter_errors(no_summary) == ["frontmatter is missing summary"]

      long =
        String.replace(
          valid_fixture(),
          "A page that passes every check.",
          String.duplicate("x", 91)
        )

      assert frontmatter_errors(long) == ["summary is 91 chars, over 90"]

      short_sha =
        String.replace(valid_fixture(), ~s(verified_at: "0123abcd"), ~s(verified_at: "0123abc"))

      assert frontmatter_errors(short_sha) == [~s(verified_at "0123abc" is not 8-40 hex)]

      unquoted =
        String.replace(valid_fixture(), ~s(verified_at: "0123abcd"), "verified_at: 12345678")

      assert frontmatter_errors(unquoted) == ["verified_at must be a quoted string, got 12345678"]
    end

    test "check 2 rejects sections out of order and a missing verified line" do
      swapped =
        valid_fixture()
        |> String.replace("## When to use it", "## PLACEHOLDER")
        |> String.replace("## How agents use it", "## When to use it")
        |> String.replace("## PLACEHOLDER", "## How agents use it")

      assert [error] = section_errors(swapped)
      assert error =~ "H2s are"

      no_last = String.replace(valid_fixture(), "_Last verified at 0123abcd._\n", "")
      assert [error] = section_errors(no_last)
      assert error =~ "expected `_Last verified at <sha>._`"

      wrong_sha =
        String.replace(
          valid_fixture(),
          "_Last verified at 0123abcd._",
          "_Last verified at 89abcdef._"
        )

      assert section_errors(wrong_sha) == [
               ~s(last line sha 89abcdef differs from verified_at "0123abcd")
             ]
    end

    test "check 3 rejects an invented tool and an underscored dotted tool" do
      content =
        String.replace(
          valid_fixture(),
          "Text.\n\n## Common",
          "Call `task_teleport` and `canvas_create`.\n\n## Common"
        )

      assert tool_name_errors(content, known_tools()) == [
               "unknown tool name `task_teleport`",
               "unknown tool name `canvas_create`"
             ]
    end

    test "check 3 leaves non-tool snake_case alone" do
      content =
        "`in_review` `verified_at` `manual_approval` `stack_pending` `space_id` `burrow/page/x.md`"

      assert tool_name_errors(content, known_tools()) == []
    end

    test "check 4 rejects an at-bracket token and each banned word" do
      # Built from parts so this file never holds a literal mention token.
      token = "@" <> "[Someone]"
      assert banned_errors("ask #{token} now") == ["contains an at-bracket mention token"]

      for word <- ~w(fabrikam Ellis HIVE moon) do
        assert banned_errors("runs on #{word} today") == ["contains banned word #{inspect(word)}"]
      end

      # Word-bounded: a longer word containing one is not a hit.
      assert banned_errors("honeymoon archive") == []
    end

    test "check 2 holds a suite CLI sha in the last line to its frontmatter key" do
      with_cli =
        valid_fixture()
        |> String.replace(
          ~s(verified_at: "0123abcd"\n),
          ~s(verified_at: "0123abcd"\nverified_at_suite_cli: "4567cdef"\n)
        )

      both = String.replace(with_cli, "at 0123abcd._", "at 0123abcd; suite CLI at 4567cdef._")
      assert frontmatter_errors(both) == []
      assert section_errors(both) == []

      # frontmatter key without the last-line stamp
      assert [error] = section_errors(with_cli)
      assert error =~ ~s(verified_at_suite_cli "4567cdef")

      # last-line stamp without the frontmatter key
      line_only =
        String.replace(valid_fixture(), "at 0123abcd._", "at 0123abcd; suite CLI at 4567cdef._")

      assert [error] = section_errors(line_only)
      assert error =~ ~s(suite CLI sha "4567cdef")

      bad_cli = String.replace(with_cli, ~s("4567cdef"), ~s("4567cde"))
      assert frontmatter_errors(bad_cli) == [~s(verified_at_suite_cli "4567cde" is not 8-40 hex)]
    end

    test "check 3 knows the extension tools and still rejects a misspelt one" do
      assert tool_name_errors("`play_session_start` `play_session_status`", known_tools()) == []

      assert tool_name_errors("`play_session_pause`", known_tools()) == [
               "unknown tool name `play_session_pause`"
             ]
    end

    test "check 5 rejects an index missing a topic, a duplicate, a stray file and a wrong order" do
      topics = [{"a.md", "Alpha", 1}, {"b.md", "Beta", 2}, {"c.md", "Gamma", 3}]

      index = """
      - Alpha: burrow/page/a.md - First.
      - Beta: burrow/page/b.md - Second.
      - Gamma: burrow/page/c.md - Third.
      """

      assert index_errors(index, topics) == []

      missing = String.replace(index, "- Beta: burrow/page/b.md - Second.\n", "")
      assert index_errors(missing, topics) == ["index does not list b.md"]

      twice = index <> "- Beta: burrow/page/b.md - Again.\n"
      assert index_errors(twice, topics) == ["index lists b.md 2 times"]

      retitled = String.replace(index, "- Beta:", "- Bets:")

      assert index_errors(retitled, topics) == [
               "index line for b.md is not `- Beta: burrow/page/b.md - <summary>`"
             ]

      stray = index <> "- Delta: burrow/page/d.md - Fourth.\n"
      assert index_errors(stray, topics) == ["index lists d.md, which is not a topic"]

      swapped =
        index
        |> String.replace("- Alpha: burrow/page/a.md - First.\n", "")
        |> Kernel.<>("- Alpha: burrow/page/a.md - First.\n")

      assert [error] = index_errors(swapped, topics)
      assert error =~ "product order"
    end
  end
end
