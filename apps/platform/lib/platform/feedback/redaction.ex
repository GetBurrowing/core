defmodule Platform.Feedback.Redaction do
  @moduledoc """
  Secret and credential scrubbing for `feedback.submit` text (task 01a11ec3
  stage 2).

  Every allowlisted field passes through `redact/1` BEFORE it is
  fingerprinted, measured against the aggregate cap, or handed to the
  publisher, so nothing this module recognises can reach a GitHub issue.

  ## What it recognises

  Token shapes with a distinctive prefix (GitHub, Slack, AWS access keys,
  Google API keys, OpenAI/Anthropic-style `sk-` keys, Stripe-style live keys),
  PEM private-key blocks, JWTs, `Authorization: Bearer|Basic` values,
  `key=value` / `key: value` assignments whose key names a secret
  (`password`, `secret`, `token`, `api_key`, `access_key`, `private_key`,
  `client_secret`, `credential`), credentials embedded in a URL's userinfo,
  and email addresses. Each match becomes `[REDACTED]`.

  ## What it does not claim

  This is pattern matching. A secret with no recognisable shape and no
  secret-naming key beside it is not detected — which is why the submission
  boundary also refuses to gather anything the caller did not type into an
  allowlisted field (no logs, no session data, no environment), and why
  diagnostics are absent unless explicitly opted in and scoped.
  """

  @marker "[REDACTED]"

  # Order matters: whole blocks first, so a PEM body is removed as one unit
  # before the token patterns look inside it. A value an earlier pattern
  # already replaced is not counted twice (`(?!\[REDACTED\])`).
  #
  # `{:whole, regex}` replaces the entire match; `{:keep_prefix, regex}`
  # keeps capture group 1 (the key name and separator, or the URL scheme) so
  # the scrubbed text still reads as what it was.
  @patterns [
    {:whole,
     ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s},
    {:whole, ~r/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/},
    {:whole, ~r/\bxox[abposr]-[A-Za-z0-9-]{10,}/},
    {:whole, ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/},
    {:whole, ~r/\bAIza[0-9A-Za-z_-]{35}\b/},
    {:whole, ~r/\bsk-[A-Za-z0-9_-]{16,}/},
    {:whole, ~r/\b(?:sk|rk|pk)_live_[A-Za-z0-9]{16,}/},
    {:whole, ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/},
    {:keep_prefix,
     ~r/(?i)\b(authorization\s*[:=]\s*)(?:bearer|basic|token)\s+(?!\[REDACTED\])[^\s"',;]+/},
    {:keep_prefix, ~r/(?i)\b(bearer\s+)[A-Za-z0-9._~+\/-]{16,}=*/},
    {:keep_prefix,
     ~r/(?i)\b((?:[a-z0-9]+[_-])*(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|credentials?)\s*["']?\s*[:=]\s*)(?!\[REDACTED\])(?:"[^"]*"|'[^']*'|[^\s"',;]+)/},
    {:keep_prefix, ~r/(?i)\b([a-z][a-z0-9+.-]*:\/\/)[^\s\/@:]+:[^\s\/@]+@/},
    {:whole, ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/}
  ]

  @doc "The replacement written over every match."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Scrub `text`. Returns `{scrubbed, count}` where `count` is the number of
  replacements made. `nil` is returned as `{nil, 0}`.
  """
  @spec redact(String.t() | nil) :: {String.t() | nil, non_neg_integer()}
  def redact(nil), do: {nil, 0}

  def redact(text) when is_binary(text) do
    Enum.reduce(@patterns, {text, 0}, fn {mode, pattern}, {acc, count} ->
      case length(Regex.scan(pattern, acc)) do
        0 -> {acc, count}
        hits -> {replace(mode, pattern, acc), count + hits}
      end
    end)
  end

  defp replace(:whole, pattern, text), do: Regex.replace(pattern, text, @marker)

  defp replace(:keep_prefix, pattern, text),
    do: Regex.replace(pattern, text, fn _whole, prefix -> prefix <> @marker end)
end
