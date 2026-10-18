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

  ## Four literal lists (owner decision, task 01a14b9e stage 5)

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
    * `@deferred`: files task A3b (01a14dce-d2d8-7000-becf-79544fe7cf98)
      rewrites, pinned by whole-file sha256 with a reason. A3b is a
      precondition for publishing the tree.

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

  @deferred %{
    "apps/platform/lib/platform/meetings/intent_classifier.ex" =>
      {"3d1a3e3c7f978fdb79227f5814a04c8da860a881a2822aac7c0c0631010741fa",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/imp_pilot/open_question/prompt_a.txt" =>
      {"5afe1aa91e2ffd9ec566af27815ae1bf481d59ca99bb525f78c3701ba580a6f3",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/README.md" =>
      {"a7ced745457199475f2573dc884d2e7fdfd105a234a23251ee0398c16b45c9e4",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/cassettes/agent_roster_20260831.jsonl" =>
      {"5aae6df852cbda3e6e89ecf742e88d5d9c248848217e8727268f41f3f53b3aff",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/cassettes/broken_malformed_schema.jsonl" =>
      {"66e2d02a734c64f091a1291ddbf6fc3d856b28a51069b79cfbf28704110a7683",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/cassettes/broken_never_off_topic.jsonl" =>
      {"e8019efff1426c816c02317da9b3b4f728626be8557e4a25b7a96cecc4961b2a",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/cassettes/off_topic_default.jsonl" =>
      {"4c9c2b028a167ac2904136c9cf418fdef4c2538fd6e1962ae27d692b0f29551f",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/manifest.json" =>
      {"60ef20c5e8cd2ba83d2c2803af207912c944af3a321426fc546fae79de5f0c26",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/prompts/agent_roster.txt" =>
      {"5afe1aa91e2ffd9ec566af27815ae1bf481d59ca99bb525f78c3701ba580a6f3",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/prompts/agent_roster_20260831.txt" =>
      {"95c9b7024aa64223ff2c8f87de1b359708dd20eb7b45c13dc157487bdd6831eb",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/prompts/off_topic_default.txt" =>
      {"882cfd0ca7ee2e43f294d046c2379301bb1def85eb2cfba8de89c15e8ec21098",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T110556Z-off_topic_default.json" =>
      {"8525a3395f4856c7538bf4188a4a577c4639ab57414324ce792f26c0ae6e3623",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T110558Z-binary_actionable.json" =>
      {"073463eb0199f9ac4a5a5e8285b535b693085b79e0e85766529e380f23282591",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T112342Z-broken_always_off_topic.json" =>
      {"82e60a129a6772aae9c4af7a37658edca8071916689b61b8bc5df2b05ff331de",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T112430Z-broken_never_off_topic.json" =>
      {"71da8f68dee5f462aa16900eaa8845024d372cb3f8b1b674e1f245653d5c2bec",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T112542Z-broken_malformed_schema.json" =>
      {"146b786a0fa6d733484fa60701e1ef7c000f5bd7aa03b6cca36cc5d3a071f9ba",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T112755Z-off_topic_default.json" =>
      {"c7edecb78a5f8528c79cd9970b246ecf9451d87fdeec7609ad5b5c81505e732c",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260827T112756Z-off_topic_default.json" =>
      {"e77acb70d0b5c7e6fef7e1c759ea7a2ddf127c8bbb4f93d297b57284de5e46ff",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260829T061814Z-off_topic_default.json" =>
      {"fe31803e9129fad354b701ce4c84a3f15d830370dbeb8e3926d9b453211ebe77",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260831T223440Z-agent_roster.json" =>
      {"841acb69ee1c4356821b5cef5f4c40d03e1d54e0711a10ca64c380389dbfa3d7",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260831T225724Z-off_topic_default.json" =>
      {"ef447a27214805b58aa0580cab505f84d863067e688937cb9dcb1ad6550591d1",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/runs/20260831T225725Z-agent_roster.json" =>
      {"bf7cac5fd10ac34887dbd1f7f8c07bb08f06a06830aac41ceb464b89cceeb9d5",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/slices/control_60.jsonl" =>
      {"79b5d4a66289244863960187a5ccfe4a678b6ad9b9d24c2b04937f44dd1e0790",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/slices/delegation_probe.jsonl" =>
      {"2317e834f543d2db8bc14c999cbbe5d6e0b4d734ae25b63d2bf6598761c851ea",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/slices/negatives_102.jsonl" =>
      {"2529c5ebb0cc131991ece29799230c9f6e5e2dbc801566c9af97e471d08ce850",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/slices/unaddressed_meeting_speech_48.jsonl" =>
      {"a117f4b37ce7f803925bdc884aa742427924774987577250c36bb1cf20b65c74",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/intent_eval/slices/unaddressed_probe_12.jsonl" =>
      {"c92944589cd701b1b649fc5f2f22462e7e0a2373bd8d4a2b66932fd7115e7afd",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/priv/repo/migrations/20260826120000_force_update_intent_classify_prompt_off_topic_default.exs" =>
      {"8e3b86f62bd0935915c72bb39061c0b541174d5f5a00f7e5aba265287dc3e6cc",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: applied classify-prompt body carrying the exemplar utterance; A3b supersedes it"},
    "apps/platform/priv/repo/migrations/20260902140000_force_update_intent_classify_prompt_unmerge_intent_and_target.exs" =>
      {"bf5643d3a32c25d856ff4eb65b0298d2a63e075205a3c866ea186a5620f32ed9",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: applied classify-prompt body carrying the exemplar utterance; A3b supersedes it"},
    "apps/platform/priv/repo/migrations/20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged.exs" =>
      {"4ffa9f17255efeb0d006de7fcf6f393388c0ab70dbe586d82db42c925206f686",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: applied classify-prompt body carrying the exemplar utterance; A3b supersedes it"},
    "apps/platform/test/platform/meetings/intent_addressee_test.exs" =>
      {"01c1631f18577dedd1726b9d60078396168f00d5ecbeacbe159fadf9d82f2057",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/meetings/intent_classifier_test.exs" =>
      {"f32297b6a8bf4ae2e61ff31a93d6ab9f5227894605fe402fc947af893816243b",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/meetings/intent_eval/delegation_probe_test.exs" =>
      {"a5f37d672aa12785671fcaa0637130beefc12a0cb50fdd447fb5c21ccce6fcda",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/meetings/intent_eval/harness_test.exs" =>
      {"71675a4c2823a2b08d6a468431083deb2fa227561e6781155017fb12b8700709",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/meetings/intent_eval_test.exs" =>
      {"2a37942e3c7c998aef0b8ef0c99d849f9c1ba77b525d8af3deca5bb58c306c2f",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/meetings/intent_unaddressed_action_item_test.exs" =>
      {"5cebb105df60ad4b4105ad3452fc6216ee8d86c657d8a6e2fe1ff32d34c79702",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/platform/repo/migrations/seed_prompt_template_intent_classify_test.exs" =>
      {"a0d74005f32b9f5e983ca42d821ca4bb0442515daf14fb015a063f386c7fe602",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "apps/platform/test/support/fixtures/intent_classify_negatives.jsonl" =>
      {"b4cbf8334b42b9a07a7dbad49206b80414c49a65936628552c6b79f2f45e754c",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: classifier exemplar utterance (eval data and pins keyed on it)"},
    "clients/android/android/app/src/test/java/com/koboai/burrow/InstallStoreTest.kt" =>
      {"c8fc7df3d6e9e907470237d427ff3e7321462bb6b4292621f0f7c4e635d3035e",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: preimages of the shipped legacy-host hash list this test proves"},
    "clients/ios/ios/App/AppTests/InstallStoreTests.swift" =>
      {"5969be1d5840249ab4d5b3a38829913dd40d7cfd64fc74453c42d66e17bd8ed0",
       "A3b 01a14dce-d2d8-7000-becf-79544fe7cf98: preimages of the shipped legacy-host hash list this test proves"}
  }

  setup_all do
    case Scanner.tracked_files(@repo_root) do
      {:ok, files} -> %{tracked: {:ok, files}, counts: Scanner.counts(@repo_root, files)}
      {:error, message} -> %{tracked: {:error, message}, counts: nil}
    end
  end

  defp tracked!(%{tracked: {:ok, files}}), do: files

  defp tracked!(%{tracked: {:error, message}}),
    do: flunk("cannot list the tracked tree: " <> message)

  defp counts!(ctx) do
    tracked!(ctx)
    ctx.counts
  end

  defp pinned, do: Map.merge(@applied_migrations, @deferred)

  defp listed?(path),
    do:
      Map.has_key?(@allowlist, path) or Map.has_key?(@applied_migrations, path) or
        Map.has_key?(@deferred, path)

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

    keys = [Map.keys(@allowlist), Map.keys(@applied_migrations), Map.keys(@deferred)]
    all = List.flatten(keys)
    assert length(all) == length(Enum.uniq(all))

    for path <- Map.keys(@deferred) do
      {_, reason} = @deferred[path]
      assert reason =~ "01a14dce-d2d8-7000-becf-79544fe7cf98", path
    end
  end

  test "no list key carries a hit" do
    keys = Map.keys(@allowlist) ++ Map.keys(@applied_migrations) ++ Map.keys(@deferred)
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
end
