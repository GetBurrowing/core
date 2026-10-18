defmodule Platform.Regression.BurrowEnvFallbackGuardTest do
  @moduledoc """
  Text guard for the Burrow env-var rename (task 01a14b9e): every in-scope
  `SUITE_X` env name is read BURROW_X first with a SUITE_X fallback, and every
  writer emits both. Readers name both full literals at the call site, which
  is what makes this text scan able to see them.

  The three name lists below are RAW LITERALS, typed out by hand. They are
  deliberately not derived from a scan, a config file or a list of call
  sites: a derived set agrees with whatever the tree says, so it cannot see
  an omission. A new `SUITE_` name, a name dropped from a list, or a reader
  that loses its BURROW_ twin each fail here.

  What this guard does NOT see, stated as its scope: it is file-granular. It
  checks that a file naming SUITE_X also names BURROW_X somewhere, not that
  every SUITE_X occurrence has a BURROW_X partner beside it. A writer that
  drops one of two emitted lines while the file still names BURROW_X
  elsewhere passes here; the per-language unit tests own that case. It also
  cannot see a name built from a suffix (`"SUITE_" <> x`), which the rename
  contract forbids for that reason.
  """
  use ExUnit.Case, async: true

  # The repo root, walked from this file rather than configured (mirrors
  # adr_corpus_packaging_test.exs).
  @repo_root Path.expand("../../../../..", __DIR__)

  # In-scope names: BURROW_ twin required wherever these appear. 34, exactly.
  @fallback_names ~w(
    SUITE_RUNNERD_BASE_URL SUITE_RUNNERD_TOKEN SUITE_RUNNERD_HOST SUITE_RUNNERD_PORT
    SUITE_RUNNERD_STATE_DIR SUITE_RUNNER_IMAGE SUITE_RUNNER_NETWORK SUITE_MODULE_DEFINITION
    SUITE_EXTENSIONS_JS SUITE_EXTENSION_LITERAL SUITE_HEROICONS_DIR SUITE_CORE_URL
    SUITE_AGENT_ID SUITE_AGENT_SESSION SUITE_UNATTENDED SUITE_CLI_REF SUITE_INSTALL_DIR
    SUITE_INSTALL_UPDATE_GOLDEN SUITE_INSTALL_TEST_POCKETID_URL SUITE_INSTALL_TEST_POCKETID_KEY
    SUITE_RUNTIME_TOKEN SUITE_BASE_URL SUITE_URL SUITE_TOKEN SUITE_SPACE_ID SUITE_PORT
    SUITE_AGENT_SLUG SUITE_RUNTIME_ID SUITE_MEETING_PROBE_URL SUITE_MEETING_PROBE_TOKEN
    SUITE_MEETING_PROBE_ROOM SUITE_MEETING_PROBE_NAME SUITE_MEETING_PROBE_CALLKIT
    SUITE_RENDER_DIR
  )

  # Names that keep their SUITE_ spelling: push category/action ids compiled
  # into installed iOS apps (a follow-up owns them), SUITE_CONVENTIONS
  # (suite-cli task 01a14b9f) and SUITE_CHANNEL_BUILD (the channel plugin's).
  @out_of_scope ~w(
    SUITE_MENTION SUITE_OPEN SUITE_RING_WAITING SUITE_REPLY SUITE_OPEN_ACTION
    SUITE_MESSAGE SUITE_CONVENTIONS SUITE_CHANNEL_BUILD
  )

  # Renamed with no shim (shell locals, TS consts, Xcode build settings that
  # no installed binary reads). The SUITE_ spelling must not come back.
  @renamed_outright ~w(
    SUITE_WS SUITE_MCP SUITE_NET SUITE_APS_ENVIRONMENT SUITE_PUSH_ENVIRONMENT
    SUITE_CLI_LIB SUITE_CLI_KEY_VECTOR
  )

  # The Xcode test-runner form. Xcode strips `TEST_RUNNER_` and passes the
  # rest, so the repo spells it TEST_RUNNER_SUITE_RENDER_DIR; a substring
  # check on RUNNER_SUITE_RENDER_DIR covers both spellings. The token regex
  # cannot see it (the `_` before SUITE_ is a word character).
  @embedded_pairs [{"RUNNER_SUITE_RENDER_DIR", "RUNNER_BURROW_RENDER_DIR"}]

  # Literal path prefixes, each with its reason.
  @exempt_prefixes [
    # Historical audit records; their prose rebrand belongs to task A2.
    "audit/",
    # Dated engineering notes; historical, A2 owns them.
    "apps/platform/notes/",
    # Accepted ADRs are records of what was decided at the time; A2 owns them.
    "docs/decisions/",
    # This file names every SUITE_ literal on purpose.
    "apps/platform/test/platform/regression/burrow_env_fallback_guard_test.exs"
  ]

  # A token starts at any character that is not an uppercase letter, digit or
  # underscore. Stricter than `\b`: `\b` misses `\nSUITE_AGENT_ID` inside a
  # JS template literal, because the `n` of `\n` is a word character.
  @suite_token ~r/(?<![A-Z0-9_])SUITE_[A-Z0-9_]+/
  @burrow_token ~r/(?<![A-Z0-9_])BURROW_[A-Z0-9_]+/

  defp tracked_files do
    # CI's Test job runs as root in a container over a workspace the runner's
    # uid owns, so git refuses the repo as "dubious ownership" (exit 128).
    # actions/checkout writes its safe.directory entry under a temporary HOME
    # that later steps do not read. Command-line config is protected
    # configuration, so git honours it here; the > 1000 positive control
    # below still fires on any other failure to list the tree.
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

  defp tokens(regex, body), do: regex |> Regex.scan(body) |> List.flatten() |> MapSet.new()

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
    assert Enum.any?(files, fn {path, _} -> path == "scripts/suite_runnerd.py" end)
    %{files: files}
  end

  test "(A) the literal lists have their fixed sizes and are pairwise disjoint" do
    assert length(@fallback_names) == 34
    assert length(@out_of_scope) == 8
    assert length(@renamed_outright) == 7

    assert Enum.uniq(@fallback_names ++ @out_of_scope ++ @renamed_outright) ==
             @fallback_names ++ @out_of_scope ++ @renamed_outright

    for {a, b} <- [
          {@fallback_names, @out_of_scope},
          {@fallback_names, @renamed_outright},
          {@out_of_scope, @renamed_outright}
        ] do
      assert MapSet.disjoint?(MapSet.new(a), MapSet.new(b))
    end
  end

  test "(B) every SUITE_ token in the tree is a listed fallback or out-of-scope name",
       %{files: files} do
    known = MapSet.new(@fallback_names ++ @out_of_scope)

    unknown =
      for {path, body} <- files,
          {line, token} <- suite_occurrences(body),
          not MapSet.member?(known, token),
          do: "#{path}:#{line}:#{token}"

    assert unknown == [],
           "SUITE_ tokens not in @fallback_names or @out_of_scope " <>
             "(bridge them BURROW-first and add them to the literal list, " <>
             "or rename them):\n" <> Enum.join(unknown, "\n")
  end

  test "(C) no file still names a SUITE_ spelling that was renamed outright",
       %{files: files} do
    renamed = MapSet.new(@renamed_outright)

    hits =
      for {path, body} <- files,
          {line, token} <- suite_occurrences(body),
          MapSet.member?(renamed, token),
          do: "#{path}:#{line}:#{token}"

    assert hits == [], "renamed-outright names reappeared:\n" <> Enum.join(hits, "\n")
  end

  test "(D) every file naming an in-scope SUITE_X also names BURROW_X", %{files: files} do
    missing =
      for {path, body} <- files,
          suite = tokens(@suite_token, body),
          burrow = tokens(@burrow_token, body),
          name <- @fallback_names,
          MapSet.member?(suite, name),
          twin = "BURROW_" <> String.replace_prefix(name, "SUITE_", ""),
          not MapSet.member?(burrow, twin),
          do: "#{path}: names #{name} but not #{twin}"

    embedded =
      for {path, body} <- files,
          {old, new} <- @embedded_pairs,
          String.contains?(body, old),
          not String.contains?(body, new),
          do: "#{path}: names #{old} but not #{new}"

    assert missing ++ embedded == [],
           "SUITE_ names without their BURROW_ twin in the same file:\n" <>
             Enum.join(missing ++ embedded, "\n")
  end
end
