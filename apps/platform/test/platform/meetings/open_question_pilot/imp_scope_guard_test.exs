defmodule Platform.Meetings.OpenQuestionPilot.ImpScopeGuardTest do
  @moduledoc """
  Imp (DSPy for Elixir) is a PILOT dependency (task 01a0e8b5). It may be
  referenced from exactly three places under `apps/platform/lib`:

    * `lib/platform/meetings/open_question_pilot/**`
    * `lib/platform/experiments/surfaces/open_question_classifier.ex`
    * `lib/mix/tasks/platform.open_question_pilot.*.ex`

  This test scans every file under `lib/` for `\\bImp\\.` or `alias Imp` and
  fails on any hit outside that allowlist.

  ## Allowlist existence rule

  A stale allowlist entry (a typo, or a file that was renamed) would silently
  permit nothing and let the real code move elsewhere, so every entry is
  checked against disk:

    * a literal entry (no glob character) must be an existing FILE, e.g.
      `lib/platform/experiments/surfaces/open_question_classifier.ex`;
    * a `dir/**` entry must name an existing DIRECTORY, e.g.
      `lib/platform/meetings/open_question_pilot`;
    * an entry whose last segment is a glob (`platform.open_question_pilot.*.ex`)
      must sit in an existing directory (`lib/mix/tasks`): the files it
      matches may legitimately not exist yet;
    * no directory segment may itself contain a glob character.

  Stage 1 could only check directories, because the pilot's files did not
  exist yet. Stage 3 tightened it to this rule once the surface file and the
  pilot directory landed.
  """
  use ExUnit.Case, async: true

  alias Platform.TestTemp

  @allowlist [
    "lib/platform/meetings/open_question_pilot/**",
    "lib/platform/experiments/surfaces/open_question_classifier.ex",
    "lib/mix/tasks/platform.open_question_pilot.*.ex"
  ]

  @imp_ref ~r/\bImp\.|alias Imp/

  # apps/platform, resolved from this file rather than the cwd.
  @app_root Path.expand("../../../..", __DIR__)

  # ---------------------------------------------------------------------------
  # Scanner
  # ---------------------------------------------------------------------------

  @doc false
  def violations(root, allowlist) do
    root
    |> hits()
    |> Enum.reject(fn {rel, _line_no, _line} -> allowed?(rel, allowlist) end)
  end

  @doc false
  def hits(root) do
    lib = Path.join(root, "lib")

    lib
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(@imp_ref, line) end)
      |> Enum.map(fn {line, n} -> {rel, n, String.trim(line)} end)
    end)
  end

  @doc false
  def allowed?(rel, allowlist), do: Enum.any?(allowlist, &Regex.match?(glob_regex(&1), rel))

  @doc false
  def missing_anchors(root, allowlist) do
    Enum.reject(allowlist, fn entry ->
      case anchor(entry) do
        {:file, path} -> File.regular?(Path.join(root, path))
        {:dir, path} -> File.dir?(Path.join(root, path))
        :invalid -> false
      end
    end)
  end

  defp anchor(entry) do
    {kind, path} =
      cond do
        String.ends_with?(entry, "/**") -> {:dir, String.replace_suffix(entry, "/**", "")}
        glob?(Path.basename(entry)) -> {:dir, Path.dirname(entry)}
        true -> {:file, entry}
      end

    if glob?(path), do: :invalid, else: {kind, path}
  end

  defp glob?(path), do: String.contains?(path, ["*", "?", "[", "{"])

  # `**` spans directories, `*` stays inside one segment.
  defp glob_regex(entry) do
    body =
      entry
      |> Regex.escape()
      |> String.replace("\\*\\*", "\u0000")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\u0000", ".*")

    Regex.compile!("\\A" <> body <> "\\z")
  end

  # ---------------------------------------------------------------------------
  # The guard
  # ---------------------------------------------------------------------------

  test "Imp is referenced only from the pilot allowlist under apps/platform/lib" do
    # Positive evidence the scan walked the real tree: a scan of zero files
    # would also report zero violations.
    assert File.regular?(Path.join(@app_root, "lib/platform/meetings/intent_classifier.ex"))

    assert violations(@app_root, @allowlist) == [],
           "Imp is a pilot dependency (task 01a0e8b5) and may only be used from " <>
             inspect(@allowlist) <>
             ". Offending lines: " <> inspect(violations(@app_root, @allowlist))
  end

  test "every allowlist entry names something that exists" do
    assert missing_anchors(@app_root, @allowlist) == [],
           "allowlist entries that name nothing on disk (typo or rename?): " <>
             inspect(missing_anchors(@app_root, @allowlist))
  end

  defp put(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  # ---------------------------------------------------------------------------
  # Controls: prove the scanner can go red
  # ---------------------------------------------------------------------------

  describe "scanner controls" do
    setup do
      root = TestTemp.mkdir!("imp-scope-guard")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "flags an out-of-allowlist Imp.call", %{root: root} do
      put(root, "lib/platform/meetings/intent_classifier.ex", """
      defmodule Platform.Meetings.IntentClassifier do
        def decide(x), do: Imp.call(:program, x)
      end
      """)

      assert [{"lib/platform/meetings/intent_classifier.ex", 2, line}] =
               violations(root, @allowlist)

      assert line =~ "Imp.call"
    end

    test "flags an out-of-allowlist alias Imp", %{root: root} do
      put(root, "lib/platform/chat/thing.ex", "  alias Imp.LM.Static\n")
      assert [{"lib/platform/chat/thing.ex", 1, _}] = violations(root, @allowlist)
    end

    test "permits hits inside each allowlist entry", %{root: root} do
      put(root, "lib/platform/meetings/open_question_pilot/program.ex", "Imp.call(x)\n")
      put(root, "lib/platform/meetings/open_question_pilot/deep/nested.ex", "alias Imp\n")
      put(root, "lib/platform/experiments/surfaces/open_question_classifier.ex", "Imp.run()\n")
      put(root, "lib/mix/tasks/platform.open_question_pilot.compile.ex", "Imp.compile()\n")

      assert length(hits(root)) == 4
      assert violations(root, @allowlist) == []
    end

    test "a single-segment * does not reach into a subdirectory", %{root: root} do
      put(root, "lib/mix/tasks/platform.open_question_pilot.x/evil.ex", "Imp.call(x)\n")
      assert [_] = violations(root, @allowlist)
    end

    test "does not match a module that merely ends in Imp", %{root: root} do
      put(root, "lib/platform/other.ex", "FooImp.call(x)\nimport Foo\n")
      assert hits(root) == []
    end

    test "reports an allowlist entry that names nothing on disk", %{root: root} do
      File.mkdir_p!(Path.join(root, "lib/platform/meetings/open_question_pilot"))
      File.mkdir_p!(Path.join(root, "lib/mix/tasks"))
      put(root, "lib/platform/experiments/surfaces/open_question_classifier.ex", "")

      good = [
        "lib/platform/meetings/open_question_pilot/**",
        "lib/platform/experiments/surfaces/open_question_classifier.ex",
        "lib/mix/tasks/platform.open_question_pilot.*.ex"
      ]

      assert missing_anchors(root, good) == []

      bad = [
        # a literal file that is not there (the directory is)
        "lib/platform/experiments/surfaces/open_question_classifer.ex",
        # a `/**` directory that is not there
        "lib/platform/meetings/open_question_pilott/**",
        # a basename glob in a directory that is not there
        "lib/mix/taks/platform.open_question_pilot.*.ex",
        # a glob in a directory segment
        "lib/*/tasks/x.ex"
      ]

      assert missing_anchors(root, bad) == bad
    end
  end
end
