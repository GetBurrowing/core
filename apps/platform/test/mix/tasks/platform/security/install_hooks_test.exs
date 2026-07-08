defmodule Mix.Tasks.Platform.Security.InstallHooksTest do
  @moduledoc """
  Tests for the `mix platform.security.install_hooks` task (task
  `019f3e8e-4406` stage 5, ADR-0043).

  Exercises the two hard-to-reason-about corners of the installer:

    * The `install_hook/4` helper copies + chmods the shipped source
      when the target doesn't exist.
    * `install_hook/4` refuses to overwrite a non-security_guard hook
      unless `force?` is `true`, but silently overwrites an older
      security_guard hook (identified by header keywords).

  We DON'T exercise the top-level `run/1` because it discovers the git
  root via `System.cmd/2` — mocking that in ExUnit needs a fake `git`
  binary on PATH which is expensive to set up. The helper covers the
  branch logic.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Platform.Security.InstallHooks

  setup do
    tmp = Path.join(System.tmp_dir!(), "install_hooks_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([tmp, ".git", "hooks"]))

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, git_root: tmp}
  end

  describe "source_hook_path/0" do
    test "returns the shipped priv/security/hooks/pre-push path" do
      assert {:ok, path} = InstallHooks.source_hook_path()
      assert String.ends_with?(path, "priv/security/hooks/pre-push")
      assert File.exists?(path)
    end

    test "the shipped hook starts with a #!/usr/bin/env bash shebang" do
      {:ok, path} = InstallHooks.source_hook_path()
      contents = File.read!(path)
      assert String.starts_with?(contents, "#!/usr/bin/env bash")
    end
  end

  describe "install_hook/4 — fresh install" do
    test "copies + chmod +x the hook when target doesn't exist", %{git_root: git_root} do
      {:ok, source} = InstallHooks.source_hook_path()

      assert :ok = InstallHooks.install_hook(git_root, source, "pre-push", false)

      target = Path.join([git_root, ".git", "hooks", "pre-push"])
      assert File.exists?(target)

      # Executable bit set.
      %File.Stat{mode: mode} = File.stat!(target)
      # The user-executable bit (0o100) should be set.
      assert Bitwise.band(mode, 0o100) == 0o100

      # Contents match the source.
      assert File.read!(target) == File.read!(source)
    end
  end

  describe "install_hook/4 — refuses to overwrite" do
    test "refuses when target is a user-supplied hook (no security_guard mention)",
         %{git_root: git_root} do
      target = Path.join([git_root, ".git", "hooks", "pre-push"])

      File.write!(
        target,
        "#!/bin/bash\n# my personal formatter hook\nmix format --check-formatted\n"
      )

      {:ok, source} = InstallHooks.source_hook_path()

      assert {:error, {:refused, ^target}} =
               InstallHooks.install_hook(git_root, source, "pre-push", false)

      # Not touched.
      assert File.read!(target) =~ "personal formatter hook"
    end

    test "overwrites with --force even when target is user-supplied",
         %{git_root: git_root} do
      target = Path.join([git_root, ".git", "hooks", "pre-push"])
      File.write!(target, "#!/bin/bash\nmy hook\n")

      {:ok, source} = InstallHooks.source_hook_path()

      assert :ok = InstallHooks.install_hook(git_root, source, "pre-push", true)
      assert File.read!(target) == File.read!(source)
    end

    test "overwrites without --force when target is an older security_guard hook",
         %{git_root: git_root} do
      target = Path.join([git_root, ".git", "hooks", "pre-push"])
      # Contains "security_guard" in the first 40 lines → treated as ours.
      File.write!(target, "#!/bin/bash\n# security_guard old version\nexit 0\n")

      {:ok, source} = InstallHooks.source_hook_path()

      assert :ok = InstallHooks.install_hook(git_root, source, "pre-push", false)
      assert File.read!(target) == File.read!(source)
    end

    test "overwrites without --force when target contains the task ID",
         %{git_root: git_root} do
      target = Path.join([git_root, ".git", "hooks", "pre-push"])
      # Contains "019f3e8e-4406" → treated as ours.
      File.write!(target, "#!/bin/bash\n# from 019f3e8e-4406\nexit 0\n")

      {:ok, source} = InstallHooks.source_hook_path()

      assert :ok = InstallHooks.install_hook(git_root, source, "pre-push", false)
    end
  end
end
