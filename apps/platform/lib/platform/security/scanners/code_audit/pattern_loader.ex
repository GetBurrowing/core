defmodule Platform.Security.Scanners.CodeAudit.PatternLoader do
  @moduledoc """
  Loads + validates the code-audit rubric (task `019f3e8e-4406`
  stage 4, ADR-0043).

  The rubric lives at `priv/security/patterns.yaml` in the platform
  app. Each entry is a map with the following required keys:

    * `id` — string. Stable identifier; participates in the finding
      fingerprint so a rubric ID change looks like a new finding.
    * `severity` — string, one of `"critical" | "high" | "medium" |
      "low"`. Maps to the same priority scale
      `Platform.Security.FindingFiler` already uses.
    * `kind` — string, one of `"regex" | "ast_probe"`. The scanner
      dispatches on this.
    * `match` — string. For `regex`, a Perl-style pattern; for
      `ast_probe`, the name of a probe function on
      `Platform.Security.Scanners.CodeAudit.AstProbes`.
    * `description` — string, optional. Renders into the task body.
    * `suggested_fix` — string, optional. Renders under
      `## Suggested fix` in the task body.

  The loader validates the shape at load time and crashes loudly on
  malformed input — a mis-typed rubric is an operator bug, not a
  finding to swallow.
  """

  @required_keys ["id", "severity", "kind", "match"]
  @valid_kinds ~w(regex ast_probe)
  @valid_severities ~w(critical high medium low)

  @type pattern :: %{
          id: String.t(),
          severity: atom(),
          kind: :regex | :ast_probe,
          match: String.t(),
          description: String.t() | nil,
          suggested_fix: String.t() | nil,
          compiled: term()
        }

  @doc """
  Read the rubric from the app's `priv/security/patterns.yaml` and
  return `{:ok, [pattern]}`. Returns `{:error, reason}` for missing
  files or malformed content — the scanner short-circuits with a
  warn on `{:error, _}`.
  """
  @spec load() :: {:ok, [pattern()]} | {:error, term()}
  def load do
    load(default_path())
  end

  @doc "Load from an explicit filesystem path — used by tests."
  @spec load(String.t()) :: {:ok, [pattern()]} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, doc} <- decode_yaml(raw),
         {:ok, patterns} <- fetch_patterns(doc) do
      compile_patterns(patterns)
    end
  end

  @doc "Default filesystem path for the shipped rubric."
  @spec default_path() :: String.t()
  def default_path do
    :platform
    |> :code.priv_dir()
    |> Path.join("security/patterns.yaml")
  end

  # ── internals ────────────────────────────────────────────────────────

  defp decode_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, doc} -> {:ok, doc}
      {:error, err} -> {:error, {:invalid_yaml, err}}
    end
  end

  defp fetch_patterns(%{"patterns" => list}) when is_list(list), do: {:ok, list}
  defp fetch_patterns(_), do: {:error, :missing_patterns_key}

  defp compile_patterns(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case compile_one(entry) do
        {:ok, pat} -> {:cont, {:ok, [pat | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, patterns} -> {:ok, Enum.reverse(patterns)}
      other -> other
    end
  end

  defp compile_one(entry) when is_map(entry) do
    with :ok <- require_keys(entry, @required_keys),
         {:ok, severity} <- validate_severity(entry["severity"]),
         {:ok, kind} <- validate_kind(entry["kind"]),
         {:ok, compiled} <- compile_match(kind, entry["match"]) do
      {:ok,
       %{
         id: entry["id"],
         severity: severity,
         kind: kind,
         match: entry["match"],
         description: entry["description"],
         suggested_fix: entry["suggested_fix"],
         compiled: compiled
       }}
    end
  end

  defp compile_one(_), do: {:error, {:invalid_pattern_entry, :not_a_map}}

  defp require_keys(entry, keys) do
    missing = Enum.reject(keys, &Map.has_key?(entry, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_pattern_keys, missing, entry["id"]}}
    end
  end

  defp validate_severity(sev) when sev in @valid_severities, do: {:ok, String.to_atom(sev)}

  defp validate_severity(other), do: {:error, {:invalid_severity, other}}

  defp validate_kind(kind) when kind in @valid_kinds, do: {:ok, String.to_atom(kind)}
  defp validate_kind(other), do: {:error, {:invalid_kind, other}}

  defp compile_match(:regex, source) when is_binary(source) do
    case Regex.compile(source) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, {:invalid_regex, source, reason}}
    end
  end

  defp compile_match(:ast_probe, probe) when is_binary(probe) do
    if function_exported?(
         Platform.Security.Scanners.CodeAudit.AstProbes,
         String.to_atom(probe),
         1
       ) do
      {:ok, String.to_atom(probe)}
    else
      # Deferred to runtime — probes module may not be loaded when
      # this runs from a `:code.priv_dir` compile-time hook. Runtime
      # invocation surfaces missing probes as a warn + skip.
      {:ok, String.to_atom(probe)}
    end
  end

  defp compile_match(_kind, other), do: {:error, {:invalid_match, other}}
end
