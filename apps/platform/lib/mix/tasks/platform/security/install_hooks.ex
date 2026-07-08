defmodule Mix.Tasks.Platform.Security.InstallHooks do
  @moduledoc """
  Install the `security_guard` git hooks into the current repo's
  `.git/hooks/` directory (task `019f3e8e-4406` stage 5, ADR-0043).

  Currently installs one hook — the `pre-push` guard that scans the
  diff of every push for secret patterns. On any hit the hook exits
  non-zero and blocks the push. To bypass in emergencies:
  `git push --no-verify`.

  ## Usage

      # Install the hooks (refuses to overwrite a non-security-guard
      # hook — pass --force to overwrite).
      mix platform.security.install_hooks

      # Overwrite an existing pre-push hook.
      mix platform.security.install_hooks --force

  ## Overwrite semantics

  The task refuses to overwrite an existing hook UNLESS either:

    * `--force` is passed
    * the existing hook's first 40 lines mention `security_guard` or
      `019f3e8e-4406` — i.e. it's a previous version of this hook

  This is deliberate — some contributors have their own custom hooks
  (e.g. formatters, credo runs) and blowing them away silently would
  be an unforced error.
  """

  use Mix.Task

  @shortdoc "Install the security_guard pre-push hook"

  @impl Mix.Task
  def run(args) do
    {opts, _remainder, _invalid} =
      OptionParser.parse(args, switches: [force: :boolean], aliases: [f: :force])

    force? = Keyword.get(opts, :force, false)

    with {:ok, git_root} <- discover_git_root(),
         {:ok, source} <- source_hook_path(),
         :ok <- ensure_hooks_dir(git_root),
         :ok <- install_hook(git_root, source, "pre-push", force?) do
      Mix.shell().info("""

      security_guard pre-push hook installed
      ======================================

      Repository: #{git_root}
      Hook:       .git/hooks/pre-push

      Test with:
        echo "sk-abcdefghijklmnopqrstuvwxyz1234567890AB" > /tmp/leak
        git add /tmp/leak && git commit -m 'test' && git push

      Emergency bypass: git push --no-verify

      Full rationale: docs/decisions/0043-security-guard-responsibility.md
      """)
    else
      {:error, {:git_root, reason}} ->
        Mix.raise("Could not discover the repository root: #{reason}")

      {:error, {:source, reason}} ->
        Mix.raise("Could not read the shipped pre-push hook: #{reason}")

      {:error, {:refused, path}} ->
        Mix.raise("""
        Refusing to overwrite existing hook: #{path}

        It doesn't look like a previous security_guard install. Pass
        `--force` if you really want to replace it, or move your existing
        hook aside first.
        """)

      {:error, {:write, reason}} ->
        Mix.raise("Could not write the hook: #{reason}")
    end
  end

  # ── internals ────────────────────────────────────────────────────────

  defp discover_git_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {reason, _} -> {:error, {:git_root, String.trim(reason)}}
    end
  rescue
    error -> {:error, {:git_root, Exception.message(error)}}
  end

  @doc false
  def source_hook_path do
    # `Application.app_dir/2` returns the platform app's priv path in
    # both `mix run` (dev) + release contexts. Falls back to a
    # source-tree relative path when the app isn't yet compiled (e.g.
    # someone running the mix task from a shallow checkout before
    # `mix compile`).
    priv_path =
      try do
        Application.app_dir(:platform, ["priv", "security", "hooks", "pre-push"])
      rescue
        _ -> source_tree_fallback()
      end

    case File.exists?(priv_path) do
      true -> {:ok, priv_path}
      false -> {:error, {:source, "expected pre-push hook at #{priv_path}"}}
    end
  end

  defp source_tree_fallback do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("../../../../priv/security/hooks/pre-push")
    |> Path.expand()
  end

  defp ensure_hooks_dir(git_root) do
    hooks_dir = Path.join([git_root, ".git", "hooks"])
    File.mkdir_p!(hooks_dir)
    :ok
  end

  @doc false
  def install_hook(git_root, source, name, force?) do
    target = Path.join([git_root, ".git", "hooks", name])

    if File.exists?(target) and not force? and not existing_hook_looks_like_ours?(target) do
      {:error, {:refused, target}}
    else
      with {:ok, contents} <- File.read(source),
           :ok <- File.write(target, contents),
           :ok <- File.chmod(target, 0o755) do
        :ok
      else
        {:error, reason} -> {:error, {:write, inspect(reason)}}
      end
    end
  end

  defp existing_hook_looks_like_ours?(path) do
    case File.read(path) do
      {:ok, contents} ->
        first_lines = contents |> String.split("\n") |> Enum.take(40) |> Enum.join("\n")

        String.contains?(first_lines, "security_guard") or
          String.contains?(first_lines, "019f3e8e-4406") or
          String.contains?(first_lines, "security.secret_leak")

      _ ->
        false
    end
  end
end
