defmodule Platform.Regression.InstallIdentityScanner do
  @moduledoc """
  The scanner behind `Platform.Regression.InstallIdentityGuardTest`: finds
  install and personal identity (an operator's org, domains, hosts, people)
  in text, so an open-source checkout carries none of it (task 01a14b9e).

  ## Why the denylist is digests

  The guard is public code. A guard that spells the terms it hunts is itself
  the trace it exists to remove, so the denylist is stored ONLY as sha256 hex
  digests of lowercase terms (`@digests`). That keeps the terms out of grep,
  code search and casual reading. **It does not stop someone who already
  guesses a term from confirming it**: hashing a guess and comparing is
  exactly what this module does. Treat the digests as "not spelled out", not
  as secret.

  To add a term, append its digest:

      printf %s <lowercase term> | sha256sum

  A term is one whole token (`[a-z0-9]+`) or one compound (a dotted or
  hyphenated run such as a host name). Two shapes identify nothing on their
  own and stay literal regexes: private IPv4 addresses in `192.168/16`, and
  home-directory paths under `/var` (`literal_patterns/0`).

  ## What counts as a hit

    * **Tokens.** Every ASCII alphanumeric run is split at camelCase
      boundaries (`FooBar` -> `foo`, `bar`; `HTTPServer` -> `http`,
      `server`), lowercased, and each piece is hashed. Whole tokens only:
      an English word that merely CONTAINS a term is not a hit.
    * **Compounds.** Every maximal `[a-z0-9]+([.-][a-z0-9]+)+` run in the
      lowercased text, and each of its dot-suffixes (`a.b-c.d` -> `a.b-c.d`,
      `b-c.d`, `d`), is hashed too. The run is taken twice, once with `/` as a
      separator and once with `/` read as `.` (paths and package names);
      a span found both ways is one hit.
    * **Literals.** The two regexes above.

  ## The scoped client set

  A second digest set, `@scoped_digests`, holds a client org and a client
  contact that eval rows once named (task 01a14dce-d2d8-7000-becf-79544fe7cf98
  stage 4). It applies ONLY to the files whose repo-relative path digest is
  in `@scoped_paths`: the 40 files the guard's former deferred list carried
  (the intent-classify family, the intent-eval corpus and tests, and the
  two `InstallStore` tests; 11 of them are run files deleted since, so a
  file re-created at one of those paths is scoped too). Paths are stored as
  sha256 of the exact relative path, so the list spells nothing either.

  It is scoped, not tree-wide, on purpose: the org term is still in more
  than 200 tracked files, including the tenant list in `Platform.Tenancy`
  and applied migrations, and three more tenant orgs sit beside it. The
  tree-wide tenant-client sweep is task A3c
  (01a14dd9-7172-7000-874c-b9ae3d4c1c83); it moves these digests into
  `@digests` and deletes this set.

  ## The published-identifier exemption

  `published_ids/0` lists, LITERALLY, the identifiers already shipped in the
  app stores (Android package, iOS bundle ids, App Group, keychain group).
  They are public, and renaming them is follow-up task A2b
  (01a14ba9-e428-7000-86ec-d39a97ab863c), not this guard's job. A hit is
  exempt only when its bytes lie inside an exact occurrence of a listed
  identifier:

    * the occurrence must start at a boundary: the byte before it is not
      `[a-z0-9_.-]` (a `/` is a boundary, so a source path under the package
      directory matches);
    * the byte after it is not `[a-z0-9_-]`. For a `:namespace` entry a
      following `.` or `/` is allowed: what follows is a child name inside
      that namespace (a subpackage, a class, an intent action, an extension
      bundle id), and its own tokens are still scanned and still hit. For an
      `:exact` entry a following `.` or `/` is allowed only when no
      alphanumeric follows it.

  No prefix wildcard and no glob: the exemption covers the listed bytes and
  nothing else, so a lookalike identifier, a different id under the same
  org prefix, or the bare org token elsewhere in the same file is a hit.
  """

  # sha256(lowercase term), hex. See the moduledoc for how to add one.
  @digests MapSet.new([
             "9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c",
             "3764dab897891d348f2022a54f44cd8d70b4557131a6349560bb81330ccf31f0",
             "44506f784f8d79f5c01259f925b02d157fc5703fa334313d7575d43f308c9a36",
             "344d0bfd9b610f39806a18638c537bfb0d490bca45ea21f9ec0487f0f05cee04",
             "90ca1d1dbf0e1ff1f4a51312b9f2f0602df43b17ea1385995ccc6a4615e1670e",
             "ee5c510a0f6e925fa732d3ad01bda596dfe3e8a346c02cb992d2a58a3a77fa88",
             "e746712dbcaf563f020e05fe3c6d446299f2f2aace319cd31075412687af7342",
             "7640da40298286a6e462d5a80f1c608b0df8660fb13bd5aad0f32b6db68b42c0",
             "9e78b43ea00edcac8299e0cc8df7f6f913078171335f733a21d5d911b6999132",
             "350a770c0ec9f353e1a5629895f374fdaa299876c3870c03feb60eb4a3769d94",
             "f6056ef7890a99494c34951817c2ed4fd3608a8488ef0ae6f2afac93ed76854e",
             "323a4206f8d711e87a6ecd279280f40d91bd1a4ead247e21024aa59a93dd02c8",
             "e0e3a2b6471d044a53a7757994b51dd33c6b3ec90e1aca21cebc8e2ae79d6d9b",
             "136c67657614311f32238751044a0a3c0294f2a521e573afa8e496992d3786ba",
             "4ca6f6d5a544bf57c323657ad33aae1a019c775518cf4414beedb86962aea7c1",
             "b8efc8666c65da89950a658fff2ea192be43efbe0dcedf31d41df9aad5ac5d80",
             "67a1609e1e9c8e80856644128a084295f732581f9ee05710d9601a5eee45b04c",
             "b29a46a27acbba77b0aaba113e3d343cbd951a3a848f8356c164c3728b1c8e05",
             "b185c3068c145f728a1aab6f00091fb6735ddf72311b368f592cb7b0a2a5f37c",
             "5dea22a579e9477122312d9f7269eabfa8147527a8d24738683f6b6734487560",
             "7bee97866a16719e2f6eca472a6f171e04da80ae3d550052f2747286d1d2fd76"
           ])

  # sha256(lowercase term), hex, applied ONLY to `@scoped_paths` (see the
  # moduledoc). The client org, then the client contact.
  @scoped_digests MapSet.new([
                    "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d",
                    "17d93b3e93059e01484fabea3489be14fc463ea0998b183a3360489e812fbf2c"
                  ])

  # sha256(repo-relative path), hex: the 40 files the guard's deferred list
  # carried before task 01a14dce stage 4 deleted it.
  @scoped_paths MapSet.new([
                  "035fee6b447464698e77ca398a43c0d24b8e8f6387bfbe4b3eeebe860056fc09",
                  "071f25dabf0d5e800cf8cde84e6698a1c32e6754d65328823bb4a599d33e6d4c",
                  "0e2f17c3d401c2e7659b2a3ced3b1fe2712033e65e407422fc3d20620944302b",
                  "0e2f3945cdaac4ebf68711f9814e5f8817d8a2af6f14708fc462bd903cad9afb",
                  "11f0bf89102e69d5716b20cacd313953a60d662de54c49306c36b08f70947479",
                  "1c70ea9b19bae409906dcfe58b3484c800ed21da108fc5fb30bfea782cfc0c87",
                  "1da3b79329fa4200954aed8e3665cfa72c58caef7999215caf7e101493cc48ca",
                  "1e03d9f1f4096625fb9c1745a948909ab1960b24b6cbddc493ff79d3be55e414",
                  "225ccc9cd7f03de8f77295c691a311a6ba09f6f2b950c9101aff564d1651d952",
                  "26bdc7cc0e92d61e8ffc7e3b65c4018ddb669c478401e4db4291645725283249",
                  "29ca72c327112368139ee7d312b808c3b91d2ac2acefd250aa8ef0f95590e10b",
                  "2bb81096c09b676c0968f4b3550db202ce6510b13807b4e7794b68b2e8e398aa",
                  "2c682a6d7bcde483ae34c6d2635451f2d1f07317aba43866c6258696e18d0b18",
                  "3b5f04ccd523b9e6060e7820ed41b22688537b91dec59df128c0f4fc884e0f9e",
                  "3f06e3327726b016fcccd5d8735a63f2436dd145852d799495c5b2adbcb034ab",
                  "438ca40569e87fdbe89d833a54faad2022783cc2691580badc72dce308438c09",
                  "46d2424c7ddacbf77941c673bb5385527d445e8c0891f58fa678913a5bfee25b",
                  "52b4e1224a459f39447830c1e69a1291b82cfef203e311225ed6b534b306dee3",
                  "6496a52982dd09416569f41bceaab146e5794534b0c7bd48654ac483408c81c9",
                  "6bd356ecc0bf924d75f5275d3d820f3488535d851a972b971dbacdedba1fccdb",
                  "73fa18a85552a446c5acb08c3ba585659dd7351fc62e0abb44d3aabb80ea00b3",
                  "746e9af32f92ca8644e24654364b65ebe9ac16b44fa4ed0f64280f4c934188af",
                  "77c12011d1defc5f833e7987fb26308a8f58b84901ec15fbf3aadd7e35bbfd1c",
                  "7bf7128454a25c06ba9700888a9aa3ffdde356a821dd6e3782dfe2321608f45d",
                  "8378be87a9adf1973cd3a259c7eae1f0717854be27cd7728917a126457f50349",
                  "85a8897423bb77ac75746763fbd34826d46b5b5b660e34949382df9086d38f4b",
                  "888c92712c853a1cdbfef361bea5ed1bc9b8e42af1a3adb8e2c5633acf76b4d1",
                  "8a5554eadb2e87ead601fd1a026323fe4aea15575bc093bbae8b3486ab455a6f",
                  "9614192decf7b4c5549156775881f86050a4ee7ba31f3fd9bc10e10c05cb946c",
                  "976925f55c07ca4d17278c1f8546408e7372a3ce716a5692589d5c90808eb88a",
                  "97ce6cffffec0a887feb714d023517a9d789ffc567db94a7d8606270d76a2293",
                  "ac0850c6624d5adaf43bafed826b03df8a4986d86823a377a8ac9c1a3e84621b",
                  "b4d1f728e8a2f44143ff59b3b114cd0fb563a94dcdb957c68f36337d58445dbf",
                  "cf78d0454038f438c183f8143eb510ff191859ac392115a50c27e1ed9203c9c7",
                  "d25f4f93f820d9899150dee35752e0aa96d7189774b758e19d233825eb7832af",
                  "d50781d59de7f40d46b57f434f86a4ab020841cd574c9cca0cd8787d7afd4695",
                  "e12cccea1f5b779a521e5207ce591c3c0b53be3f9372f4ed9efb0ebc5297939e",
                  "e67e40d220a57364510d1e1403aa7f94aab16fa4c4651571212f537327d4f589",
                  "f70ee4b76f968ed691ad6fd3218bcccca49f736156c185993a5aee9a0870e41a",
                  "fc53a5ae1277bef7ef95265ab004796f0a964ca02222bf1dc06f564b98d8b961"
                ])

  @scoped_union MapSet.union(@digests, @scoped_digests)

  # Shipped app-store identifiers, literal. {id, mode, reason}. Every entry is
  # renamed (or not) by task A2b, 01a14ba9-e428-7000-86ec-d39a97ab863c.
  @published_ids [
    # Android namespace/applicationId and Kotlin package (build.gradle), and
    # the server-side allowed package in Platform.Mobile.FcmDevice. A2b.
    {"com.koboai.burrow", :namespace, "shipped Android package id"},
    # iOS bundle id and its extensions' ids (project.yml). A2b.
    {"com.kobo-ai.burrow", :namespace, "shipped iOS bundle id"},
    # iOS App Group shared by the app and its extensions (*.entitlements). A2b.
    {"group.com.kobo-ai.burrow", :namespace, "shipped iOS App Group id"},
    # Team-prefixed keychain access group (*.entitlements). A2b.
    {"XJ2GLJ9ST2.com.kobo-ai.burrow", :namespace, "shipped iOS keychain group"},
    # project.yml bundleIdPrefix, on its own only. A2b.
    {"com.kobo-ai", :exact, "shipped iOS bundleIdPrefix"}
  ]

  @doc "The shipped identifiers exempted by literal match, as `{id, mode, reason}`."
  def published_ids, do: @published_ids

  @doc """
  The operator org token the shipped iOS bundle id carries (the first
  hyphen-separated label of its org part), derived from `published_ids/0`
  so a test can refute it without spelling it, or plant it as a positive
  control.
  """
  def published_org_token do
    {ios, :namespace, _} =
      Enum.find(@published_ids, fn {id, _, _} -> id =~ ~r/\Acom\.[a-z]+-/ end)

    ios |> String.split(".") |> Enum.at(1) |> String.split("-") |> hd()
  end

  @doc "sha256 hex digest of `term`, lowercase hex."
  def digest(term) when is_binary(term),
    do: :sha256 |> :crypto.hash(term) |> Base.encode16(case: :lower)

  @doc "Is this exact lowercase candidate a denylisted term?"
  def denied?(candidate) when is_binary(candidate),
    do: MapSet.member?(@digests, digest(candidate))

  @doc "The scoped client digests, as a MapSet of lowercase hex."
  def scoped_digests, do: @scoped_digests

  @doc "The scoped path digests, as a MapSet of lowercase hex."
  def scoped_paths, do: @scoped_paths

  @doc "Is `rel` (a repo-relative path) one of the scoped files?"
  def scoped_path?(rel) when is_binary(rel), do: MapSet.member?(@scoped_paths, digest(rel))

  @doc """
  Is `hex` one of the denylist digests? For code that matches a historical
  value by its digest (applied migrations, task 01a14b9e stage 5) and wants
  to prove the digest names a denied term without spelling the term.
  """
  def listed_digest?(hex) when is_binary(hex), do: MapSet.member?(@digests, hex)

  @doc """
  Every non-exempt hit in `text`, as sorted `{byte_offset, byte_length}`
  spans. Public so callers can run it over any string, rendered HTML
  included: a rendered page gets the same check as a source file, class
  names and attributes included, with no page-only exemption (task 01a14b9e
  stage 6 removed the one heroicon class exemption by inlining that glyph).
  """
  def hits(text) when is_binary(text), do: hits(text, :general)

  @doc """
  As `hits/1`, with the denylist chosen by `scope`: `:general` is `@digests`
  alone; `:scoped` is `@digests` plus `@scoped_digests`, the set
  `count_file/2` applies to a scoped path.
  """
  def hits(text, scope) when is_binary(text) and scope in [:general, :scoped] do
    set = digest_set(scope)
    low = String.downcase(text, :ascii)
    norm = :binary.replace(low, "/", ".", [:global])
    exempt = exempt_spans(low, norm)

    (token_hits(text, set) ++
       compound_hits(low, set) ++ compound_hits(norm, set) ++ literal_hits(text))
    |> Enum.uniq()
    |> Enum.reject(&inside_any?(&1, exempt))
    |> Enum.sort()
  end

  defp digest_set(:general), do: @digests
  defp digest_set(:scoped), do: @scoped_union

  @doc "Number of non-exempt hits in `text`."
  def count(text) when is_binary(text), do: length(hits(text))

  @doc "Number of non-exempt hits in `text` under `scope` (see `hits/2`)."
  def count(text, scope) when is_binary(text), do: length(hits(text, scope))

  @doc "A NUL in the first 8 KB means binary: its content is not scanned."
  def text?(bin) when is_binary(bin),
    do: not String.contains?(binary_part(bin, 0, min(byte_size(bin), 8192)), <<0>>)

  @doc """
  Every tracked path under `root` (`git ls-files -z`), sorted. Tracked files
  only, so build output and dependencies are never scanned. Returns
  `{:error, message}` with git's own output when git cannot answer.
  """
  def tracked_files(root) do
    args = ["-c", "safe.directory=*", "-C", root, "ls-files", "-z"]

    case System.cmd("git", args) do
      {out, 0} ->
        {:ok, out |> String.split(<<0>>, trim: true) |> Enum.sort()}

      {_out, code} ->
        {out, _} = System.cmd("git", args, stderr_to_stdout: true)
        {:error, "git ls-files -z in #{root} exited #{code}: #{out}"}
    end
  rescue
    e in ErlangError -> {:error, "git could not run in #{root}: #{Exception.message(e)}"}
  end

  @doc """
  Hits for one tracked file: its PATH (so a file named after a term is a
  hit) plus its content when the content is text. A scoped path
  (`scoped_path?/1`) is scanned with the scoped set as well.
  """
  def count_file(root, rel) do
    scope = if scoped_path?(rel), do: :scoped, else: :general
    count(rel, scope) + content_count(Path.join(root, rel), scope)
  end

  @doc "`%{relative_path => hits}` for every given path with at least one hit."
  def counts(root, rels) do
    for rel <- rels, n = count_file(root, rel), n > 0, into: %{}, do: {rel, n}
  end

  defp content_count(abs, scope) do
    case File.read(abs) do
      {:ok, bin} -> if text?(bin), do: count(bin, scope), else: 0
      # Tracked but deleted in the working tree: only the path is scanned.
      {:error, :enoent} -> 0
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: abs
    end
  end

  defp token_hits(text, set) do
    for [{start, len}] <- Regex.scan(~r/[A-Za-z0-9]+/, text, return: :index),
        {s, l} <- camel_pieces(binary_part(text, start, len), start),
        in_set?(set, String.downcase(binary_part(text, s, l), :ascii)),
        do: {s, l}
  end

  defp in_set?(set, candidate), do: MapSet.member?(set, digest(candidate))

  # Upper-run before Upper+lower (HTTPServer -> HTTP, Server), else an
  # optional capital and its lowercase/digit tail, else an upper-case run.
  defp camel_pieces(run, offset) do
    for [{s, l}] <-
          Regex.scan(~r/[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+[0-9]*/, run, return: :index),
        do: {offset + s, l}
  end

  defp compound_hits(low, set) do
    for [{s, l}] <- Regex.scan(~r/[a-z0-9]+(?:[.\-][a-z0-9]+)+/, low, return: :index),
        run = binary_part(low, s, l),
        {cs, cl} <- [{0, l} | dot_suffixes(run)],
        in_set?(set, binary_part(run, cs, cl)),
        do: {s + cs, cl}
  end

  defp dot_suffixes(run) do
    for {i, 1} <- :binary.matches(run, "."), do: {i + 1, byte_size(run) - i - 1}
  end

  @doc """
  The two literal regexes: a `192.168/16` address and a home-directory path
  under `/var`. The second is assembled so this file does not spell it.
  """
  def literal_patterns do
    [~r/\b192\.168\.\d{1,3}\.\d{1,3}\b/, Regex.compile!(Regex.escape("/var/" <> "home/"))]
  end

  defp literal_hits(text) do
    for re <- literal_patterns(),
        [span] <- Regex.scan(re, text, return: :index),
        do: span
  end

  defp exempt_spans(low, norm) do
    for {id, mode, _reason} <- @published_ids,
        pattern = :binary.replace(String.downcase(id, :ascii), "/", ".", [:global]),
        {s, l} <- :binary.matches(norm, pattern),
        left_bounded?(low, s),
        right_bounded?(low, s + l, mode),
        do: {s, l}
  end

  defp left_bounded?(_low, 0), do: true

  defp left_bounded?(low, s),
    do: not id_byte?(:binary.at(low, s - 1)) and :binary.at(low, s - 1) != ?.

  defp right_bounded?(low, e, _mode) when e >= byte_size(low), do: true

  defp right_bounded?(low, e, mode) do
    next = :binary.at(low, e)

    cond do
      id_byte?(next) -> false
      next in [?., ?/] and mode == :exact -> not followed_by_alnum?(low, e + 1)
      true -> true
    end
  end

  defp followed_by_alnum?(low, i), do: i < byte_size(low) and alnum?(:binary.at(low, i))

  defp id_byte?(c), do: alnum?(c) or c in [?_, ?-]
  defp alnum?(c), do: c in ?a..?z or c in ?0..?9

  defp inside_any?({s, l}, spans),
    do: Enum.any?(spans, fn {es, el} -> s >= es and s + l <= es + el end)
end
