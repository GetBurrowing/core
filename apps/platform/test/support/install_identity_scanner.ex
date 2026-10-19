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

  ## Tenant and client terms

  Since task A3c (01a14dd9-7172-7000-874c-b9ae3d4c1c83) the list also
  carries, tree-wide, the eight terms that named the shipped tenant orgs and
  the client: four tenant slugs (the second one by the part after its `_`,
  which as a token catches the underscore, hyphen, space and camelCase
  spellings), a fifth org, the client's product, the client's contact, and
  the client's hyphenated full name (a compound). Task A3b
  (01a14dce-d2d8-7000-becf-79544fe7cf98) had applied two of them to a scoped
  set of 40 paths only; A3c removed the last preimage from the tree, moved
  both digests here and deleted the scoped set.

  **One limit, by construction.** A token digest denies one token and a
  compound digest denies one dotted or hyphenated run. A multi-word name
  whose words are ordinary English words is therefore NOT denied when its
  words are joined some other way: separated by spaces or `_`, written with
  no separator, or camelCased. Hashing those words one by one would flag
  ordinary prose. The client's full name is such a name. This guard catches
  only its hyphenated spelling (any letter case), and only where that run
  stands alone or ends a dotted run: the compound rule hashes a run and its
  dot-SUFFIXES, never a prefix, so `x.<name>` and `<name>/x` are hits while
  `<name>.md` and `www.<name>.com` are not (measured, task A3c stage 5).
  The other spellings are covered by the out-of-tree sweep tasks A3c
  stages 3 and 4 ran, not by this guard. Slug 2 is caught by its second
  part with `_`, `-`, a space or a case boundary before it, but not joined
  with no separator and no case boundary (lower, Capitalised or UPPER):
  that join is an English word.

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
             "7bee97866a16719e2f6eca472a6f171e04da80ae3d550052f2747286d1d2fd76",
             # Tenant and client terms (task A3c 01a14dd9). Tenant slug 1,
             # the part of slug 2 after its `_`, the client org (slug 3),
             # slug 4, the fifth org, the client's product, the client's
             # hyphenated full name, the client's contact.
             "1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b",
             "a4914116477206d6766723e306a2fe39e4b97c3cabfce141310622adbb33d34e",
             "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d",
             "d0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c",
             "71ce8a1658507fc4e432cb3621322632972d9256e652b1dee92af6528719216f",
             "4de7d59fd6866c46855c913fe9c7e498228200fdfcbb326f80062bdde43f4b51",
             "fb3a3f5343ca1ff87236fb75ad0f48987d0fd0f4d15b787fb59057e37186f2a0",
             "17d93b3e93059e01484fabea3489be14fc463ea0998b183a3360489e812fbf2c"
           ])

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

  @doc "Every denylist digest, as a MapSet of lowercase hex."
  def digests, do: @digests

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
  def hits(text) when is_binary(text) do
    low = String.downcase(text, :ascii)
    norm = :binary.replace(low, "/", ".", [:global])
    exempt = exempt_spans(low, norm)

    (token_hits(text) ++ compound_hits(low) ++ compound_hits(norm) ++ literal_hits(text))
    |> Enum.uniq()
    |> Enum.reject(&inside_any?(&1, exempt))
    |> Enum.sort()
  end

  @doc "Number of non-exempt hits in `text`."
  def count(text) when is_binary(text), do: length(hits(text))

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
  hit) plus its content when the content is text.
  """
  def count_file(root, rel), do: count(rel) + content_count(Path.join(root, rel))

  @doc "`%{relative_path => hits}` for every given path with at least one hit."
  def counts(root, rels) do
    for rel <- rels, n = count_file(root, rel), n > 0, into: %{}, do: {rel, n}
  end

  defp content_count(abs) do
    case File.read(abs) do
      {:ok, bin} -> if text?(bin), do: count(bin), else: 0
      # Tracked but deleted in the working tree: only the path is scanned.
      {:error, :enoent} -> 0
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: abs
    end
  end

  defp token_hits(text) do
    for [{start, len}] <- Regex.scan(~r/[A-Za-z0-9]+/, text, return: :index),
        {s, l} <- camel_pieces(binary_part(text, start, len), start),
        denied?(String.downcase(binary_part(text, s, l), :ascii)),
        do: {s, l}
  end

  # Upper-run before Upper+lower (HTTPServer -> HTTP, Server), else an
  # optional capital and its lowercase/digit tail, else an upper-case run.
  defp camel_pieces(run, offset) do
    for [{s, l}] <-
          Regex.scan(~r/[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+[0-9]*/, run, return: :index),
        do: {offset + s, l}
  end

  defp compound_hits(low) do
    for [{s, l}] <- Regex.scan(~r/[a-z0-9]+(?:[.\-][a-z0-9]+)+/, low, return: :index),
        run = binary_part(low, s, l),
        {cs, cl} <- [{0, l} | dot_suffixes(run)],
        denied?(binary_part(run, cs, cl)),
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
