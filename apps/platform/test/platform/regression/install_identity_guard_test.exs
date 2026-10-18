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
  fourth list, the files it was to rewrite. Those 40 paths now carry a
  SECOND denylist instead, the scanner's scoped client set (two client
  digests, applied to those paths only; read the scanner's moduledoc).

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
          counts: Scanner.counts(@repo_root, files),
          scoped_preimages: scoped_preimages(files)
        }

      {:error, message} ->
        %{tracked: {:error, message}, counts: nil, scoped_preimages: %{}}
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
    # Not vacuous: each source exists and is read as text. Neither source is
    # a scoped path, so the scoped client set is checked here explicitly.
    for rel <- @guard_sources do
      bin = File.read!(Path.join(@repo_root, rel))
      assert Scanner.text?(bin)
      assert byte_size(bin) > 1000
      assert Scanner.count(bin, :scoped) == 0, "#{rel} spells a scoped client term"
      assert Scanner.count(rel, :scoped) == 0
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

  # -- the scoped client set (task 01a14dce stage 4) ---------------------------

  # Each scoped term is derived from the tracked tree, never spelled: the
  # first token in a tracked file OUTSIDE the scoped set whose digest is the
  # scoped digest. Both terms are in the tree today (the org in the tenant
  # list, the contact in a test fixture). When task A3c sweeps them out, this
  # flunks: move the digests to the general list there and take the fixtures
  # from the reviewer.
  defp scoped_preimages(files) do
    wanted = Scanner.scoped_digests()

    files
    |> Enum.reject(&Scanner.scoped_path?/1)
    |> Enum.reduce_while(%{}, fn rel, acc ->
      acc = Map.merge(preimages(rel, wanted), acc)
      if map_size(acc) == MapSet.size(wanted), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp scoped_terms!(ctx) do
    tracked!(ctx)
    wanted = Scanner.scoped_digests()
    found = ctx.scoped_preimages

    assert map_size(found) == MapSet.size(wanted),
           "no preimage left in the tracked tree for #{MapSet.size(wanted) - map_size(found)} " <>
             "scoped digest(s): fixtures for the scoped tests must come from the reviewer"

    wanted |> Enum.sort() |> Enum.map(&Map.fetch!(found, &1))
  end

  defp preimages(rel, wanted) do
    case File.read(Path.join(@repo_root, rel)) do
      {:ok, bin} ->
        if Scanner.text?(bin) do
          for [tok] <- Regex.scan(~r/[a-z0-9]+/, String.downcase(bin, :ascii)),
              d = Scanner.digest(tok),
              MapSet.member?(wanted, d),
              into: %{},
              do: {d, tok}
        else
          %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @inside "apps/platform/test/platform/meetings/intent_eval/harness_test.exs"
  @outside "apps/platform/lib/platform/tenancy.ex"

  test "SCOPED SET: two term digests and 40 path digests, none in the general set", ctx do
    terms = Scanner.scoped_digests()
    paths = Scanner.scoped_paths()

    assert MapSet.size(terms) == 2
    assert MapSet.size(paths) == 40
    assert Enum.all?(MapSet.union(terms, paths), &(&1 =~ ~r/\A[0-9a-f]{64}\z/))
    refute Enum.any?(terms, &Scanner.listed_digest?/1)

    # 29 of the 40 are tracked today; the other 11 are the pre-rename run
    # files stage 2 deleted, still scoped should one be re-created.
    tracked = Enum.filter(tracked!(ctx), &Scanner.scoped_path?/1)
    assert length(tracked) == 29
    assert Enum.all?(tracked, &(not listed?(&1)))

    assert Scanner.scoped_path?(@inside)
    assert Scanner.scoped_path?("apps/platform/priv/intent_eval/slices/control_60.jsonl")

    assert Scanner.scoped_path?(
             "clients/android/android/app/src/test/java/com/koboai/burrow/InstallStoreTest.kt"
           )

    assert Scanner.scoped_path?("clients/ios/ios/App/AppTests/InstallStoreTests.swift")
    refute Scanner.scoped_path?(@outside)
    refute Scanner.scoped_path?("apps/platform/priv/intent_eval/README")
  end

  @tag :tmp_dir
  test "SCOPED: a client term, alone or camelCased, is a hit at a scoped path",
       %{tmp_dir: dir} = ctx do
    terms = scoped_terms!(ctx)
    assert length(terms) == 2

    for term <- terms do
      camel = String.capitalize(term) <> "Admin"

      for {text, n} <- [
            {term, 1},
            {String.upcase(term), 1},
            {camel, 1},
            {"# #{camel} and #{term}\n", 2}
          ] do
        write!(dir, @inside, text)
        assert Scanner.count_file(dir, @inside) == n, "scoped plant not counted #{n}x"
      end

      # whole tokens only, as in the general set
      write!(dir, @inside, term <> "ish")
      assert Scanner.count_file(dir, @inside) == 0
    end
  end

  @tag :tmp_dir
  test "SCOPE: the same client terms OUTSIDE the scoped paths are not hits",
       %{tmp_dir: dir} = ctx do
    text =
      ctx |> scoped_terms!() |> Enum.map_join("\n", &(String.capitalize(&1) <> "Admin " <> &1))

    write!(dir, @inside, text)
    assert Scanner.count_file(dir, @inside) == 4

    write!(dir, @outside, text)
    assert Scanner.count_file(dir, @outside) == 0
    assert Scanner.count(text) == 0
    assert Scanner.count(text, :scoped) == 4
  end

  @tag :tmp_dir
  test "SCOPED POSITIVE CONTROL: a planted client term in a real scoped file is named",
       %{tmp_dir: dir} = ctx do
    [term | _] = scoped_terms!(ctx)
    write!(dir, @inside, File.read!(Path.join(@repo_root, @inside)) <> "# " <> term <> "\n")

    counts = Map.merge(counts!(ctx), Scanner.counts(dir, [@inside]))
    named = for {path, _} <- counts, not listed?(path), do: path

    assert named == [@inside]
    assert counts[@inside] == 1
  end

  defp write!(dir, rel, text) do
    abs = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, text)
  end
end
