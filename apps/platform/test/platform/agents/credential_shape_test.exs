defmodule Platform.Agents.CredentialShapeTest do
  @moduledoc """
  Every positive fixture in this file is SYNTHETIC — generated at test time
  from `:crypto.strong_rand_bytes/1`. No real credential appears here, and
  none may ever be added: a credential that reaches a source file is
  compromised, and rotation is the only control.

  The interesting assertions are the NEGATIVE ones. A predicate that
  returns `true` unconditionally passes every positive case in this file,
  so the positives on their own prove nothing about the detector. The
  named negatives below — a UUIDv7 task id, 7- and 40-character git SHAs,
  a memory path, prose, a fenced snippet, a bare URL — are what separate
  a working detector from `fn _ -> true end`.
  """

  use ExUnit.Case, async: true

  alias Platform.Agents.CredentialShape

  doctest Platform.Agents.CredentialShape

  # --- synthetic fixture generators ------------------------------------------

  defp random_urlsafe(n) do
    (n * 2)
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> binary_part(0, n)
  end

  defp random_lower_hex(n) do
    (n * 2)
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, n)
  end

  defp random_upper_base32(n) do
    (n * 2)
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
    |> binary_part(0, n)
  end

  describe "tier 1 — structured issuer prefixes" do
    test "an sk- prefixed key with a 20+ character body is credential-shaped" do
      assert CredentialShape.credential_shaped?("sk-" <> random_urlsafe(32))
    end

    test "an sk-ant- prefixed key is credential-shaped" do
      assert CredentialShape.credential_shaped?("sk-ant-" <> random_urlsafe(40))
    end

    test "an sk-proj- prefixed key is credential-shaped" do
      assert CredentialShape.credential_shaped?("sk-proj-" <> random_urlsafe(40))
    end

    test "ghp_, gho_, ghs_ and ghu_ GitHub tokens are credential-shaped" do
      for prefix <- ~w(ghp_ gho_ ghs_ ghu_) do
        assert CredentialShape.credential_shaped?(prefix <> random_lower_hex(36)),
               "expected #{prefix} prefix to be detected"
      end
    end

    test "a github_pat_ fine-grained token is credential-shaped" do
      assert CredentialShape.credential_shaped?("github_pat_" <> random_lower_hex(48))
    end

    test "a glpat- GitLab token is credential-shaped" do
      assert CredentialShape.credential_shaped?("glpat-" <> random_urlsafe(20))
    end

    test "xoxb-, xoxp- and xoxa- Slack tokens are credential-shaped" do
      for prefix <- ~w(xoxb- xoxp- xoxa-) do
        assert CredentialShape.credential_shaped?(prefix <> random_lower_hex(24)),
               "expected #{prefix} prefix to be detected"
      end
    end

    test "an AKIA access key id is credential-shaped" do
      assert CredentialShape.credential_shaped?("AKIA" <> random_upper_base32(16))
    end

    test "an ASIA session access key id is credential-shaped" do
      assert CredentialShape.credential_shaped?("ASIA" <> random_upper_base32(16))
    end

    test "an AIza Google API key is credential-shaped" do
      assert CredentialShape.credential_shaped?("AIza" <> random_urlsafe(35))
    end

    test "a PEM private key header is credential-shaped" do
      for algo <- ["", "RSA ", "EC ", "OPENSSH "] do
        assert CredentialShape.credential_shaped?(
                 "-----BEGIN #{algo}PRIVATE KEY-----\n" <> random_urlsafe(64)
               ),
               "expected #{inspect(algo)} PEM header to be detected"
      end
    end

    test "a three-segment JWT of 40+ characters is credential-shaped" do
      header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
      payload = Base.url_encode64(~s({"sub":"#{random_lower_hex(16)}"}), padding: false)
      jwt = header <> "." <> payload <> "." <> random_urlsafe(43)

      assert byte_size(jwt) >= 40
      assert CredentialShape.credential_shaped?(jwt)
    end

    test "a Bearer authorization value is credential-shaped" do
      assert CredentialShape.credential_shaped?("Authorization: Bearer " <> random_urlsafe(40))
    end

    test "a URL with userinfo carrying a password is credential-shaped" do
      url = "postgres://appuser:" <> random_urlsafe(24) <> "@db.internal:5432/platform"

      assert CredentialShape.credential_shaped?(url)
    end

    test "tier 1 fires inside surrounding prose, not only on a bare token" do
      text = "here is the key you asked for: sk-" <> random_urlsafe(32) <> " — rotate it after."

      assert CredentialShape.credential_shaped?(text)
    end
  end

  describe "tier 2 — assignment shape" do
    test "a secret-named key bound to a non-benign value is credential-shaped" do
      for name <- ~w(api_key apikey token secret password passwd credential auth_token) do
        assert CredentialShape.credential_shaped?("#{name}=#{random_urlsafe(24)}"),
               "expected #{name} assignment to be detected"
      end
    end

    test "a secret-named key bound to an ALLOWLISTED value is not credential-shaped" do
      # This is the clause that keeps `auth_token: <uuid>` — a shape our own
      # channels emit hourly — out of the redactor.
      assert refute_shaped("auth_token: 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def")
      assert refute_shaped("secret_ref: 06417daea157d7c31e78fec65f1e88a402f03bf1")
    end

    test "a key whose name does not say secret is not credential-shaped" do
      assert refute_shaped("task_id: 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def")
      assert refute_shaped("stage_id = 01a0aa73-237b-7001-9106-d08aced55671")
    end
  end

  describe "tier 3 — generic high entropy" do
    test "a 32+ character mixed-class high-entropy run is credential-shaped" do
      assert CredentialShape.credential_shaped?("value is " <> random_urlsafe(44))
    end

    test "a high-entropy run SHORTER than 32 characters is not credential-shaped" do
      assert refute_shaped("value is " <> random_urlsafe(24))
    end
  end

  describe "NEGATIVES — the shapes the digest must keep" do
    test "a real-shaped UUIDv7 task id is not credential-shaped" do
      assert refute_shaped("01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def")
      assert refute_shaped("task 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def advanced to stage 1")
    end

    test "a 7-char git SHA is not credential-shaped" do
      assert refute_shaped("06417da")
      assert refute_shaped("main is at 06417da")
    end

    test "a 40-char git SHA is not credential-shaped" do
      assert refute_shaped("06417daea157d7c31e78fec65f1e88a402f03bf1")
      assert refute_shaped("merged 06417daea157d7c31e78fec65f1e88a402f03bf1 into main")
    end

    test "8- and 10-char git SHAs and sha256: digests are not credential-shaped" do
      assert refute_shaped("06417dae")
      assert refute_shaped("06417daea1")
      assert refute_shaped("sha256:" <> random_lower_hex(64))
    end

    test "the memory path org/page/silent-caps-and-index-maintenance.md is not credential-shaped" do
      assert refute_shaped("org/page/silent-caps-and-index-maintenance.md")
    end

    test "project and space memory paths carrying a uuid are not credential-shaped" do
      assert refute_shaped(
               "project/019d1357-cb08-7023-b165-fd19e9462316/page/process-patterns.md"
             )

      assert refute_shaped("space/01a0aa6d-8ea4-7001-a442-97d8c187d03b/journal/2026-09-16.md")
    end

    test "a long prose sentence is not credential-shaped" do
      assert refute_shaped(
               "The allowlist is load-bearing because a detector that redacts " <>
                 "every high-entropy run also redacts the task ids and commit " <>
                 "shas that make the activity digest worth reading at all, and " <>
                 "a digest nobody reads is not a security control."
             )
    end

    test "a fenced Elixir snippet is not credential-shaped" do
      assert refute_shaped("""
             ```elixir
             defmodule Platform.Agents.CredentialShape do
               @spec credential_shaped?(binary() | nil) :: boolean()
               def credential_shaped?(nil), do: false

               def credential_shaped?(text) when is_binary(text) do
                 tier1?(text) or tier2?(text) or tier3?(text)
               end
             end
             ```
             """)
    end

    test "a bare https URL is not credential-shaped" do
      assert refute_shaped("https://github.com/Startup-Suite/core/pull/1030")
      assert refute_shaped("see https://suite.example.net/tasks for the board")
    end

    test "nil is not credential-shaped" do
      refute CredentialShape.credential_shaped?(nil)
    end

    test "the empty string is not credential-shaped" do
      assert refute_shaped("")
    end
  end

  # ── The measured false positives (stage 3) ───────────────────────────────
  #
  # Each case here is a named family from the 2026-09-16 measurement over
  # 30 days of production `chat_messages` — 12.5331% of 160,176 bodies
  # flagged, 98.97% of the flags tier 3. Every one has the same cause: the
  # generic run pattern admits `-`, `_` and `=`, so it glues an identifier's
  # separators into one run and the anchored allowlist no longer recognises
  # the parts.
  describe "tier 3 false positives measured on production traffic" do
    test "a query parameter carrying a UUID is not credential-shaped" do
      # ~4,900 flags. The UUID alone was ALREADY allowlisted; the `=` is
      # what defeated it, which is why widening had to be about separators
      # and not about the entropy floor.
      assert refute_shaped("space_id=01a0aa6d-8ea4-7001-a442-97d8c187d03b")
      assert refute_shaped("task_id=01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def")
      assert CredentialShape.benign_shape?("space_id=01a0aa6d-8ea4-7001-a442-97d8c187d03b")
    end

    test "a numeric-prefixed kebab slug — an ADR or memory-page filename — is not credential-shaped" do
      # 14,824 flags, the single largest family.
      assert refute_shaped("0043-security-guard-responsibility")
      assert refute_shaped("0033-org-level-context-management")
      assert refute_shaped("a-green-result-is-evidence-only-in-proportion-to-a-demonstrated-red")
    end

    test "a SCREAMING_SNAKE assignment to an identifier value is not credential-shaped" do
      # 760 flags.
      assert refute_shaped("PLATFORM_TEST_DATABASE=platform_test_shard")
    end

    test "the widening does NOT admit an unbroken high-entropy blob" do
      # The control that keeps the widening from being a hole: a real
      # secret has no separators to break on, so it has exactly one
      # segment and `separator_joined_identifier?/1` cannot reach it.
      assert CredentialShape.credential_shaped?("value is " <> random_urlsafe(44))
      refute CredentialShape.benign_shape?(random_urlsafe(44))
    end

    test "a short secret carrying a separator is still credential-shaped" do
      # The hole the FIRST cut of this widening opened, and the reason the
      # segment rule is about character CLASS and not about length: a
      # 24-character url-safe secret containing one `-` splits into two
      # sub-16 segments, and a length ceiling would have allowlisted it. An
      # existing tier-2 case caught this; it is pinned here by name so the
      # ceiling cannot come back.
      secret = random_urlsafe(11) <> "-" <> random_urlsafe(12)

      refute CredentialShape.benign_shape?(secret)
      assert CredentialShape.credential_shaped?("token=" <> secret)
    end

    test "a separated run with ONE long mixed-class segment is still credential-shaped" do
      # A secret that happens to carry a separator is still caught, because
      # allowlisting requires EVERY segment to be unremarkable — not one.
      candidate = "prefix-" <> random_urlsafe(40)

      refute CredentialShape.benign_shape?(candidate)
      assert CredentialShape.credential_shaped?("value is " <> candidate)
    end
  end

  describe "benign_shape?/1 — the allowlist, driven directly" do
    test "recognises canonical UUIDs in either case" do
      assert CredentialShape.benign_shape?("01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def")
      assert CredentialShape.benign_shape?("01A09C9B-5D2D-7001-B7BD-0EA5B3FB1DEF")
    end

    test "recognises bare hex of exactly 7, 8, 10 and 40 characters" do
      for len <- [7, 8, 10, 40] do
        assert CredentialShape.benign_shape?(random_lower_hex(len)),
               "expected a #{len}-char hex run to be allowlisted"
      end
    end

    test "does NOT allowlist a hex run of a length git never emits" do
      # 33 is mixed-class, high entropy, and not a git sha length — it must
      # fall through the allowlist or the allowlist is just "any hex".
      refute CredentialShape.benign_shape?(random_lower_hex(33))
    end

    test "recognises sha256: prefixed digests" do
      assert CredentialShape.benign_shape?("sha256:" <> random_lower_hex(64))
    end

    test "recognises memory and filesystem paths" do
      assert CredentialShape.benign_shape?("org/page/evidence-and-measurement-discipline.md")

      assert CredentialShape.benign_shape?(
               "apps/platform/lib/platform/agents/credential_shape.ex"
             )

      assert CredentialShape.benign_shape?("/Volumes/Dev/sources/core")
    end

    test "recognises a bare URL with no userinfo but NOT one carrying a password" do
      assert CredentialShape.benign_shape?("https://suite.example.net/tasks")
      refute CredentialShape.benign_shape?("postgres://user:" <> random_urlsafe(20) <> "@db/x")
    end

    test "recognises a run drawn from a single character class" do
      assert CredentialShape.benign_shape?("thisisaverylongbutentirelylowercaserun")
      assert CredentialShape.benign_shape?("THISISAVERYLONGBUTENTIRELYUPPERCASERUN")
      assert CredentialShape.benign_shape?("12345678901234567890123456789012345678")
    end

    test "does not allowlist a mixed-class random token" do
      refute CredentialShape.benign_shape?(random_urlsafe(40))
    end

    test "nil is not benign — an absent candidate is not an allowlisted one" do
      refute CredentialShape.benign_shape?(nil)
    end
  end

  describe "shannon_entropy/1" do
    test "is 0.0 for the empty string and for a single repeated character" do
      assert CredentialShape.shannon_entropy("") == 0.0
      assert CredentialShape.shannon_entropy("aaaaaaaaaaaaaaaa") == 0.0
    end

    test "is 1.0 for a balanced two-symbol string" do
      assert_in_delta CredentialShape.shannon_entropy("abababab"), 1.0, 0.0001
    end

    test "clears the 3.6 bit floor for a random url-safe token" do
      assert CredentialShape.shannon_entropy(random_urlsafe(44)) >= 3.6
    end

    test "falls below the 3.6 bit floor for repetitive prose" do
      assert CredentialShape.shannon_entropy("aaaabbbbccccddddaaaabbbbccccdddd") < 3.6
    end
  end

  # Returns true when the text is NOT credential-shaped, so a failure message
  # prints the offending text rather than a bare `false`.
  defp refute_shaped(text) do
    refute CredentialShape.credential_shaped?(text),
           "expected #{inspect(text)} NOT to be credential-shaped"

    true
  end
end
