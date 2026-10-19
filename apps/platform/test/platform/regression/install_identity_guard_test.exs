defmodule Platform.Regression.InstallIdentityGuardTest do
  @moduledoc """
  An open-source checkout must carry no install or personal identity: no
  operator org, domain, host, home path, LAN address or person's name
  (task 01a14b9e; it supersedes the narrower 01a116de guard).

  `Platform.Regression.InstallIdentityScanner` (test/support) does the
  matching and documents it: the denylist is sha256 digests only, so this
  guard does not spell what it hunts, and shipped app-store identifiers are
  exempted by a narrow LITERAL list. Read its moduledoc before changing
  either side.

  Scanned: EVERY tracked file (`git ls-files -z` at the repo root), its
  content when it is text and its PATH always. Build output, dependencies
  and anything untracked are never scanned. If git cannot list the tree the
  tests fail with git's output; they never skip.

  ## Three literal lists (owner decision, task 01a14b9e stage 5)

    * `@allowlist`: files allowed a hit at an EXACT count, each with a KEEP
      reason. Only English words live here (today one file, the emoji
      keyword data), and the list is capped at 10 entries. It fails when a file has MORE hits than its
      entry, or FEWER or none (the ratchet: a change that removes hits must
      shrink the list).
    * `@published_ids` (in the scanner): shipped app-store identifiers,
      exempt byte-for-byte, renamed (or not) by task A2b.
    * `@applied_migrations`: applied migrations whose hits are data a fresh
      install still writes, so editing them would change a fresh database.
      Each is pinned by whole-file sha256 with a reason.

  Task A3b (01a14dce-d2d8-7000-becf-79544fe7cf98) emptied and deleted the
  fourth list, the files it was to rewrite. Task A3c
  (01a14dd9-7172-7000-874c-b9ae3d4c1c83) deleted the scoped client set A3b
  left on 40 of those paths: the tenant and client digests are on the one
  tree-wide denylist now, pinned by the literal list in `TENANT AND CLIENT
  DIGESTS` below.

  A pinned file that changes fails as a STALE PIN naming it: an edit to it
  is exactly the moment to remove its hits, or to re-pin it deliberately
  with the reason. Any file on none of the lists with a hit fails, and so
  does a path on two lists, a list key that itself carries a hit, and a
  plaintext term in the guard's own sources.

  A file whose PATH carries a term cannot be listed, because its key would
  spell the term here: rename the file.
  """
  use ExUnit.Case, async: true

  alias Platform.Regression.InstallIdentityScanner, as: Scanner

  @repo_root Path.expand("../../../../..", __DIR__)

  @guard_sources [
    "apps/platform/test/platform/regression/install_identity_guard_test.exs",
    "apps/platform/test/support/install_identity_scanner.ex"
  ]

  # The general allowlist's cap. The pinned lists below are not counted
  # against it: each is a separate literal list with its own justification.
  @allowlist_cap 10

  # %{relative_path => exact hit count}.
  #
  # Stage 6 inlined the dark-mode glyph as an SVG and renamed the theme
  # toggle's variables, so app.css, theme_toggle.js, layouts.ex,
  # shell.html.heex and theme_toggle_test.exs left this list at 0 hits.
  @allowlist %{
    # KEEP: emoji keyword data (English words and one country name)
    "apps/platform/assets/emoji/data.js" => 37
  }

  @applied_migrations %{
    "apps/platform/priv/repo/migrations/20260708130000_seed_prompt_templates_security_guard.exs" =>
      {"b50b33817af05bc3ef0605ce0e01f4dda9b6ba475ea43ff747ea337760884200",
       "frozen security.deploy_audit.v1 body a fresh install still serves (fresh-DB proof: editing it changes prompt_templates)"}
  }

  setup_all do
    case Scanner.tracked_files(@repo_root) do
      {:ok, files} ->
        %{
          tracked: {:ok, files},
          counts: Scanner.counts(@repo_root, files)
        }

      {:error, message} ->
        %{tracked: {:error, message}, counts: nil}
    end
  end

  defp tracked!(%{tracked: {:ok, files}}), do: files

  defp tracked!(%{tracked: {:error, message}}),
    do: flunk("cannot list the tracked tree: " <> message)

  defp counts!(ctx) do
    tracked!(ctx)
    ctx.counts
  end

  defp pinned, do: @applied_migrations

  defp listed?(path),
    do: Map.has_key?(@allowlist, path) or Map.has_key?(@applied_migrations, path)

  defp file_sha256(path) do
    case File.read(Path.join(@repo_root, path)) do
      {:ok, bin} -> Scanner.digest(bin)
      {:error, reason} -> {:error, reason}
    end
  end

  defp pin_problem(path, sha, files, counts) do
    cond do
      not MapSet.member?(files, path) -> "#{path}: pinned but not tracked"
      file_sha256(path) != sha -> "#{path}: STALE PIN, content changed since it was pinned"
      Map.get(counts, path, 0) == 0 -> "#{path}: pinned but has no hit; delete the pin"
      true -> nil
    end
  end

  # Every allowlist entry as {path, allowed, actual}.
  defp entries(counts) do
    @allowlist
    |> Enum.map(fn {path, n} -> {path, n, Map.get(counts, path, 0)} end)
    |> Enum.sort()
  end

  test "the scanned set is the real tracked tree", ctx do
    files = tracked!(ctx)
    assert length(files) > 4000
    assert "apps/platform/lib/platform/tenancy.ex" in files
    assert "clients/ios/README.md" in files
    refute Enum.any?(files, &String.contains?(&1, ["/_build/", "/deps/", "/node_modules/"]))
  end

  test "no file on none of the lists has a hit", ctx do
    found =
      ctx
      |> counts!()
      |> Enum.reject(fn {path, _} -> listed?(path) end)
      |> Enum.sort()
      |> Enum.map(fn {path, n} -> "#{path} (#{n})" end)

    assert found == [],
           "install or personal identity in files on no list (it belongs in " <>
             "install config or the DB, not in the tree): " <> Enum.join(found, ", ")
  end

  test "no allowlisted file has MORE hits than its entry", ctx do
    over =
      for {label, allowed, actual} <- entries(counts!(ctx)),
          actual > allowed,
          do: "#{label}: #{actual} hits, allowlist says #{allowed}"

    assert over == [], "hits grew: " <> Enum.join(over, "; ")
  end

  test "RATCHET: no allowlisted file has FEWER hits than its entry, and none has zero", ctx do
    under =
      for {label, allowed, actual} <- entries(counts!(ctx)),
          actual < allowed or actual == 0,
          do: "#{label}: #{actual} hits, allowlist says #{allowed}"

    assert under == [],
           "hits shrank; lower the entry to the new count, or delete it at zero: " <>
             Enum.join(under, "; ")
  end

  test "CAP: the general allowlist holds at most 10 entries" do
    assert @allowlist_cap == 10

    assert map_size(@allowlist) <= @allowlist_cap,
           "the general allowlist has #{map_size(@allowlist)} entries, over its cap of " <>
             "#{@allowlist_cap}: remove hits instead of listing files"
  end

  test "PINS: every pinned file is tracked, unchanged since its pin, and still has a hit", ctx do
    files = MapSet.new(tracked!(ctx))
    counts = counts!(ctx)

    problems =
      pinned()
      |> Enum.sort()
      |> Enum.map(fn {path, {sha, _reason}} -> pin_problem(path, sha, files, counts) end)
      |> Enum.reject(&is_nil/1)

    assert problems == [], Enum.join(problems, "; ")
  end

  test "every entry on every list carries a reason, and no path is on two lists" do
    for {path, {sha, reason}} <- pinned() do
      assert sha =~ ~r/\A[0-9a-f]{64}\z/, path
      assert is_binary(reason) and String.length(reason) > 20, path
    end

    for {path, _, reason} <- Scanner.published_ids(),
        do: assert(is_binary(reason) and reason != "", path)

    all = Map.keys(@allowlist) ++ Map.keys(@applied_migrations)
    assert length(all) == length(Enum.uniq(all))
  end

  test "no list key carries a hit" do
    keys = Map.keys(@allowlist) ++ Map.keys(@applied_migrations)
    keyed = for path <- keys, Scanner.count(path) > 0, do: path
    assert keyed == []
  end

  test "the guard's own sources carry no plaintext term" do
    found =
      for rel <- @guard_sources,
          n = Scanner.count_file(@repo_root, rel),
          n > 0,
          do: "#{rel} (#{n})"

    assert found == []
    # Not vacuous: each source exists and is read as text.
    for rel <- @guard_sources do
      bin = File.read!(Path.join(@repo_root, rel))
      assert Scanner.text?(bin)
      assert byte_size(bin) > 1000
    end
  end

  @tag :tmp_dir
  test "EXEMPTION IS NARROW: only the listed identifier's own bytes are exempt",
       %{tmp_dir: dir} do
    [{android, :namespace, _} | _] = Scanner.published_ids()
    other = String.replace(android, ".burrow", ".other")
    lookalike = android <> "x"
    org = android |> String.split(".") |> Enum.at(1)

    fixture = Path.join(dir, "build.gradle")
    File.write!(fixture, android <> "\n" <> other <> "\n")
    assert Scanner.count_file(dir, "build.gradle") == 1
    # the one hit is the second line's org token, four bytes into it
    assert [{offset, _}] = Scanner.hits(File.read!(fixture))
    assert offset == byte_size(android) + 1 + byte_size("com.")

    assert Scanner.count(android) == 0
    assert Scanner.count(android <> ".debug") == 0
    assert Scanner.count(lookalike) == 1
    assert Scanner.count("x." <> android) == 1
    assert Scanner.count(android <> " " <> org) == 1
  end

  test "TOKENS: whole tokens only, camelCase split, compounds and literals" do
    [{android, _, _}, {ios, _, _} | _] = Scanner.published_ids()
    org = android |> String.split(".") |> Enum.at(1)
    hyphen_org = ios |> String.split(".") |> Enum.at(1)

    camel = String.capitalize(org) <> "Admin"
    assert Scanner.count(camel) == 1
    assert Scanner.count(String.upcase(org)) == 1
    assert Scanner.count(org <> "ish") == 0
    # a hyphenated org host: its first token and the dot-suffix compound
    assert Scanner.count("www." <> hyphen_org <> ".com") == 2
    # assembled so this file does not carry the address it tests
    assert Scanner.count("lan " <> "192." <> "168.4.20 here") == 1
    assert Scanner.count("lan 192.0.2.20 here") == 0
    assert Scanner.count("/var/" <> "home/someone") == 1
    # the derived org token page tests refute is itself a denylisted term
    assert Scanner.count(Scanner.published_org_token()) == 1
    assert String.starts_with?(hyphen_org, Scanner.published_org_token() <> "-")
  end

  test "RENDERED HTML: hits/1 has no page exemption, so a class token is a hit" do
    # The dark-mode glyph's library class name, built from bytes so this file
    # does not spell it. Stage 6 removed it from the shell and layouts.ex
    # (inline SVG) and removed the page_hits/1 exemption that let it pass.
    word = <<109, 111, 111, 110>>
    assert Scanner.count(word) == 1

    # POSITIVE CONTROL: the markup the shell rendered before stage 6 is a hit
    # in the class token, at the word's offset
    old = ~s(<span data-icon="dark" class="hero-#{word} size-4"></span>)
    assert [{offset, 4}] = Scanner.hits(old)
    assert binary_part(old, offset, 4) == word
    assert Scanner.count(~s(<span class='opacity-75 hero-#{word}-micro'></span>)) == 1
    refute function_exported?(Scanner, :page_hits, 1)

    # a planted org token inside a class attribute is a hit too
    org = Scanner.published_org_token()
    assert Scanner.count(~s(<span class="hero-#{org} size-4"></span>)) == 1

    # NEGATIVE: the markup the shell renders now carries no hit
    svg =
      ~s(<svg data-icon="dark" class="size-4 align-middle" viewBox="0 0 24 24" ) <>
        ~s(stroke="currentColor"><path d="M21.752 15.002A9.72 9.72 0 0 1 18 15.75"/></svg>)

    assert Scanner.hits(svg) == []
  end

  @tag :tmp_dir
  test "POSITIVE CONTROL: a fixture carrying a camelCase term and a compound is named, and only it",
       %{tmp_dir: dir} = ctx do
    [{android, _, _}, {ios, _, _} | _] = Scanner.published_ids()
    org = android |> String.split(".") |> Enum.at(1)
    hyphen_org = ios |> String.split(".") |> Enum.at(1)

    fixture = Path.join(dir, "fixture.ex")
    File.write!(fixture, "# #{String.capitalize(org)}Admin\n# www.#{hyphen_org}.com\n")
    rel = Path.relative_to(fixture, @repo_root)

    counts = Map.merge(counts!(ctx), Scanner.counts(@repo_root, [rel]))
    named = for {path, _} <- counts, not listed?(path), do: path

    assert named == [rel]
    assert counts[rel] == 3
  end

  # -- tenant and client terms (task A3c 01a14dd9 stage 5) ---------------------

  # The eight tenant and client term digests, LITERALLY. A derived set would
  # not catch a digest deleted from the scanner: LIB POSITIVE CONTROL below
  # plants an older term and stays green with all eight removed (stage 5,
  # mutation m3). In order: tenant slug 1, the part of slug 2 after its `_`,
  # the client org (slug 3), slug 4, the fifth org, the client's product, the
  # client's hyphenated full name, the client's contact.
  @tenant_client_digests [
    "1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b",
    "a4914116477206d6766723e306a2fe39e4b97c3cabfce141310622adbb33d34e",
    "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d",
    "d0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c",
    "71ce8a1658507fc4e432cb3621322632972d9256e652b1dee92af6528719216f",
    "4de7d59fd6866c46855c913fe9c7e498228200fdfcbb326f80062bdde43f4b51",
    "fb3a3f5343ca1ff87236fb75ad0f48987d0fd0f4d15b787fb59057e37186f2a0",
    "17d93b3e93059e01484fabea3489be14fc463ea0998b183a3360489e812fbf2c"
  ]

  test "TENANT AND CLIENT DIGESTS: all eight are on the tree-wide denylist" do
    assert length(@tenant_client_digests) == 8
    assert length(Enum.uniq(@tenant_client_digests)) == 8
    assert Enum.all?(@tenant_client_digests, &(&1 =~ ~r/\A[0-9a-f]{64}\z/))

    missing = Enum.reject(@tenant_client_digests, &Scanner.listed_digest?/1)
    assert missing == [], "not on the denylist: " <> Enum.join(missing, ", ")

    assert MapSet.size(Scanner.digests()) == 29

    # Every term digest the shipped-org records carry is listed, and the
    # records name no term outside the root and these eight.
    record_terms = Platform.Tenancy.HistoricalRootSlug.term_digests()
    unlisted = Enum.reject(record_terms, &Scanner.listed_digest?/1)

    assert unlisted == [],
           "record term digests not on the denylist: " <> Enum.join(unlisted, ", ")

    assert MapSet.subset?(MapSet.new(@tenant_client_digests), MapSet.new(record_terms))

    # The scoped set A3b left is gone, not merely emptied.
    refute function_exported?(Scanner, :scoped_digests, 0)
    refute function_exported?(Scanner, :scoped_paths, 0)
    refute function_exported?(Scanner, :scoped_path?, 1)
    refute function_exported?(Scanner, :hits, 2)
    refute function_exported?(Scanner, :count, 2)
  end

  @tag :tmp_dir
  test "LIB POSITIVE CONTROL: a term planted in a copy of projects.ex is named, and only it",
       %{tmp_dir: dir} = ctx do
    rel = "apps/platform/lib/platform/projects.ex"
    planted_root = Path.join(dir, "repo")
    planted = Path.join(planted_root, rel)
    File.mkdir_p!(Path.dirname(planted))

    # No preimage of the eight is left in the tree (stage 4), so the plant is
    # the operator org token derived from the shipped identifiers.
    original = File.read!(Path.join(@repo_root, rel))
    assert Scanner.count(original) == 0
    File.write!(planted, original <> "# #{Scanner.published_org_token()}\n")

    counts = Map.merge(counts!(ctx), Scanner.counts(planted_root, [rel]))
    named = for {path, n} <- Enum.sort(counts), not listed?(path), do: {path, n}

    assert named == [{rel, 1}]
  end
end
