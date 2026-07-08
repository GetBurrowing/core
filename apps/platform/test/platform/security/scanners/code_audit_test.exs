defmodule Platform.Security.Scanners.CodeAuditTest do
  @moduledoc """
  Tests for `Platform.Security.Scanners.CodeAudit` (task
  `019f3e8e-4406` stage 4, ADR-0043).

  The scanner has three moving parts: rubric loading (covered by
  `PatternLoaderTest`), a filesystem walk (covered here by installing
  a tmp `security_scanner_repo_root`), and per-pattern dispatch to
  either regex or AST-probe machinery. This suite exercises the
  orchestration + fingerprint / dedup shape.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Security.Scanners.CodeAudit
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @fixture_root Path.expand("../../../support/fixtures/security", __DIR__)

  setup do
    project = create_security_project!()

    prev_project_id =
      Application.get_env(:platform, Platform.Security, [])
      |> Keyword.get(:project_id)

    Application.put_env(
      :platform,
      Platform.Security,
      Application.get_env(:platform, Platform.Security, [])
      |> Keyword.put(:project_id, project.id)
    )

    Application.put_env(
      :platform,
      :code_audit_patterns_path,
      Path.join(@fixture_root, "patterns_min.yaml")
    )

    on_exit(fn ->
      current = Application.get_env(:platform, Platform.Security, [])

      restored =
        if is_nil(prev_project_id) do
          Keyword.delete(current, :project_id)
        else
          Keyword.put(current, :project_id, prev_project_id)
        end

      Application.put_env(:platform, Platform.Security, restored)
      Application.delete_env(:platform, :security_scanner_repo_root)
      Application.delete_env(:platform, :code_audit_patterns_path)
      Application.delete_env(:platform, :code_audit_ignore_relative_prefixes)
    end)

    {:ok, project: project}
  end

  defp create_security_project! do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Security Project #{suffix}"})
    project
  end

  defp install_repo_root!(files) do
    root =
      System.tmp_dir!()
      |> Path.join("code_audit_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    for {rel, contents} <- files do
      abs = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, contents)
    end

    Application.put_env(:platform, :security_scanner_repo_root, root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp list_audit_tasks do
    Platform.Repo.all(TaskSchema)
    |> Enum.filter(fn task ->
      case task.metadata do
        %{"security_scanner" => "security.code_audit"} -> is_nil(task.deleted_at)
        _ -> false
      end
    end)
  end

  # ── regex patterns ─────────────────────────────────────────────────────

  describe "run_scan/2 — regex patterns" do
    test "flags unparameterized_sql with a critical task + file:line fingerprint" do
      install_repo_root!(%{
        "lib/vulnerable.ex" => """
        defmodule Vulnerable do
          def find(user) do
            Repo.query("SELECT * FROM users WHERE id = '\#{user.id}'")
          end
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      [task] = list_audit_tasks()
      assert task.priority == "critical"
      assert task.status == "backlog"
      assert task.title =~ "unparameterized_sql"
      assert task.title =~ "lib/vulnerable.ex"

      assert task.metadata["security_fingerprint"] =~
               ~r|^code_audit:unparameterized_sql:lib/vulnerable\.ex:\d+$|

      assert task.metadata["pattern_id"] == "unparameterized_sql"
      assert task.description =~ "lib/vulnerable.ex"
      assert task.description =~ "SQL injection"
    end

    test "skips a correctly-parameterized query" do
      install_repo_root!(%{
        "lib/safe.ex" => """
        defmodule Safe do
          def find(user) do
            Repo.query("SELECT * FROM users WHERE id = $1", [user.id])
          end
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 0} = CodeAudit.run_scan(%{}, %{})
      end)

      assert list_audit_tasks() == []
    end

    test "flags a hardcoded OpenAI key" do
      install_repo_root!(%{
        "lib/oops.ex" => """
        defmodule Oops do
          @api_key "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      [task] = list_audit_tasks()
      assert task.priority == "critical"
      assert task.metadata["pattern_id"] == "hardcoded_openai_key"
    end

    test "flags interpolated System.cmd argument" do
      install_repo_root!(%{
        "lib/shell.ex" => """
        defmodule Shell do
          def run(user_input) do
            System.cmd("bash", ["-c", "echo \#{user_input}"])
          end
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      [task] = list_audit_tasks()
      assert task.priority == "high"
      assert task.metadata["pattern_id"] == "command_injection_system_cmd"
    end

    test "counts multiple matches on separate lines as separate findings" do
      install_repo_root!(%{
        "lib/multi.ex" => """
        defmodule Multi do
          def a(user), do: Repo.query("A \#{user.id}")
          def b(user), do: Repo.query("B \#{user.id}")
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 2} = CodeAudit.run_scan(%{}, %{})
      end)

      tasks = list_audit_tasks()
      assert length(tasks) == 2
      lines = Enum.map(tasks, & &1.metadata["line"]) |> Enum.sort()
      assert lines == [2, 3]
    end
  end

  # ── AST probes ────────────────────────────────────────────────────────

  describe "run_scan/2 — AST probes" do
    test "flags a webhook controller with no HMAC verifier" do
      install_repo_root!(%{
        "lib/unsafe_webhook.ex" => """
        defmodule UnsafeWebhookController do
          use Phoenix.Controller

          def payment_webhook(conn, params) do
            IO.inspect(params)
            send_resp(conn, 200, "ok")
          end
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      [task] = list_audit_tasks()
      assert task.metadata["pattern_id"] == "missing_webhook_hmac"
      assert task.metadata["kind"] == "ast_probe"
      assert task.priority == "high"
    end

    test "skips a webhook controller that DOES call Plug.Crypto.secure_compare/2" do
      install_repo_root!(%{
        "lib/safe_webhook.ex" => """
        defmodule SafeWebhookController do
          use Phoenix.Controller

          def payment_webhook(conn, params) do
            expected = compute_signature(conn.assigns.raw_body)
            got = get_req_header(conn, "x-signature") |> List.first()

            if Plug.Crypto.secure_compare(expected, got || "") do
              send_resp(conn, 200, "ok")
            else
              send_resp(conn, 401, "no")
            end
          end

          defp compute_signature(_body), do: "sig"
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 0} = CodeAudit.run_scan(%{}, %{})
      end)

      assert list_audit_tasks() == []
    end
  end

  # ── dedup ────────────────────────────────────────────────────────────

  describe "run_scan/2 — dedup" do
    test "a second scan with the same file files 0 additional tasks" do
      install_repo_root!(%{
        "lib/dedup.ex" => """
        defmodule Dedup do
          def run(user), do: Repo.query("SELECT \#{user.id}")
        end
        """
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      assert length(list_audit_tasks()) == 1

      capture_log(fn ->
        assert {:ok, 0} = CodeAudit.run_scan(%{}, %{})
      end)

      assert length(list_audit_tasks()) == 1
    end
  end

  # ── config guardrails ────────────────────────────────────────────────

  describe "run_scan/2 — missing config" do
    test "returns {:ok, 0} + logs warn when project_id is not configured" do
      install_repo_root!(%{
        "lib/x.ex" => "defmodule X, do: Repo.query(\"SELECT \#{y}\")"
      })

      current = Application.get_env(:platform, Platform.Security, [])
      Application.put_env(:platform, Platform.Security, Keyword.delete(current, :project_id))

      log =
        capture_log(fn ->
          assert {:ok, 0} = CodeAudit.run_scan(%{}, %{})
        end)

      assert log =~ "no project_id configured"
      assert list_audit_tasks() == []
    end

    test "returns {:ok, 0} + logs warn when the rubric fails to load" do
      install_repo_root!(%{
        "lib/x.ex" => "defmodule X, do: Repo.query(\"SELECT \#{y}\")"
      })

      Application.put_env(
        :platform,
        :code_audit_patterns_path,
        Path.join(@fixture_root, "patterns_broken.yaml")
      )

      log =
        capture_log(fn ->
          assert {:ok, 0} = CodeAudit.run_scan(%{}, %{})
        end)

      assert log =~ "rubric load failed"
      assert list_audit_tasks() == []
    end
  end

  # ── ignore prefixes ─────────────────────────────────────────────────

  describe "run_scan/2 — ignore prefixes" do
    test "skips files under deps/ / _build/ by default" do
      install_repo_root!(%{
        "lib/keep.ex" => "defmodule Keep, do: Repo.query(\"SELECT \#{u.id}\")",
        "deps/vendored/lib/vendor.ex" => "defmodule Vendor, do: Repo.query(\"SELECT \#{u.id}\")",
        "_build/dev/lib/gen.ex" => "defmodule Gen, do: Repo.query(\"SELECT \#{u.id}\")"
      })

      capture_log(fn ->
        assert {:ok, 1} = CodeAudit.run_scan(%{}, %{})
      end)

      [task] = list_audit_tasks()
      assert task.metadata["file"] == "lib/keep.ex"
    end
  end
end
