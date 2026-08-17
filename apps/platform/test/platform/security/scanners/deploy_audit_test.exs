defmodule Platform.Security.Scanners.DeployAuditTest do
  @moduledoc """
  Tests for `Platform.Security.Scanners.DeployAudit` (task
  `019f3e8e-4406` stage 4, ADR-0043).

  DeployAudit's four probes (Traefik, containers, env-var diff, TLS)
  are exercised via tmp fixtures pointed at by the
  `deploy_audit_*_root` config keys the scanner reads from. Each
  probe has a "missing root" case that must NOT crash — the scanner
  runs everywhere including dev workstations where these paths don't
  exist.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Security.Scanners.DeployAudit
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  setup do
    project = create_security_project!()

    prev_security_config = Application.get_env(:platform, Platform.Security, [])

    tmp_roots = %{
      traefik: mkdir!("deploy_traefik"),
      containers: mkdir!("deploy_containers"),
      core_ops: mkdir!("deploy_core_ops"),
      tls: mkdir!("deploy_tls")
    }

    Application.put_env(
      :platform,
      Platform.Security,
      prev_security_config
      |> Keyword.put(:project_id, project.id)
      |> Keyword.put(:deploy_audit_traefik_root, tmp_roots.traefik)
      |> Keyword.put(:deploy_audit_containers_root, tmp_roots.containers)
      |> Keyword.put(:deploy_audit_core_ops_root, tmp_roots.core_ops)
      |> Keyword.put(:deploy_audit_tls_root, tmp_roots.tls)
    )

    on_exit(fn ->
      Application.put_env(:platform, Platform.Security, prev_security_config)

      Enum.each(tmp_roots, fn {_, path} -> File.rm_rf!(path) end)
    end)

    {:ok, project: project, roots: tmp_roots}
  end

  defp create_security_project! do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Security Project #{suffix}"})
    project
  end

  defp mkdir!(name) do
    path =
      Platform.TestTemp.mkdir!("deploy_audit_#{name}")

    path
  end

  defp write!(root, rel, contents) do
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, contents)
    abs
  end

  defp list_deploy_tasks do
    Platform.Repo.all(TaskSchema)
    |> Enum.filter(fn task ->
      case task.metadata do
        %{"security_scanner" => "security.deploy_audit"} -> is_nil(task.deleted_at)
        _ -> false
      end
    end)
  end

  # ── Traefik probe ──────────────────────────────────────────────────

  describe "run_scan/2 — Traefik probe" do
    test "flags an HTTP-only route without a redirect middleware", %{roots: r} do
      write!(r.traefik, "public.toml", """
      [http.routers.public-site]
        entryPoints = ["web"]
        rule = "Host(`example.com`)"
        service = "app"
        middlewares = ["compress"]
      """)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      assert Enum.any?(tasks, fn t ->
               t.metadata["security_fingerprint"] =~ "deploy_audit:traefik_http_only:"
             end)
    end

    test "flags a protected upstream lacking chain-oauth2", %{roots: r} do
      write!(r.traefik, "admin.toml", """
      [http.routers.admin]
        entryPoints = ["websecure"]
        rule = "Host(`admin.suite.example.com`)"
        service = "admin-app"
        middlewares = ["chain-no-auth"]
      """)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      hit =
        Enum.find(tasks, fn t ->
          t.metadata["security_fingerprint"] =~ "deploy_audit:traefik_missing_oauth:"
        end)

      assert hit
      assert hit.priority == "critical"
      assert hit.metadata["router"] == "admin"
    end

    test "does NOT flag a well-formed protected route with chain-oauth2", %{roots: r} do
      write!(r.traefik, "admin_ok.toml", """
      [http.routers.admin]
        entryPoints = ["websecure"]
        rule = "Host(`admin.suite.example.com`)"
        service = "admin-app"
        middlewares = ["chain-oauth2"]
      """)

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end
  end

  # ── container probe ────────────────────────────────────────────────

  describe "run_scan/2 — container probe" do
    test "flags a .container file missing AutoUpdate=registry", %{roots: r} do
      write!(r.containers, "core-platform.container", """
      [Unit]
      Description=Core Platform

      [Container]
      Image=ghcr.io/example/core:latest
      PublishPort=127.0.0.1:4000:4000
      """)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      hit =
        Enum.find(tasks, fn t ->
          t.metadata["security_fingerprint"] =~ "deploy_audit:container_no_autoupdate:"
        end)

      assert hit
      assert hit.priority == "high"
      assert hit.metadata["container"] == "core-platform"
    end

    test "flags a .container file with a missing EnvironmentFile", %{roots: r} do
      write!(r.containers, "core-platform.container", """
      [Container]
      Image=ghcr.io/example/core:latest
      AutoUpdate=registry
      EnvironmentFile=/srv/dev/core-ops/absolutely-not-here.env
      """)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      hit =
        Enum.find(tasks, fn t ->
          t.metadata["security_fingerprint"] =~ "deploy_audit:container_missing_env_file:"
        end)

      assert hit
      assert hit.priority == "critical"
    end

    test "does NOT flag a well-formed container manifest", %{roots: r} do
      existing_env = write!(r.containers, "actual.env", "SOMETHING=1\n")

      write!(r.containers, "core-platform.container", """
      [Container]
      Image=ghcr.io/example/core:latest
      AutoUpdate=registry
      EnvironmentFile=#{existing_env}
      """)

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end
  end

  # ── env-var diff probe ───────────────────────────────────────────────

  describe "run_scan/2 — env-var diff probe" do
    test "flags an env var declared in .env.example but missing from secrets", %{roots: r} do
      write!(r.core_ops, "targets/moon-production/env/platform.shared.env.example", """
      # Required at boot
      REQUIRED_KEY=
      MEETING_GUEST_SIGNING_KEY=
      """)

      write!(r.core_ops, "secrets/moon-production/platform.secrets.env", """
      REQUIRED_KEY=abc
      """)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      hit =
        Enum.find(tasks, fn t ->
          t.metadata["security_fingerprint"] ==
            "deploy_audit:missing_env_var:moon-production:MEETING_GUEST_SIGNING_KEY"
        end)

      assert hit
      assert hit.priority == "high"
      assert hit.metadata["target"] == "moon-production"
      assert hit.metadata["env_var"] == "MEETING_GUEST_SIGNING_KEY"
      assert hit.title =~ "MEETING_GUEST_SIGNING_KEY"
      assert hit.description =~ "MEETING_GUEST_SIGNING_KEY"
    end

    test "does NOT flag when env keys match", %{roots: r} do
      write!(r.core_ops, "targets/moon-production/env/platform.shared.env.example", """
      REQUIRED_KEY=
      """)

      write!(r.core_ops, "secrets/moon-production/platform.secrets.env", """
      REQUIRED_KEY=abc
      """)

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end

    test "aggregates keys across multiple secrets files for the same target", %{roots: r} do
      write!(r.core_ops, "targets/moon-production/env/platform.shared.env.example", """
      SHARED_KEY=
      GUEST_KEY=
      """)

      write!(r.core_ops, "secrets/moon-production/platform.shared.env", """
      SHARED_KEY=one
      """)

      write!(r.core_ops, "secrets/moon-production/platform.secrets.env", """
      GUEST_KEY=two
      """)

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end
  end

  # ── TLS probe ────────────────────────────────────────────────────────

  describe "run_scan/2 — TLS probe" do
    test "returns {:ok, 0} + no crash when tls_root does not exist" do
      current = Application.get_env(:platform, Platform.Security, [])

      Application.put_env(
        :platform,
        Platform.Security,
        Keyword.put(
          current,
          :deploy_audit_tls_root,
          "/tmp/absolutely_no_letsencrypt_here_#{System.unique_integer([:positive])}"
        )
      )

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)
    end

    test "flags a cert whose mtime > 60 days ago (within 30-day expiry window)", %{roots: r} do
      cert_dir = Path.join(r.tls, "old.example.com")
      File.mkdir_p!(cert_dir)
      cert_path = Path.join(cert_dir, "cert.pem")
      File.write!(cert_path, "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")

      # Set mtime to 65 days ago so estimated expiry = mtime + 90d = 25d from now,
      # which is inside the default 30-day warning window.
      posix_65_days_ago = System.system_time(:second) - 65 * 24 * 3600
      File.touch!(cert_path, posix_65_days_ago)

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      tasks = list_deploy_tasks()

      hit =
        Enum.find(tasks, fn t ->
          t.metadata["security_fingerprint"] =~ "deploy_audit:tls_expiry:old.example.com"
        end)

      assert hit
      assert hit.priority == "high"
    end

    test "does NOT flag a fresh cert (mtime today)", %{roots: r} do
      cert_dir = Path.join(r.tls, "fresh.example.com")
      File.mkdir_p!(cert_dir)
      cert_path = Path.join(cert_dir, "cert.pem")
      File.write!(cert_path, "fake\n")

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end
  end

  # ── missing paths — dev workstation happy path ─────────────────────

  describe "run_scan/2 — missing filesystem roots" do
    test "returns {:ok, 0} + no crash when all four roots are absent" do
      current = Application.get_env(:platform, Platform.Security, [])

      Application.put_env(
        :platform,
        Platform.Security,
        current
        |> Keyword.put(:deploy_audit_traefik_root, "/tmp/nope_traefik_#{u()}")
        |> Keyword.put(:deploy_audit_containers_root, "/tmp/nope_containers_#{u()}")
        |> Keyword.put(:deploy_audit_core_ops_root, "/tmp/nope_core_ops_#{u()}")
        |> Keyword.put(:deploy_audit_tls_root, "/tmp/nope_tls_#{u()}")
      )

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert list_deploy_tasks() == []
    end
  end

  # ── config guardrails ───────────────────────────────────────────────

  describe "run_scan/2 — missing project_id" do
    test "returns {:ok, 0} + logs warn when project_id is not configured" do
      current = Application.get_env(:platform, Platform.Security, [])
      Application.put_env(:platform, Platform.Security, Keyword.delete(current, :project_id))

      log =
        capture_log(fn ->
          assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
        end)

      assert log =~ "no project_id configured"
      assert list_deploy_tasks() == []
    end
  end

  # ── dedup ────────────────────────────────────────────────────────────

  describe "run_scan/2 — dedup" do
    test "a second scan against the same fixture files 0 additional tasks", %{roots: r} do
      write!(r.core_ops, "targets/moon-production/env/platform.shared.env.example", """
      MEETING_GUEST_SIGNING_KEY=
      """)

      write!(r.core_ops, "secrets/moon-production/platform.secrets.env", "")

      capture_log(fn ->
        assert {:ok, 1} = DeployAudit.run_scan(%{}, %{})
      end)

      assert length(list_deploy_tasks()) == 1

      capture_log(fn ->
        assert {:ok, 0} = DeployAudit.run_scan(%{}, %{})
      end)

      assert length(list_deploy_tasks()) == 1
    end
  end

  defp u, do: System.unique_integer([:positive])

  # ── LLM enrichment seam (v2 stage 3) ───────────────────────────────────

  describe "run_scan/2 — LLM enrichment seam" do
    alias Platform.Test.SecurityEnrichmentHelper

    test "external agent pinned to security.deploy_audit enriches the finding", %{roots: r} do
      # Emit a container-missing-autoupdate finding.
      write!(r.containers, "core-platform.container", """
      [Unit]
      Description=Core Platform

      [Container]
      Image=ghcr.io/example/core:latest
      PublishPort=127.0.0.1:4000:4000
      """)

      _agent = SecurityEnrichmentHelper.install_llm_stub!("security.deploy_audit")

      SecurityEnrichmentHelper.plant_canned!(
        "Container drifts on security patches without AutoUpdate=registry",
        "high",
        [
          "Add AutoUpdate=registry to core-platform.container",
          "Enable podman-auto-update.timer"
        ]
      )

      capture_log(fn ->
        assert {:ok, filed} = DeployAudit.run_scan(%{}, %{})
        assert filed >= 1
      end)

      # At least one call — a fixture might produce > 1 finding, so
      # ≥ 1 not == 1 (env probe also runs).
      assert SecurityEnrichmentHelper.call_count() >= 1

      tasks = list_deploy_tasks()

      enriched =
        Enum.find(tasks, fn t -> t.metadata["security_enriched"] == true end)

      assert enriched
      assert enriched.description =~ "podman-auto-update.timer"
    end
  end
end
