defmodule Platform.Regression.BurrowEnvFallbackGuardTest do
  @moduledoc """
  Text guard for the finished Burrow env-name rename (task 01a18dab, stage 2;
  the bridge it replaces was task 01a14b9e's). No tracked file names a
  `SUITE_` env name any more, and no reader falls back to one.

  The invariant: every token matching `(?<![A-Z0-9_])SUITE_[A-Z0-9_]+` in a
  tracked, non-exempt file is on @keep, a hand-typed list where each entry
  carries its reason. Anything else fails, naming `path:line:token`.

  @keep holds SUFFIXES and the guard compares against `"SUITE" <> "_" <>
  suffix`, so this file carries no `SUITE_` token of its own and does not
  show up in the ticket's grep
  (`grep -rhoE '\\bSUITE_[A-Z0-9_]{2,}' apps services deployment clients`).
  Tests may build a legacy name this way to prove it is ignored; readers may
  not, and a reader that builds one is invisible to this text scan. That is
  the scope this guard covers, stated as scope: literal tokens in tracked
  text, plus the one embedded Xcode spelling below.

  The list is typed out, not derived from a scan: a derived list agrees
  with whatever the tree says, so it cannot see an addition.
  """
  use ExUnit.Case, async: true

  # The repo root, walked from this file rather than configured (mirrors
  # adr_corpus_packaging_test.exs).
  @repo_root Path.expand("../../../../..", __DIR__)

  # Suffix => reason. Six entries, all mobile push category/action ids.
  # Measured 2026-10-30 with Platform.Mobile.push_category_adoption() over
  # prod rpc: legacy iOS rows were nonzero on each of the three prod
  # installs (2, 1, 1), so renaming would stop those devices showing actions. Remove an entry only
  # when ios.legacy == 0 and android.legacy == 0 on every install.
  @keep %{
    "MENTION" =>
      "push category id compiled into installed iOS/Android builds; stored-data identifier, not an env name",
    "OPEN" =>
      "push category id compiled into installed iOS/Android builds; stored-data identifier, not an env name",
    "RING_WAITING" =>
      "push category id compiled into installed iOS builds; stored-data identifier, not an env name",
    "REPLY" =>
      "notification action id registered by installed iOS builds under the legacy categories",
    "OPEN_ACTION" =>
      "notification action id registered by installed iOS builds under the legacy categories",
    "MESSAGE" =>
      "legacy push category spelling used as an incoming-payload fixture in IntentsTests.swift"
  }

  # Literal path prefixes, each with its reason.
  @exempt_prefixes [
    # Historical audit records.
    "audit/",
    # Dated engineering notes; historical.
    "apps/platform/notes/",
    # Accepted ADRs record what was decided at the time.
    "docs/decisions/",
    # Release notes record what shipped at the time.
    "CHANGELOG"
  ]

  # A token starts at any character that is not an uppercase letter, digit or
  # underscore. Stricter than `\b`: `\b` misses a token written right after
  # a `\n` escape inside a JS template literal, because the `n` of `\n` is a
  # word character.
  @suite_token ~r/(?<![A-Z0-9_])SUITE_[A-Z0-9_]+/

  # The Xcode test-runner form: Xcode strips `TEST_RUNNER_` and passes the
  # rest, so the old spelling was TEST_RUNNER_ + legacy RENDER_DIR. The token
  # regex cannot see it (the `_` before it is a word character), so it gets a
  # substring check of its own.
  @embedded_legacy ["RUNNER_" <> "SUITE" <> "_RENDER_DIR"]

  defp keep_names, do: MapSet.new(Map.keys(@keep), &("SUITE" <> "_" <> &1))

  defp tracked_files do
    # CI's Test job runs as root in a container over a workspace the runner's
    # uid owns, so git refuses the repo as "dubious ownership" (exit 128).
    # Command-line config is protected configuration, so git honours it here;
    # the > 1000 positive control below still fires on any other failure.
    {out, 0} =
      System.cmd("git", ["-c", "safe.directory=#{@repo_root}", "ls-files", "-z"], cd: @repo_root)

    out
    |> String.split(<<0>>, trim: true)
    |> Enum.reject(fn path -> Enum.any?(@exempt_prefixes, &String.starts_with?(path, &1)) end)
    |> Enum.flat_map(fn path ->
      case File.read(Path.join(@repo_root, path)) do
        {:ok, body} -> if String.contains?(body, <<0>>), do: [], else: [{path, body}]
        # A tracked file deleted in the working tree is not content.
        {:error, :enoent} -> []
      end
    end)
  end

  defp suite_occurrences(body) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      @suite_token |> Regex.scan(line) |> List.flatten() |> Enum.map(&{n, &1})
    end)
  end

  setup_all do
    files = tracked_files()
    # Positive control: the scan must have something to scan. An empty file
    # list (no .git, wrong root) would make every check below pass silently.
    assert length(files) > 1000, "git ls-files under #{@repo_root} returned #{length(files)}"

    # The scan reaches every directory the rename covers, scripts/ included.
    for path <- [
          "apps/platform/config/runtime.exs",
          "services/agent-host/src/main.ts",
          "deployment/installer/burrow_install/setup/state.py",
          "clients/ios/ios/App/App/BurrowBridgeViewController.swift",
          "scripts/suite_runnerd.py",
          "skills/openclaw-isolated-gateway/scripts/setup-isolated-gateway.sh"
        ] do
      assert Enum.any?(files, fn {p, _} -> p == path end), "#{path} is not in the scan"
    end

    %{files: files}
  end

  test "the keep-list is the six push ids, each with a reason" do
    assert map_size(@keep) == 6
    for {suffix, reason} <- @keep, do: assert(String.length(reason) > 20, suffix)
  end

  test "every SUITE_ token in a tracked file is on the keep-list", %{files: files} do
    keep = keep_names()

    unknown =
      for {path, body} <- files,
          {line, token} <- suite_occurrences(body),
          not MapSet.member?(keep, token),
          do: "#{path}:#{line}:#{token}"

    assert unknown == [],
           "SUITE_ tokens not on the keep-list (rename them to BURROW_; a keep entry " <>
             "needs a reason that it is not an env name):\n" <> Enum.join(unknown, "\n")
  end

  test "the embedded Xcode test-runner spelling is gone", %{files: files} do
    hits =
      for {path, body} <- files,
          old <- @embedded_legacy,
          String.contains?(body, old),
          do: "#{path}: names #{old}"

    assert hits == [], Enum.join(hits, "\n")
  end

  test "runtime.exs has no compat_env bridge" do
    body = File.read!(Path.join(@repo_root, "apps/platform/config/runtime.exs"))
    refute body =~ "compat_env"
    assert body =~ ~s{"BURROW_RUNNERD_BASE_URL"}
  end
end
