defmodule Platform.Agents.CredentialShape do
  @moduledoc """
  Does this string LOOK like a credential? A pure, no-IO shape test.

  This exists because a real credential reached a context it should not
  have. The control for that is not "be careful" — it is a predicate a
  redaction site can call before text leaves the box. Nothing here reads
  a database, a file, or the clock; the answer is a function of the
  bytes alone, so a caller can run it on a hot path and a test can drive
  it without a fixture.

  ## What it does NOT do

  It does not decide that a string IS a credential, and it never looks
  one up. There is no oracle — a detector can only recognise SHAPE, and
  every shape here is a shape that issuers chose to make recognisable.
  A caller that redacts on `true` is trading a small amount of legible
  digest for the one failure mode that has no cleanup path.

  ## Three tiers, cheapest and most precise first

    1. **Structured issuer prefixes.** `sk-`, `ghp_`, `glpat-`, `AKIA…`,
       `AIza…`, PEM headers, JWTs, `Bearer …`, a URL carrying userinfo
       with a password. These are near-zero false positive: the issuer
       minted the prefix precisely so that a scanner could find it.

    2. **Assignment shape.** A key whose NAME says secret (`token`,
       `password`, `api_key`, …) bound to a value. The right-hand side
       must ALSO fail `benign_shape?/1`, so `auth_token: <uuid>` — a
       shape our own channels emit hourly — does not trip it.

    3. **Generic high entropy.** A 32+ character run drawn from
       `[A-Za-z0-9+/=_-]` whose Shannon entropy is at least
       #{3.6} bits/char and which is not allowlisted. Deliberately
       narrow. This is the tier that generates false positives, so it
       is the tier that leans hardest on the allowlist.

  ## The allowlist is load-bearing

  `benign_shape?/1` is PUBLIC, not a private helper, because the
  interesting measurement on this module is its false-positive rate and
  that measurement has to be able to drive the allowlist directly.

  Its entries are not a grab bag. Each is a shape that appears in our
  own channels hourly and that tier 3 would otherwise swallow: a UUID
  (36 chars, mixed case classes, high entropy), a 40-character git SHA
  (40 chars, high entropy), `sha256:` digests, memory paths. Remove the
  allowlist call from tier 3 and the digest stops carrying task ids and
  commit shas — which is the failure the "do not redact so broadly the
  digest stops being useful" clause names.
  """

  @entropy_floor 3.6
  @generic_run_min_length 32

  # --- Tier 1: structured issuer prefixes -----------------------------------
  #
  # Anchored on the prefix the ISSUER chose, plus a minimum body length, so a
  # prose mention of the prefix ("rotate the ghp_ token") does not match.

  @tier1_patterns [
    # OpenAI and Anthropic: sk-, sk-ant-, sk-proj- + 20 or more.
    ~r/\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}/,
    # GitHub PATs and OAuth tokens.
    ~r/\b(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    # GitLab PAT.
    ~r/\bglpat-[A-Za-z0-9_-]{16,}/,
    # Slack bot / user / app tokens.
    ~r/\bxox[bpa]-[A-Za-z0-9-]{10,}/,
    # AWS long-lived and session access key ids — fixed 16-char body.
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bASIA[0-9A-Z]{16}\b/,
    # Google API key.
    ~r/\bAIza[0-9A-Za-z_-]{30,}/,
    # PEM private key header, any algorithm.
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    # HTTP Authorization bearer value.
    ~r/\bBearer [A-Za-z0-9._~+\/=-]{20,}/,
    # A URL whose authority carries userinfo WITH a password:
    # scheme://user:password@host. Userinfo with no colon is not a secret.
    ~r/\b[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s:\/@]+:[^\s\/@]+@/
  ]

  # A JWT is three base64url segments. The regex cannot express "40 or more
  # characters overall", so the length test is applied to the match.
  @jwt_pattern ~r/\beyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+/
  @jwt_min_length 40

  # --- Tier 2: assignment shape ---------------------------------------------

  @assignment_pattern ~r/
    \b[A-Za-z0-9_.-]*
    (?:secret|token|password|passwd|pwd|api[_-]?key|apikey|credential|auth)
    [A-Za-z0-9_.-]*
    \s*[:=]\s*
    ["']?(?<value>[A-Za-z0-9+\/=_.-]{8,})["']?
  /ix

  # --- Tier 3: generic high-entropy run -------------------------------------

  # The optional `scheme:` head is what makes the `sha256:`-prefixed-hex and
  # bare-URL allowlist entries reachable at all. Scanning bare runs splits
  # `sha256:<64 hex>` at the colon and hands the allowlist a naked 64-char hex
  # run, which is not a git sha length and not single-class — so the digest ref
  # was flagged. Keeping the head attached lets `benign_shape?/1` see the whole
  # candidate it was specified against.
  @generic_run_pattern ~r/(?:[A-Za-z][A-Za-z0-9+.-]*:)?[A-Za-z0-9+\/=_-]+/

  # --- Allowlist shapes ------------------------------------------------------

  @uuid_pattern ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @git_sha_lengths [7, 8, 10, 40]
  @hex_pattern ~r/\A[0-9a-fA-F]+\z/
  @sha256_ref_pattern ~r/\Asha256:[0-9a-fA-F]{64}\z/i
  @path_pattern ~r/\A[A-Za-z0-9._~\/-]*\/[A-Za-z0-9._~\/-]*\z/
  @url_pattern ~r/\A[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s@]+\z/

  @doc """
  Does `text` contain anything shaped like a credential?

  `nil` is `false` — an absent value cannot leak. Runs the three tiers in
  order and short-circuits, so the common case (ordinary prose) pays only
  for the tier-1 prefix scan.

      iex> Platform.Agents.CredentialShape.credential_shaped?(nil)
      false

      iex> Platform.Agents.CredentialShape.credential_shaped?(
      ...>   "deployed 06417daea157d7c31e78fec65f1e88a402f03bf1"
      ...> )
      false
  """
  @spec credential_shaped?(binary() | nil) :: boolean()
  def credential_shaped?(nil), do: false

  def credential_shaped?(text) when is_binary(text) do
    tier1?(text) or tier2?(text) or tier3?(text)
  end

  @doc """
  Which tier fires first for `text`, or `nil` when it is not
  credential-shaped.

  Public so the false-positive measurement can report a flag's SHAPE CLASS
  without reporting anything about the matched span. **It returns the tier
  and only the tier** — never the match, never its offset, never its
  length. A length plus a tier narrows a secret; the match simply is one.
  Callers that want a boolean should use `credential_shaped?/1`.

  Tiers are reported in detection order — cheapest and most precise first —
  so the returned tier is the one that would have caused the withholding.

      iex> Platform.Agents.CredentialShape.firing_tier("nothing to see here")
      nil
  """
  @spec firing_tier(binary() | nil) ::
          :tier1_issuer_prefix | :tier2_assignment_shape | :tier3_generic_entropy | nil
  def firing_tier(nil), do: nil

  def firing_tier(text) when is_binary(text) do
    cond do
      tier1?(text) -> :tier1_issuer_prefix
      tier2?(text) -> :tier2_assignment_shape
      tier3?(text) -> :tier3_generic_entropy
      true -> nil
    end
  end

  @doc """
  Is `candidate` a shape we refuse to treat as a credential?

  Public on purpose: the allowlist is the half of this module that
  decides whether a redacted digest is still worth reading, so its
  false-positive rate has to be measurable without going through
  `credential_shaped?/1`.

  Expects a single candidate token or run, not a prose blob — it anchors
  every pattern at both ends.

      iex> Platform.Agents.CredentialShape.benign_shape?(
      ...>   "org/page/silent-caps-and-index-maintenance.md"
      ...> )
      true
  """
  @spec benign_shape?(binary() | nil) :: boolean()
  def benign_shape?(nil), do: false

  def benign_shape?(candidate) when is_binary(candidate) do
    uuid?(candidate) or git_sha?(candidate) or digest_ref?(candidate) or
      path_like?(candidate) or url_without_userinfo?(candidate) or
      single_character_class?(candidate) or separator_joined_identifier?(candidate)
  end

  @doc """
  Shannon entropy of `text` in bits per character, over its own symbol
  distribution. `0.0` for the empty string, and for any string of one
  repeated character.

  Inline rather than pulled from a library: it is ten lines, and a
  dependency here would be a dependency on every redaction hot path.

      iex> Platform.Agents.CredentialShape.shannon_entropy("aaaaaaaa")
      0.0
  """
  @spec shannon_entropy(binary()) :: float()
  def shannon_entropy(""), do: 0.0

  def shannon_entropy(text) when is_binary(text) do
    chars = String.graphemes(text)
    total = length(chars)

    chars
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_char, count}, acc ->
      p = count / total
      acc - p * :math.log2(p)
    end)
  end

  # --- Tier implementations --------------------------------------------------

  defp tier1?(text) do
    Enum.any?(@tier1_patterns, &Regex.match?(&1, text)) or jwt?(text)
  end

  defp jwt?(text) do
    case Regex.run(@jwt_pattern, text) do
      [match | _] -> byte_size(match) >= @jwt_min_length
      nil -> false
    end
  end

  defp tier2?(text) do
    @assignment_pattern
    |> Regex.scan(text, capture: :all_names)
    |> Enum.any?(fn [value] -> not benign_shape?(String.trim(value, ".")) end)
  end

  defp tier3?(text) do
    @generic_run_pattern
    |> Regex.scan(text)
    |> Enum.any?(fn [run] -> high_entropy_secret_run?(run) end)
  end

  defp high_entropy_secret_run?(run) do
    String.length(run) >= @generic_run_min_length and
      not benign_shape?(run) and
      shannon_entropy(run) >= @entropy_floor
  end

  # --- Allowlist implementations ---------------------------------------------

  defp uuid?(candidate), do: Regex.match?(@uuid_pattern, candidate)

  defp git_sha?(candidate) do
    String.length(candidate) in @git_sha_lengths and Regex.match?(@hex_pattern, candidate)
  end

  defp digest_ref?(candidate), do: Regex.match?(@sha256_ref_pattern, candidate)

  # Memory paths (`org/page/…`, `project/<uuid>/page/…`,
  # `space/<uuid>/journal/…`) and filesystem paths are all just "has a slash,
  # made only of path-safe characters, carries no userinfo".
  defp path_like?(candidate), do: Regex.match?(@path_pattern, candidate)

  defp url_without_userinfo?(candidate) do
    Regex.match?(@url_pattern, candidate)
  end

  # ── The widening that made this shippable (task 01a09c9b stage 3) ─────────
  #
  # MEASURED, not guessed. Tier 3 flagged 12.5331% of 160,176 production
  # `chat_messages` bodies over the 30 days to 2026-09-16 — 19,869 of 20,075
  # flags, 98.97% of them. A redactor at that rate gets switched off, and a
  # switched-off redactor is worse than none because the ticket reads closed.
  #
  # Every dominant false-positive family had ONE cause, and it was not the
  # entropy floor. `@generic_run_pattern` admits `-`, `_` and `=`, so it
  # GLUES an identifier's separators into a single run — and every allowlist
  # predicate above is anchored at both ends, so it then fails to recognise
  # the parts. The three biggest masked shape classes, by count:
  #
  #   14,824  `9{4}-a{5}-a{7}-a{8}-…`   numeric-prefixed kebab slug — an ADR
  #                                     or memory-page filename.
  #    ~4,900  `a{5}_a{2}={…uuid…}`      `space_id=<uuid>` and friends: a
  #                                     query parameter whose `=` glues the
  #                                     key onto a UUID the allowlist would
  #                                     have recognised standing alone.
  #      760  `A{8}_A{4}_A{8}=a{9}_…`   `SCREAMING_SNAKE=value` assignment.
  #
  # So: split the run on its separators and ask whether EVERY segment is
  # itself unremarkable. A secret is an unbroken high-entropy blob; break it
  # on separators and you still hold a long mixed-class segment. An
  # identifier breaks into words, UUID groups and short hex.
  #
  # A SEGMENT is unremarkable when it is drawn from at most one character
  # class, or is a hex group of UUID/short-sha size. NOT "is short" — the
  # first cut of this used a 16-character segment ceiling and it opened a
  # real hole, caught by an existing tier-2 test: a 24-character url-safe
  # secret that happens to contain one `-` splits into two sub-16 segments
  # and would have been allowlisted. **A length ceiling measures the wrong
  # thing.** The property that separates an identifier from a secret is not
  # segment length, it is that an identifier's segments are each drawn from
  # one alphabet — words are lowercase, env vars are uppercase, UUID groups
  # and short shas are hex — while a random secret's segments are mixed by
  # construction, which is the whole point of the alphabet it is drawn from.
  #
  # KNOWN RESIDUAL, deliberate and inherited from stage 1's documented
  # trade: a secret drawn from a single alphabet (lowercase-only,
  # digits-only) is not caught by tier 3, and separator-splitting does not
  # change that. Tier 1 catches the issued formats shaped that way.
  @separator_split_min_segments 2
  @uuid_group_max_length 12

  defp separator_joined_identifier?(candidate) do
    segments = String.split(candidate, ["-", "_", "=", "+", "/"], trim: true)

    length(segments) >= @separator_split_min_segments and
      Enum.all?(segments, &unremarkable_segment?/1)
  end

  defp unremarkable_segment?(segment) do
    single_character_class?(segment) or hex_group?(segment) or
      uuid?(segment) or git_sha?(segment)
  end

  defp hex_group?(segment) do
    String.length(segment) <= @uuid_group_max_length and Regex.match?(@hex_pattern, segment)
  end

  # A run drawn from at most ONE of {lowercase, uppercase, digits} — ignoring
  # separators, which every shape here uses — is prose, an identifier, or a
  # number. No issuer mints a secret out of a single alphabet, and reading the
  # class count is cheaper and more stable than a second entropy threshold.
  defp single_character_class?(candidate) do
    classes =
      candidate
      |> String.graphemes()
      |> Enum.reduce(MapSet.new(), fn char, acc ->
        cond do
          char >= "a" and char <= "z" -> MapSet.put(acc, :lower)
          char >= "A" and char <= "Z" -> MapSet.put(acc, :upper)
          char >= "0" and char <= "9" -> MapSet.put(acc, :digit)
          true -> acc
        end
      end)

    MapSet.size(classes) <= 1
  end
end
