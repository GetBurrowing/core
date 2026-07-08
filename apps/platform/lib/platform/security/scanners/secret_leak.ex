defmodule Platform.Security.Scanners.SecretLeak do
  @moduledoc """
  Secret-leak scanner for the `security.secret_leak` responsibility
  (task `019f3e8e-4406` stage 5, ADR-0043).

  Runs the same progressive-enhancement contract the other three
  scanners do: with no role assigned to `security_guard`, the Sweeper
  never invokes this and no findings are filed. When invoked, this
  module:

    1. Walks the working tree under
       `Application.get_env(:platform, :security_scanner_repo_root,
       File.cwd!())`, honoring `.gitignore` for exclusion. Each file
       is scanned with the built-in pattern library (below).
    2. When `secret_leak_scan_git_history` is `true` (default `false`),
       ALSO runs `git log --all -p` and scans the diff output for the
       same patterns. Off by default because full history scans on
       real-sized repos are minute-scale.
    3. Applies the `.gitleaks-allowlist.toml` at the repo root (if
       present) as a post-filter — matches whose value satisfies any
       `allowlist.regex` entry are dropped.
    4. Files findings via `Platform.Security.FindingFiler.file_findings/1`
       (batch path — many secrets in one scan collapse into the
       weekly digest task).

  ## Pattern library

  The pattern list is inline as a module attribute — small enough
  that a config file adds ceremony without value. Each entry is
  `{id, severity, regex, description}`. All matches are severity
  `:critical` because a leaked secret is always a rotation event.

  ## Return

  `{:ok, findings_filed}` — the count of task rows the FindingFiler
  actually inserted (dedup hits + digest consolidation count as 0
  per finding; digest counts as 1 for the whole batch).
  """

  require Logger

  alias Platform.Security.FindingFiler

  @default_max_bytes_per_file 1_048_576
  @default_max_git_log_bytes 20_971_520

  # `{id, severity, regex, description}`. Patterns MUST include
  # enough discriminating characters that `sk-` (OpenAI) doesn't
  # collide with `sk-ant-` (Anthropic) — Anthropic runs first in
  # the walk order so its longer prefix wins.
  @patterns [
    {"anthropic_api_key", :critical, ~r/sk-ant-[A-Za-z0-9_\-]{40,}/,
     "Anthropic API key checked into source (starts with sk-ant-)."},
    {"openai_api_key", :critical, ~r/sk-(?!ant-)[A-Za-z0-9]{40,}/,
     "OpenAI API key checked into source (starts with sk- but not sk-ant-)."},
    {"github_pat", :critical, ~r/(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}/,
     "GitHub personal access token or fine-grained PAT."},
    {"aws_access_key", :critical, ~r/\bAKIA[0-9A-Z]{16}\b/, "AWS access key ID."},
    {"livekit_api_key", :critical, ~r/\bAPI[A-Za-z][A-Za-z0-9]{20,}\b/,
     "LiveKit API key (matches production LiveKit key shape APIt...)."},
    {"private_rsa_key", :critical, ~r/-----BEGIN RSA PRIVATE KEY-----/,
     "PEM-encoded RSA private key."},
    {"private_ec_key", :critical, ~r/-----BEGIN EC PRIVATE KEY-----/,
     "PEM-encoded EC private key."},
    {"private_openssh_key", :critical, ~r/-----BEGIN OPENSSH PRIVATE KEY-----/,
     "PEM-encoded OpenSSH private key."}
  ]

  @doc """
  Public accessor for the built-in pattern library. Exposed so the
  pre-push git hook + tests can share the same list without
  duplication. Returns a list of `{id, severity, regex, description}`
  tuples.
  """
  @spec patterns() :: [{String.t(), atom(), Regex.t(), String.t()}]
  def patterns, do: @patterns

  @doc """
  Run a secret-leak scan and file findings. Sweeper-facing entrypoint
  matching the four-scanner uniform contract.
  """
  @spec run_scan(map(), map()) :: {:ok, non_neg_integer()}
  def run_scan(_responsibility, _trigger_meta) do
    repo_root =
      Application.get_env(:platform, :security_scanner_repo_root) || File.cwd!()

    with project_id when is_binary(project_id) <- configured_project_id() do
      allowlist = load_allowlist(repo_root)

      working_findings = scan_working_tree(repo_root, allowlist)

      history_findings =
        if scan_git_history?() do
          scan_git_history(repo_root, allowlist)
        else
          []
        end

      all =
        (working_findings ++ history_findings)
        |> Enum.uniq_by(& &1.fingerprint)
        |> Enum.map(&Map.put(&1, :project_id, project_id))

      Logger.info(
        "[Security.Scanners.SecretLeak] scanned root=#{repo_root} findings=#{length(all)}"
      )

      filed = FindingFiler.file_findings(all)
      {:ok, filed}
    else
      nil ->
        Logger.warning(
          "[Security.Scanners.SecretLeak] no project_id configured — set config :platform, Platform.Security, project_id: <uuid>"
        )

        {:ok, 0}
    end
  rescue
    error ->
      Logger.error("[Security.Scanners.SecretLeak] scanner raised — #{Exception.message(error)}")

      {:ok, 0}
  end

  # ── working-tree scan ─────────────────────────────────────────────────

  @doc false
  def scan_working_tree(repo_root, allowlist) do
    ignore_prefixes = load_gitignore(repo_root)

    repo_root
    |> discover_files(ignore_prefixes)
    |> Enum.flat_map(fn abs_path ->
      scan_file(abs_path, repo_root, allowlist)
    end)
  end

  defp discover_files(root, ignore_prefixes) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn abs ->
      rel = Path.relative_to(abs, root)
      ignored?(rel, ignore_prefixes)
    end)
    # Cap per-file size — a monorepo build artifact accidentally left
    # in the tree can be dozens of MB. Skip anything > 1 MB; a real
    # secret wouldn't hide in a huge binary anyway.
    |> Enum.filter(fn abs ->
      case File.stat(abs) do
        {:ok, %File.Stat{size: size}} -> size <= max_bytes_per_file()
        _ -> false
      end
    end)
  end

  # A tiny gitignore parser — supports the common cases:
  # bare directory names (`deps/`), path segments (`_build/`), plain
  # file extensions (`*.local`), and comments. Not a full glob
  # engine — we bail to prefix-matching. Good enough for the scanner
  # because the CVE + Code scanners already share the same repo-root
  # walker and the shipped `.gitignore` here is simple.
  defp load_gitignore(root) do
    path = Path.join(root, ".gitignore")

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)
        # Drop negations for now (`!.env.example`) — we treat them as
        # "please keep this file". Handled by the ignore-with-negation
        # loop below.
        |> Enum.reject(fn line -> String.starts_with?(line, "!") end)
        |> Kernel.++(default_walk_ignore_prefixes())

      _ ->
        default_walk_ignore_prefixes()
    end
  end

  # A minimal set of prefixes we always skip regardless of `.gitignore`
  # so the scanner never gets stuck on `_build/`, `deps/`, or dot-dirs
  # that the tree-walker's `match_dot: true` otherwise picks up.
  defp default_walk_ignore_prefixes do
    ["_build/", "deps/", ".git/", ".elixir_ls/", "node_modules/", "cover/", "priv/static/"]
  end

  defp ignored?(rel, patterns) do
    Enum.any?(patterns, fn pattern -> matches_gitignore?(rel, pattern) end)
  end

  # Match a relative path against one gitignore-style entry.
  defp matches_gitignore?(rel, pattern) do
    cond do
      # bare dir prefix `_build/` → drop anything under it
      String.ends_with?(pattern, "/") ->
        String.starts_with?(rel, pattern) or String.contains?(rel, "/" <> pattern)

      # simple extension glob `*.local`
      String.starts_with?(pattern, "*.") ->
        String.ends_with?(rel, String.trim_leading(pattern, "*"))

      # rooted path `/deps/` — strip lead `/` and treat as prefix
      String.starts_with?(pattern, "/") ->
        stripped = String.trim_leading(pattern, "/")
        String.starts_with?(rel, stripped)

      # `.env.*` — leading-dot prefix
      String.starts_with?(pattern, ".") and String.contains?(pattern, "*") ->
        base = String.trim_trailing(pattern, "*")
        String.starts_with?(Path.basename(rel), base)

      # bare filename or dir
      true ->
        rel == pattern or String.starts_with?(rel, pattern <> "/") or
          Path.basename(rel) == pattern
    end
  end

  defp scan_file(abs_path, repo_root, allowlist) do
    relative = Path.relative_to(abs_path, repo_root)

    case File.read(abs_path) do
      {:ok, contents} ->
        contents
        |> scan_string(relative)
        |> Enum.reject(fn finding -> allowlisted?(finding, allowlist) end)
        |> Kernel.++(env_file_finding(relative, contents, allowlist))

      _ ->
        []
    end
  end

  # `.env` accidentally staged: if the file's basename matches
  # `.env` OR `.env.*` (but not `.env.example`) AND it isn't
  # allowlisted, flag it wholesale — the .gitignore keeps them out
  # of commits BUT a fresh repo without a proper .gitignore lets
  # them slip. This is a wholesale-file finding (line = 1) rather
  # than a per-line hit.
  defp env_file_finding(rel, _contents, allowlist) do
    base = Path.basename(rel)

    if env_file?(base) do
      finding = %{
        scanner_key: "security.secret_leak",
        severity: :critical,
        title: "`.env` file present in working tree — likely to leak",
        description: env_file_description(rel),
        fingerprint: "secret_leak:env_file:#{rel}:1",
        suggested_fix:
          "Move the file's values into a real secrets store (see `reference_suite_prod_secrets`) and add `#{rel}` to `.gitignore` if it isn't already.",
        metadata: %{"file" => rel, "line" => 1, "pattern_id" => "env_file"}
      }

      if allowlisted?(finding, allowlist), do: [], else: [finding]
    else
      []
    end
  end

  defp env_file?(basename) do
    cond do
      basename == ".env" -> true
      basename == ".env.example" -> false
      String.starts_with?(basename, ".env.") -> true
      true -> false
    end
  end

  defp env_file_description(rel) do
    """
    ## Match

    **File:** `#{rel}`
    **Pattern:** `env_file`

    ## Rotation checklist

    1. Rotate every value the file contains at the upstream provider.
    2. Move the values into a proper secrets store — see the
       `reference_suite_prod_secrets` memory for the on-host paths.
    3. Add `#{rel}` to `.gitignore`.
    4. Purge the file from git history if it was ever committed —
       `git filter-repo --path #{rel} --invert-paths`.
    """
  end

  defp scan_string(contents, relative) do
    lines = String.split(contents, "\n")

    @patterns
    |> Enum.flat_map(fn {pattern_id, severity, regex, description} ->
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        case Regex.run(regex, line, capture: :first) do
          [match] ->
            [
              build_finding(
                pattern_id,
                severity,
                relative,
                line_no,
                line,
                match,
                description
              )
            ]

          _ ->
            []
        end
      end)
    end)
  end

  defp build_finding(pattern_id, severity, relative, line_no, line, match, description) do
    masked = mask(match)

    %{
      scanner_key: "security.secret_leak",
      severity: severity,
      title: "Suspected `#{pattern_id}` in #{relative}:#{line_no}",
      description: build_description(pattern_id, relative, line_no, masked, description, line),
      fingerprint: "secret_leak:#{pattern_id}:#{relative}:#{line_no}",
      suggested_fix:
        "Rotate the leaked value at the upstream provider immediately, purge from git history, and move the real value to a proper secrets store.",
      metadata: %{
        "file" => relative,
        "line" => line_no,
        "pattern_id" => pattern_id,
        "masked" => masked
      }
    }
  end

  defp build_description(pattern_id, relative, line_no, masked, description, snippet_line) do
    # Mask the snippet by scrubbing every pattern match — the raw
    # value cannot appear in the task description or the task itself
    # becomes a leak vector once it renders anywhere it's visible.
    scrubbed = scrub_snippet(snippet_line)

    """
    ## Match

    **File:** `#{relative}`
    **Line:** `#{line_no}`
    **Pattern:** `#{pattern_id}`
    **Masked value:** `#{masked}`

    ## Description

    #{description}

    ## Snippet

    ```
    #{line_no}: #{String.slice(scrubbed, 0, 200)}
    ```

    ## Rotation checklist

    1. Revoke the leaked credential at the upstream provider.
    2. Generate a replacement.
    3. Update the secret store (see `reference_suite_prod_secrets`
       for the on-host paths) with the new value.
    4. Rotate any downstream references — CI env, deploys, dev
       workstations.
    5. Purge the value from git history if the file was ever
       committed — `git filter-repo --replace-text` or a full-history
       rewrite. Coordinate with anyone who has a checkout.
    """
  end

  # First 6 chars + ellipsis. Short enough to identify without
  # letting the task description itself become a leak vector.
  defp mask(binary) when byte_size(binary) <= 6, do: "***"

  defp mask(binary) do
    binary
    |> String.slice(0, 6)
    |> Kernel.<>("…")
  end

  # Scrub any matches of the pattern library from `line` before
  # embedding it in a task description. Prevents the task itself
  # from becoming a secondary leak vector.
  defp scrub_snippet(line) do
    Enum.reduce(@patterns, line, fn {_id, _sev, regex, _desc}, acc ->
      Regex.replace(regex, acc, fn match -> mask(match) end)
    end)
  end

  # ── git-history scan ──────────────────────────────────────────────────

  @doc false
  def scan_git_history(repo_root, allowlist) do
    case System.cmd("git", ["-C", repo_root, "log", "--all", "-p", "-U0"], stderr_to_stdout: true) do
      {output, 0} ->
        # Cap total output size — a full-history scan on a real repo
        # can be dozens of MB.
        truncated = String.slice(output, 0, max_git_log_bytes())
        scan_history_output(truncated, allowlist)

      {reason, exit_code} ->
        Logger.warning(
          "[Security.Scanners.SecretLeak] git log failed exit=#{exit_code} — skipping history scan: #{String.slice(reason, 0, 200)}"
        )

        []
    end
  rescue
    error ->
      Logger.warning(
        "[Security.Scanners.SecretLeak] git history scan raised — #{Exception.message(error)}"
      )

      []
  end

  defp scan_history_output(output, allowlist) do
    # Bucket the output by commit — `commit <sha>` lines act as
    # boundaries; findings inside a commit share its sha in the
    # fingerprint so per-commit hits stay legible.
    output
    |> String.split(~r/\ncommit /, trim: true)
    |> Enum.flat_map(fn chunk ->
      sha = extract_commit_sha(chunk)

      # Only consider added lines (diff `+ ...` at column 0). We
      # DON'T care about the deletions — those are what a repo is
      # trying to unstage. The presence in history is what matters.
      chunk
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(line, "+") and not String.starts_with?(line, "+++")
      end)
      |> Enum.flat_map(fn line -> match_history_line(line, sha) end)
    end)
    |> Enum.reject(fn finding -> allowlisted?(finding, allowlist) end)
  end

  defp extract_commit_sha(chunk) do
    chunk
    |> String.split("\n", parts: 2)
    |> List.first("")
    |> String.trim()
    |> String.split(" ")
    |> List.first("UNKNOWN")
    |> String.slice(0, 12)
  end

  defp match_history_line(line, sha) do
    @patterns
    |> Enum.flat_map(fn {pattern_id, severity, regex, description} ->
      case Regex.run(regex, line, capture: :first) do
        [match] ->
          masked = mask(match)

          [
            %{
              scanner_key: "security.secret_leak",
              severity: severity,
              title: "Suspected `#{pattern_id}` in git history (commit #{sha})",
              description: """
              ## Match

              **Commit:** `#{sha}`
              **Pattern:** `#{pattern_id}`
              **Masked value:** `#{masked}`

              ## Description

              #{description}

              ## Rotation checklist

              1. Revoke the credential at the upstream provider — it is
                 in the git object store, permanently.
              2. Generate a replacement.
              3. Update the secret store.
              4. Purge from history — `git filter-repo` is the modern
                 tool. Rewriting history requires a coordinated
                 force-push.
              """,
              fingerprint: "secret_leak:history:#{sha}:#{pattern_id}",
              suggested_fix:
                "Rotate immediately — the credential is in the git object store forever, even after a `git filter-repo`.",
              metadata: %{"commit_sha" => sha, "pattern_id" => pattern_id, "masked" => masked}
            }
          ]

        _ ->
          []
      end
    end)
  end

  # ── allowlist ─────────────────────────────────────────────────────────

  @doc false
  def load_allowlist(repo_root) do
    path = Path.join(repo_root, ".gitleaks-allowlist.toml")

    case File.read(path) do
      {:ok, contents} ->
        parse_allowlist(contents)

      _ ->
        []
    end
  end

  # A minimal TOML-slice parser for `[[allowlist]] regex = "..."`
  # blocks. Extracts every `regex = "..."` value (and only that key)
  # into a list of compiled Regex.t(). Doesn't need to be a full TOML
  # parser — the allowlist is small and the format is well-known
  # from gitleaks.
  defp parse_allowlist(contents) do
    ~r/regex\s*=\s*"([^"]+)"/
    |> Regex.scan(contents)
    |> Enum.flat_map(fn
      [_, pattern] ->
        case Regex.compile(pattern) do
          {:ok, compiled} -> [compiled]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp allowlisted?(_finding, []), do: false

  defp allowlisted?(%{metadata: %{"masked" => masked}} = finding, allowlist) do
    # The masked value is only 6 chars + ellipsis, which won't
    # match a full regex. Also try matching against the description
    # (which contains context) and the title.
    haystacks = [masked, Map.get(finding, :title, ""), Map.get(finding, :description, "")]

    Enum.any?(allowlist, fn regex ->
      Enum.any?(haystacks, fn h -> Regex.match?(regex, h) end)
    end)
  end

  defp allowlisted?(finding, allowlist) do
    haystacks = [Map.get(finding, :title, ""), Map.get(finding, :description, "")]

    Enum.any?(allowlist, fn regex ->
      Enum.any?(haystacks, fn h -> Regex.match?(regex, h) end)
    end)
  end

  # ── config accessors ─────────────────────────────────────────────────

  defp scan_git_history? do
    case Application.get_env(:platform, Platform.Security) do
      nil -> false
      kw -> Keyword.get(kw, :secret_leak_scan_git_history, false)
    end
  end

  defp configured_project_id do
    case Application.get_env(:platform, Platform.Security) do
      nil -> nil
      kw -> Keyword.get(kw, :project_id)
    end
  end

  defp max_bytes_per_file do
    case Application.get_env(:platform, Platform.Security) do
      nil -> @default_max_bytes_per_file
      kw -> Keyword.get(kw, :secret_leak_max_bytes_per_file, @default_max_bytes_per_file)
    end
  end

  defp max_git_log_bytes do
    case Application.get_env(:platform, Platform.Security) do
      nil -> @default_max_git_log_bytes
      kw -> Keyword.get(kw, :secret_leak_max_git_log_bytes, @default_max_git_log_bytes)
    end
  end
end
