defmodule Platform.Tasks.StackDeployer.GitShellRunnerTest do
  @moduledoc """
  Regression cover for two of the four independent breaks that stood
  between a reviewed stack member and a merged one:

    * **Fix B** — the git credential helper was never wired for the
      deployer's shared clone. `GitShellRunner`'s own moduledoc said
      "Setting that up is deferred to a follow-up"; the follow-up never
      happened, so `GITHUB_TOKEN` in the prod environment had nothing to
      consume it and every rollup push failed with a generic non-zero git
      exit.

    * **Fix C** — `gh` is not installed in `ghcr.io/getburrowing/core`.
      `System.cmd("gh", …)` on a host without it raises
      `ErlangError: :enoent`, which is indistinguishable from a git
      failure once it has been through the deployer's try/rescue.

  `async: false` because the `gh` tests scrub `PATH` for the duration of a
  single assertion. ExUnit runs sync modules serially after every async
  module has finished, so nothing else is looking at `PATH` meanwhile.
  """

  use ExUnit.Case, async: false

  alias Platform.Execution.LocalWorkspace
  alias Platform.Tasks.StackDeployer.GitShellRunner

  setup do
    root = Platform.TestTemp.mkdir!("gsr-test")

    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(
      :platform,
      :stack_deployer,
      Keyword.put(prev, :repo_root, Path.join(root, "clones"))
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # ── Fix B: credential helper on the shared clone ────────────────────────

  describe "ensure_clone: GITHUB_TOKEN credential helper (regression)" do
    test "a freshly-cloned repo carries the credential helper", %{root: root} do
      origin = seed_origin!(root)
      project_id = "proj-fresh-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: :created}} =
               GitShellRunner.ensure_rollup_branch(%{
                 repo_url: origin,
                 base_branch: "main",
                 rollup_branch: "stack/fresh",
                 project_id: project_id
               })

      clone = clone_path(project_id)
      assert File.dir?(Path.join(clone, ".git"))

      assert git_config(clone, "credential.helper") == expected_helper()
      assert git_config(clone, "credential.useHttpPath") == "true"
    end

    test "an ALREADY-EXISTING clone acquires the helper too", %{root: root} do
      # `ensure_clone/2` short-circuits on an existing clone. Every clone
      # created before this fix landed is in exactly this state, so the
      # already-exists path has to configure the helper as well or the
      # deploy stays broken until someone deletes the clone by hand.
      origin = seed_origin!(root)
      project_id = "proj-existing-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               GitShellRunner.ensure_rollup_branch(%{
                 repo_url: origin,
                 base_branch: "main",
                 rollup_branch: "stack/one",
                 project_id: project_id
               })

      clone = clone_path(project_id)

      # Simulate a clone made before the fix: strip the helper back out.
      # `--unset-all` exits 5 when the key is absent, which is what happens
      # under the buggy code — tolerate it so this test detonates on the
      # assertion below rather than on a MatchError.
      unset(clone, "credential.helper")
      unset(clone, "credential.useHttpPath")

      assert git_config(clone, "credential.helper") == nil

      # Second invocation takes the already-exists branch.
      assert {:ok, _} =
               GitShellRunner.ensure_rollup_branch(%{
                 repo_url: origin,
                 base_branch: "main",
                 rollup_branch: "stack/two",
                 project_id: project_id
               })

      assert git_config(clone, "credential.helper") == expected_helper()
      assert git_config(clone, "credential.useHttpPath") == "true"
    end

    test "the helper is idempotent — repeated calls leave exactly one value", %{root: root} do
      origin = seed_origin!(root)
      project_id = "proj-idem-#{System.unique_integer([:positive])}"

      args = %{
        repo_url: origin,
        base_branch: "main",
        rollup_branch: "stack/idem",
        project_id: project_id
      }

      assert {:ok, _} = GitShellRunner.ensure_rollup_branch(args)
      assert {:ok, _} = GitShellRunner.ensure_rollup_branch(args)
      assert {:ok, _} = GitShellRunner.ensure_rollup_branch(args)

      clone = clone_path(project_id)

      {out, 0} =
        System.cmd("git", ["config", "--local", "--get-all", "credential.helper"], cd: clone)

      assert out |> String.split("\n", trim: true) |> length() == 1
    end

    test "the token is never written to disk", %{root: root} do
      # The design reads `$GITHUB_TOKEN` from the environment at push time
      # precisely so it never lands in a config file or a remote URL. Pin
      # that: run the whole flow with a distinctive token set and grep the
      # repo config for it.
      origin = seed_origin!(root)
      project_id = "proj-notoken-#{System.unique_integer([:positive])}"
      sentinel = "ghp_SENTINEL_MUST_NOT_BE_PERSISTED_#{System.unique_integer([:positive])}"

      prev_token = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", sentinel)

      on_exit(fn ->
        if prev_token,
          do: System.put_env("GITHUB_TOKEN", prev_token),
          else: System.delete_env("GITHUB_TOKEN")
      end)

      assert {:ok, _} =
               GitShellRunner.ensure_rollup_branch(%{
                 repo_url: origin,
                 base_branch: "main",
                 rollup_branch: "stack/notoken",
                 project_id: project_id
               })

      clone = clone_path(project_id)
      config = File.read!(Path.join([clone, ".git", "config"]))

      refute String.contains?(config, sentinel)
      assert String.contains?(config, "$GITHUB_TOKEN")

      {remote, 0} = System.cmd("git", ["remote", "get-url", "origin"], cd: clone)
      refute String.contains?(remote, sentinel)
    end

    test "git actually resolves credentials through the helper", %{root: root} do
      # Not a stub: this drives git's OWN credential machinery with the
      # helper this fix installs and asserts on what git hands back to a
      # transport. `git credential fill` is the exact code path a push over
      # HTTPS uses to obtain a username/password.
      #
      # `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` are nulled so a developer's
      # own helper (osxkeychain, libsecret, …) can't answer first —
      # `credential.helper` is multi-valued and git tries system, then
      # global, then local, then `-c`.
      sentinel = "ghp_LIVE_HELPER_#{System.unique_integer([:positive])}"

      input = Path.join(root, "cred-input")
      File.write!(input, "protocol=https\nhost=github.com\npath=Startup-Suite/core.git\n\n")

      command =
        "git " <>
          Enum.map_join(LocalWorkspace.git_push_auth_cli_args(), " ", &sh_quote/1) <>
          " credential fill < " <> sh_quote(input)

      {out, 0} =
        System.cmd("sh", ["-c", command],
          stderr_to_stdout: true,
          env: [
            {"GITHUB_TOKEN", sentinel},
            {"GIT_TERMINAL_PROMPT", "0"},
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_SYSTEM", "/dev/null"}
          ]
        )

      assert out =~ "username=x-access-token"
      assert out =~ "password=#{sentinel}"
    end

    test "an unset GITHUB_TOKEN fails loudly instead of pushing an empty password", %{root: root} do
      input = Path.join(root, "cred-input-empty")
      File.write!(input, "protocol=https\nhost=github.com\npath=Startup-Suite/core.git\n\n")

      command =
        "git " <>
          Enum.map_join(LocalWorkspace.git_push_auth_cli_args(), " ", &sh_quote/1) <>
          " credential fill < " <> sh_quote(input)

      {out, _code} =
        System.cmd("sh", ["-c", command],
          stderr_to_stdout: true,
          env: [
            {"GITHUB_TOKEN", ""},
            {"GIT_TERMINAL_PROMPT", "0"},
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_SYSTEM", "/dev/null"}
          ]
        )

      refute out =~ "username=x-access-token"
    end
  end

  # ── Fix C: gh guard ─────────────────────────────────────────────────────

  describe "gh availability guard (regression)" do
    test "open_stack_pr returns {:error, {:gh_unavailable, _}} when gh is not on PATH" do
      result =
        without_gh(fn ->
          GitShellRunner.open_stack_pr(%{
            repo_url: "https://github.com/test/repo",
            base_branch: "main",
            rollup_branch: "stack/x",
            title: "t",
            body: "b"
          })
        end)

      assert {:error, {:gh_unavailable, message}} = result
      assert message =~ "gh"
    end

    test "close_stack_pr returns {:error, {:gh_unavailable, _}} when gh is not on PATH" do
      result =
        without_gh(fn ->
          GitShellRunner.close_stack_pr(%{
            repo_url: "https://github.com/test/repo",
            pr_number: 7
          })
        end)

      assert {:error, {:gh_unavailable, message}} = result
      assert message =~ "gh"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp sh_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  # 0 = unset, 5 = key wasn't there. Both are "the key is now absent".
  defp unset(clone, key) do
    {_, code} =
      System.cmd("git", ["config", "--local", "--unset-all", key],
        cd: clone,
        stderr_to_stdout: true
      )

    assert code in [0, 5]
  end

  defp expected_helper do
    {"credential.helper", helper} =
      Enum.find(LocalWorkspace.git_push_auth_config(), &match?({"credential.helper", _}, &1))

    helper
  end

  defp clone_path(project_id) do
    Application.get_env(:platform, :stack_deployer, [])
    |> Keyword.fetch!(:repo_root)
    |> Path.expand()
    |> Path.join(String.replace(project_id, ~r/[^A-Za-z0-9._-]/u, "_"))
  end

  defp git_config(clone, key) do
    case System.cmd("git", ["config", "--local", "--get", key],
           cd: clone,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # A real bare repo with one commit on `main`, used as `origin`. Real
  # `git clone` / `git fetch` / `git push` run against it — no stubs.
  defp seed_origin!(root) do
    bare = Path.join(root, "origin.git")
    work = Path.join(root, "seed")

    {_, 0} = System.cmd("git", ["init", "--quiet", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["init", "--quiet", "--initial-branch=main", work])

    File.write!(Path.join(work, "README.md"), "seed\n")

    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: work)
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "seed"], cd: work)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", bare], cd: work)
    {_, 0} = System.cmd("git", ["push", "--quiet", "origin", "main"], cd: work)

    bare
  end

  # Run `fun` with an empty `PATH` so `System.find_executable("gh")`
  # returns nil, then restore. Without the guard this makes
  # `System.cmd("gh", …)` raise `ErlangError: :enoent` — the opaque failure
  # the guard replaces.
  defp without_gh(fun) do
    previous = System.get_env("PATH")
    System.put_env("PATH", Path.join(System.tmp_dir!(), "definitely-not-a-bin-dir"))

    try do
      fun.()
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end
  end
end
