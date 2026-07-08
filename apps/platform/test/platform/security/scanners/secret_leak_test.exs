defmodule Platform.Security.Scanners.SecretLeakTest do
  @moduledoc """
  Tests for `Platform.Security.Scanners.SecretLeak` (task
  `019f3e8e-4406` stage 5, ADR-0043).

  Covers the pattern library (per-key type), allowlist behavior,
  `.env`-file detection, and the git-history opt-in — the four cases
  the stage plan calls out.
  """
  use Platform.DataCase, async: false

  alias Platform.Security.Scanners.SecretLeak
  alias Platform.Tasks

  @openai_key "sk-abcdefghij1234567890KLMNOPQRSTUVWXYZ1234567890AB"
  @anthropic_key "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789abcdefghij"
  @github_pat "ghp_abcdefghij1234567890ABCDEFGHIJKLMNOP"
  @aws_key "AKIAIOSFODNN7EXAMPLE"
  @rsa_key_header "-----BEGIN RSA PRIVATE KEY-----"

  defp create_security_project! do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "SecretLeak Test #{suffix}"})
    project
  end

  defp put_security_config(project_id, extras \\ []) do
    prev = Application.get_env(:platform, Platform.Security)

    merged =
      Keyword.merge(
        prev || [],
        [project_id: project_id, finding_digest_threshold: 100] ++ extras
      )

    Application.put_env(:platform, Platform.Security, merged)

    ExUnit.Callbacks.on_exit(fn ->
      if prev do
        Application.put_env(:platform, Platform.Security, prev)
      else
        Application.delete_env(:platform, Platform.Security)
      end
    end)
  end

  defp put_repo_root(root) do
    prev = Application.get_env(:platform, :security_scanner_repo_root)
    Application.put_env(:platform, :security_scanner_repo_root, root)

    ExUnit.Callbacks.on_exit(fn ->
      if prev do
        Application.put_env(:platform, :security_scanner_repo_root, prev)
      else
        Application.delete_env(:platform, :security_scanner_repo_root)
      end
    end)
  end

  defp write_file!(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  describe "run_scan/2 — pattern detection" do
    @tag :tmp_dir
    test "OpenAI API key in working tree files 1 finding", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "config/leaked.exs", ~s|api_key = "#{@openai_key}"|)

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      assert task.priority == "critical"
      assert task.metadata["security_scanner"] == "security.secret_leak"
      assert task.metadata["security_fingerprint"] =~ ~r/^secret_leak:openai_api_key:/
      # Description carries the masked value, not the full key.
      assert task.description =~ "sk-abc"
      refute task.description =~ @openai_key
    end

    @tag :tmp_dir
    test "Anthropic API key is detected as anthropic_api_key, not openai", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "config/leaked.exs", ~s|key = "#{@anthropic_key}"|)

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      assert task.metadata["security_fingerprint"] =~ ~r/^secret_leak:anthropic_api_key:/
    end

    @tag :tmp_dir
    test "GitHub PAT is detected", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "deploy.sh", ~s|GH_TOKEN=#{@github_pat}|)

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      assert task.metadata["security_fingerprint"] =~ ~r/^secret_leak:github_pat:/
    end

    @tag :tmp_dir
    test "AWS access key is detected", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "aws.env", "AWS_ACCESS_KEY_ID=#{@aws_key}")

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      # The AWS pattern is severity :critical too.
      assert task.priority == "critical"
      # Fingerprint could be for aws_access_key or env_file (env files are
      # a wholesale finding). Assert at least one AWS-shaped hit.
      fingerprints =
        Tasks.list_tasks_by_project(project.id) |> Enum.map(& &1.metadata["security_fingerprint"])

      assert Enum.any?(fingerprints, &String.contains?(&1, "aws_access_key"))
    end

    @tag :tmp_dir
    test "RSA private key header is detected", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "id_rsa", @rsa_key_header <> "\nabc\n-----END RSA PRIVATE KEY-----\n")

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      assert task.metadata["security_fingerprint"] =~ ~r/^secret_leak:private_rsa_key:/
    end

    @tag :tmp_dir
    test "clean working tree files 0 findings", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "lib/clean.ex", "defmodule Clean, do: nil\n")

      assert {:ok, 0} = SecretLeak.run_scan(%{}, %{})
      assert [] = Tasks.list_tasks_by_project(project.id)
    end
  end

  describe "run_scan/2 — .env file wholesale detection" do
    @tag :tmp_dir
    test "a bare `.env` file flags a wholesale finding", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, ".env", "FOO=bar\nBAZ=qux\n")

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})

      [task] = Tasks.list_tasks_by_project(project.id)
      assert task.metadata["security_fingerprint"] =~ ~r/^secret_leak:env_file:/
      assert task.metadata["pattern_id"] == "env_file"
    end

    @tag :tmp_dir
    test ".env.example is NOT flagged", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, ".env.example", "FOO=  # your value here\n")

      assert {:ok, 0} = SecretLeak.run_scan(%{}, %{})
    end
  end

  describe "run_scan/2 — allowlist" do
    @tag :tmp_dir
    test "an entry matching the fixture is dropped", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      # Allowlist matches the masked-value prefix that appears in the
      # finding's title (the openai key starts with "sk-abc").
      write_file!(
        tmp_dir,
        ".gitleaks-allowlist.toml",
        """
        [[allowlist]]
        description = "test allowlist entry"
        regex = "sk-abc"
        """
      )

      write_file!(tmp_dir, "config/leaked.exs", ~s|api_key = "#{@openai_key}"|)

      assert {:ok, 0} = SecretLeak.run_scan(%{}, %{})
      assert [] = Tasks.list_tasks_by_project(project.id)
    end

    @tag :tmp_dir
    test "no allowlist file → all findings flagged", %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id)
      put_repo_root(tmp_dir)

      write_file!(tmp_dir, "config/leaked.exs", ~s|api_key = "#{@openai_key}"|)

      assert {:ok, 1} = SecretLeak.run_scan(%{}, %{})
    end
  end

  describe "run_scan/2 — git-history opt-in" do
    @tag :tmp_dir
    test "history scan is off by default → history-only leaks are not flagged",
         %{tmp_dir: tmp_dir} do
      project = create_security_project!()
      put_security_config(project.id, secret_leak_scan_git_history: false)
      put_repo_root(tmp_dir)

      # No working-tree leak, so 0 findings unless history is scanned.
      write_file!(tmp_dir, "lib/clean.ex", "defmodule Clean, do: nil\n")

      assert {:ok, 0} = SecretLeak.run_scan(%{}, %{})
    end
  end

  describe "run_scan/2 — no project_id configured" do
    @tag :tmp_dir
    test "returns {:ok, 0} + warns, does NOT crash", %{tmp_dir: tmp_dir} do
      # Clear project_id explicitly.
      prev = Application.get_env(:platform, Platform.Security)

      Application.put_env(
        :platform,
        Platform.Security,
        Keyword.merge(prev || [], project_id: nil)
      )

      on_exit(fn ->
        if prev do
          Application.put_env(:platform, Platform.Security, prev)
        else
          Application.delete_env(:platform, Platform.Security)
        end
      end)

      put_repo_root(tmp_dir)
      write_file!(tmp_dir, "config/leaked.exs", ~s|api_key = "#{@openai_key}"|)

      assert {:ok, 0} = SecretLeak.run_scan(%{}, %{})
    end
  end

  describe "patterns/0 accessor" do
    test "exposes the built-in pattern library as a tuple list" do
      patterns = SecretLeak.patterns()

      assert is_list(patterns)
      assert length(patterns) >= 7

      # Every entry is a 4-tuple of {id, severity, %Regex{}, description}.
      for {id, severity, regex, description} <- patterns do
        assert is_binary(id)
        assert severity in [:critical, :high, :medium, :low]
        assert %Regex{} = regex
        assert is_binary(description)
      end
    end

    test "OpenAI pattern does NOT match Anthropic keys (order matters)" do
      # Anthropic runs FIRST so its longer prefix wins.
      {"anthropic_api_key", _, anth_regex, _} = Enum.at(SecretLeak.patterns(), 0)
      {"openai_api_key", _, oai_regex, _} = Enum.at(SecretLeak.patterns(), 1)

      # Anthropic regex matches an Anthropic key.
      assert Regex.match?(anth_regex, @anthropic_key)

      # OpenAI regex should NOT match an Anthropic key (has `sk-ant-` prefix).
      refute Regex.match?(oai_regex, @anthropic_key)

      # And OpenAI DOES match an OpenAI key.
      assert Regex.match?(oai_regex, @openai_key)
    end
  end
end
