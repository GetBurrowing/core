defmodule Platform.ProductNameGuardTest do
  @moduledoc """
  The product is called Burrow (task 01a14b9e-50a4-7000-996c-429bca872907,
  rename A2). This guard fails when the old product name comes back in
  user-facing code or copy, naming every offending `path:line: text`.

  ## What is scanned

  Every file under these repo-root paths:

    * `apps/platform/lib/**/*.{ex,heex,eex}`;
    * `apps/platform/assets/js/**` and `apps/platform/assets/css/**`, except
      any `vendor/` directory;
    * `apps/platform/priv/prototype/**` and `apps/platform/priv/static/sw.js`;
    * `apps/social/lib/**`;
    * `docs/burrow/**/*.md`, `README.md` and `CONTRIBUTING.md`.

  The files are enumerated with `Path.wildcard/1`, not `git ls-files`: CI's
  Test job checks the repo out (`actions/checkout`) BEFORE it installs git,
  so that checkout has no `.git` directory for `git ls-files` to read. At the
  commit this guard landed on, none of these paths held an untracked or
  ignored file, so the two enumerations named the same files.

  ## What is forbidden, per line

  `\\bSuite\\b` (case-sensitive), `startup suite` (any case), `Startup Burrow`
  and `Burrow Suite`. Before matching:

    * the GitHub organisation spans `Startup-Suite/`, `github.com/Startup-Suite`
      and `ghcr.io/startup-suite` are removed. The organisation is renamed last,
      by its own ticket;
    * each allowlisted substring for that file is removed, so an allowlisted
      identifier does not hide a second, new occurrence on the same line.

  ## The sibling-ticket skip

  Lines carrying identifiers that sibling ticket A3 (01a14b9e-c802) owns are
  skipped whole. Those identifiers must not be published in plaintext, so they
  are held as sha256 hashes in `@a3_owned_hashes`, the same way A3's own guard
  stores its denylist. A line is tokenised (lowercase, split on anything that
  is not `[a-z0-9]`, plus every dotted or hyphenated compound of adjacent
  tokens), each token is hashed, and the line is skipped when any hash is in
  the list. REMOVE THIS SKIP WHEN A3 LANDS: its lines will no longer carry the
  old product name.

  ## The allowlist fires in both directions

  `@allowlist` is an explicit list of `{relative_path, exact_substring,
  reason}`. Every entry must still occur on at least one scanned line of its
  file, or the test fails naming it as a stale allowlist entry. So an entry
  cannot outlive the text it excuses.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The patterns tested against each line, after the spans below are removed.
  @forbidden [
    ~r/\bSuite\b/,
    ~r/startup suite/i,
    ~r/Startup Burrow/,
    ~r/Burrow Suite/
  ]

  # GitHub organisation and registry names: renamed with the org, last.
  @org_spans ~r/Startup-Suite\/|github\.com\/Startup-Suite|ghcr\.io\/startup-suite/

  # sha256 of each identifier sibling ticket A3 (01a14b9e-c802) owns. Lines
  # carrying one are A3's to change, so this guard skips them. Removed when A3
  # lands.
  @a3_owned_hashes MapSet.new([
                     "9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c",
                     "44506f784f8d79f5c01259f925b02d157fc5703fa334313d7575d43f308c9a36",
                     "b29a46a27acbba77b0aaba113e3d343cbd951a3a848f8356c164c3728b1c8e05",
                     "b185c3068c145f728a1aab6f00091fb6735ddf72311b368f592cb7b0a2a5f37c",
                     "344d0bfd9b610f39806a18638c537bfb0d490bca45ea21f9ec0487f0f05cee04"
                   ])

  @client_state "Storage key namespace and browser global, kept by stage 2: renaming it orphans state persisted in users' browsers"
  @earlier_name "States the product's earlier name on purpose"
  @org_name "The GitHub organisation's name, renamed with the org by its own ticket"
  @quoted "Quotes the title of an earlier design artefact or memory page verbatim"

  @allowlist [
    {"README.md", "Burrow used to be called Startup Suite", @earlier_name},
    {"docs/burrow/index.md", "Burrow was called Startup Suite", @earlier_name},
    {"apps/platform/assets/js/client_state.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/canvas_sidebar_resize.js", "Suite.ClientState",
     @client_state},
    {"apps/platform/assets/js/hooks/compose_input.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/done_column_state.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/last_project.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/lazy_inline_canvas.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/meeting_captions.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/meeting_soundboard.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/resizable_sidebar.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/sidebar_collapse.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/tasks_status_filter.js", "Suite.ClientState", @client_state},
    {"apps/platform/lib/mix/tasks/suite.deploy.scope_gate.ex", "Mix.Tasks.Suite.",
     "Mix task module; its name is the `mix suite.deploy.scope_gate` command scripts call"},
    {"apps/platform/lib/mix/tasks/suite.responsibility_reachability.ex", "Mix.Tasks.Suite.",
     "Mix task module; its name is the `mix suite.responsibility_reachability` command scripts call"},
    {"apps/platform/lib/platform/experiments/surfaces/code_mode.ex", "Suite tool",
     "Experiment code-mode-2026-10 is running on this surface; its directives stay byte-identical until it concludes"},
    {"apps/platform/lib/platform/experiments/surfaces/code_mode.ex", "Suite calls",
     "Experiment code-mode-2026-10 is running on this surface; its directives stay byte-identical until it concludes"},
    {"apps/platform/lib/platform/federation/tool_surface.ex", "Startup-Suite feedback repository",
     @org_name},
    {"apps/platform/lib/platform/feedback/github_publisher.ex",
     "Startup-Suite feedback repository", @org_name},
    {"apps/platform/lib/platform/meetings/archive.ex", "Suite / Control Center",
     "Example meeting subtitle quoting a space's own name"},
    {"apps/platform/lib/platform_web/live/meeting_live.ex", "Suite / Control Center",
     "Example meeting subtitle quoting a space's own name"},
    {"apps/platform/lib/platform/push/notification.ex", "Suite iOS v1", @quoted},
    {"apps/platform/lib/platform/push/notification.ex", ~s(compiled `"Suite"`),
     "Describes the old compiled default this code replaced"},
    {"apps/platform/priv/static/sw.js", ~s(`"Suite"` was doing),
     "Describes the old name a renamed install kept showing"},
    {"apps/platform/lib/platform/responsibilities/handlers/agents_goal_heartbeat.ex", ~s(Suite"),
     "Quotes the title of an agent's goal verbatim"},
    {"apps/platform/lib/platform/responsibilities/handlers/architecture_audit_diff.ex",
     "Suite ToolSurface smell", @quoted},
    {"apps/platform/lib/platform/tasks.ex", "[Suite engine quirks]", @quoted},
    {"apps/platform/lib/platform/tasks/plan_engine.ex", "[Suite engine quirks]", @quoted},
    {"apps/platform/lib/platform_web/live/control_center/native_login.ex", ~s("Suite), @quoted},
    {"apps/platform/lib/platform_web/live/org_memory_live/mobile_shell.ex", "Suite tokens",
     @quoted}
  ]

  describe "scan of the repository" do
    test "scans a non-trivial file set" do
      files = scanned_files()

      # A guard whose glob silently matched nothing would pass on every tree.
      assert length(files) > 500, "only #{length(files)} files scanned; a scan root moved?"

      for root <- ["apps/platform/lib/", "apps/platform/assets/js/", "apps/social/lib/"] do
        assert Enum.any?(files, &String.starts_with?(&1, root)), "nothing scanned under #{root}"
      end

      for file <- ["README.md", "docs/burrow/index.md", "apps/platform/priv/static/sw.js"] do
        assert file in files, "#{file} is not scanned"
      end
    end

    test "no scanned line names the old product, outside the allowlist" do
      offences =
        Enum.flat_map(scanned_files(), fn rel ->
          rel |> read_lines() |> offences(rel, allowed_substrings(rel))
        end)

      assert offences == [], """
      The product is called Burrow. #{length(offences)} line(s) still use the old name.
      Change the copy, or, if the old name is deliberate, add an entry to
      @allowlist in #{Path.relative_to(__ENV__.file, @repo_root)} with a reason:

      #{Enum.join(offences, "\n")}
      """
    end

    test "every allowlist entry still matches a scanned line" do
      files = MapSet.new(scanned_files())

      stale =
        for {rel, substring, _reason} <- @allowlist,
            not (MapSet.member?(files, rel) and
                   Enum.any?(read_lines(rel), &String.contains?(&1, substring))) do
          "stale allowlist entry: #{rel} no longer contains #{inspect(substring)}"
        end

      assert stale == [], Enum.join(stale, "\n")
    end

    test "every allowlist entry has a reason" do
      for {rel, substring, reason} <- @allowlist do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{rel} #{inspect(substring)} has no reason"
      end
    end
  end

  describe "line matcher (planted lines)" do
    test "flags each forbidden form" do
      for line <- [
            "Welcome to Suite.",
            "<p>Sign in to Suite</p>",
            "Startup Suite",
            "startup suite",
            "Startup Burrow",
            "Burrow Suite"
          ] do
        assert offences([line], "planted.ex", []) == ["planted.ex:1: #{line}"],
               "#{inspect(line)} was not flagged"
      end
    end

    test "leaves the English word and identifiers alone" do
      for line <- [
            "the full test suite",
            "a suite of tools",
            "SuiteExecutor runs the stage",
            "suite_run, SUITE_TOKEN and BURROW_TOKEN",
            "Burrow tools"
          ] do
        assert offences([line], "planted.ex", []) == [], "#{inspect(line)} was flagged"
      end
    end

    test "removes the GitHub organisation spans before matching" do
      for line <- [
            "see github.com/Startup-Suite/core",
            "ghcr.io/startup-suite/core:latest",
            "Startup-Suite/feedback issues"
          ] do
        assert offences([line], "planted.ex", []) == [], "#{inspect(line)} was flagged"
      end

      assert offences(["Suite lives at github.com/Startup-Suite/core"], "p.ex", []) ==
               ["p.ex:1: Suite lives at github.com/Startup-Suite/core"]
    end

    test "an allowlisted substring does not hide a second occurrence on its line" do
      assert offences(["uses Suite.ClientState"], "p.js", ["Suite.ClientState"]) == []

      assert offences(["Suite.ClientState for Suite"], "p.js", ["Suite.ClientState"]) ==
               ["p.js:1: Suite.ClientState for Suite"]
    end

    test "tokenises compounds so a dotted or hyphenated identifier is one token" do
      tokens = tokens("See https://a.b-c.d/x and Foo_Bar")

      for t <- ~w(see https a b c d x foo bar a.b b-c c.d a.b-c b-c.d a.b-c.d) do
        assert t in tokens, "#{t} missing from #{inspect(tokens)}"
      end
    end

    test "the skip list holds five sha256 digests" do
      assert MapSet.size(@a3_owned_hashes) == 5
      assert Enum.all?(@a3_owned_hashes, &(&1 =~ ~r/\A[0-9a-f]{64}\z/))
    end
  end

  # -- scanning ---------------------------------------------------------------

  defp scanned_files do
    [
      "apps/platform/lib/**/*.{ex,heex,eex}",
      "apps/platform/assets/js/**",
      "apps/platform/assets/css/**",
      "apps/platform/priv/prototype/**",
      "apps/platform/priv/static/sw.js",
      "apps/social/lib/**",
      "docs/burrow/**/*.md",
      "README.md",
      "CONTRIBUTING.md"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.reject(&("vendor" in Path.split(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp read_lines(rel), do: @repo_root |> Path.join(rel) |> File.read!() |> String.split("\n")

  defp allowed_substrings(rel), do: for({^rel, s, _} <- @allowlist, do: s)

  # -- matching ---------------------------------------------------------------

  defp offences(lines, rel, allowed) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> offending?(line, allowed) end)
    |> Enum.map(fn {line, n} -> "#{rel}:#{n}: #{String.trim(line)}" end)
  end

  defp offending?(line, allowed) do
    stripped =
      Enum.reduce(allowed, Regex.replace(@org_spans, line, ""), &String.replace(&2, &1, ""))

    Enum.any?(@forbidden, &Regex.match?(&1, stripped)) and not a3_owned?(line)
  end

  defp a3_owned?(line) do
    line
    |> tokens()
    |> Enum.any?(&MapSet.member?(@a3_owned_hashes, sha256(&1)))
  end

  defp sha256(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  # Lowercase tokens split on anything that is not [a-z0-9], plus every
  # dotted or hyphenated compound of adjacent tokens ("a.b-c" yields "a.b",
  # "b-c" and "a.b-c"), so a host name or a hyphenated handle is also tested
  # whole and by each of its sub-domains.
  defp tokens(line) do
    down = String.downcase(line)
    simple = String.split(down, ~r/[^a-z0-9]+/, trim: true)

    compounds =
      down
      |> String.split(~r/[^a-z0-9.\-]+/, trim: true)
      |> Enum.flat_map(&compounds/1)

    Enum.uniq(simple ++ compounds)
  end

  defp compounds(chunk) do
    parts = Regex.split(~r/([.\-])/, chunk, include_captures: true)
    words = Enum.take_every(parts, 2)
    seps = parts |> Enum.drop(1) |> Enum.take_every(2)
    n = length(words)

    for i <- 0..(n - 2)//1, j <- (i + 1)..(n - 1)//1 do
      Enum.slice(words, i..j)
      |> Enum.zip(["" | Enum.slice(seps, i..(j - 1))])
      |> Enum.map_join(fn {w, s} -> s <> w end)
    end
  end
end
