defmodule Platform.Security.Scanners.CveScanTest do
  @moduledoc """
  Tests for `Platform.Security.Scanners.CveScan` (task
  `019f3e8e-4406` stage 3, ADR-0043).

  The scanner has three moving parts: lockfile discovery / parsing
  (covered separately in `LockfileParserTest`), the OSV batch query
  (mocked here via `Application.put_env(:platform,
  :cve_scan_osv_client, MockOsv)`), and the FindingFiler dispatch.
  This suite exercises the orchestration — severity filtering,
  fingerprint construction, dedup on second run, timeout handling.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Security.FindingFiler
  alias Platform.Security.Scanners.CveScan
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @fixture_root Path.expand("../../../support/fixtures/security", __DIR__)

  # ── mock OSV client ────────────────────────────────────────────────────

  defmodule MockOsv do
    @moduledoc false
    @behaviour Platform.Security.Scanners.CveScan.OsvClientBehaviour

    @impl true
    def query_batch(queries) do
      case Process.get(:mock_osv_response) do
        {:raise, err} -> raise err
        {:error, reason} -> {:error, reason}
        {:ok, results_fn} when is_function(results_fn, 1) -> {:ok, results_fn.(queries)}
        {:ok, results} -> {:ok, results}
        nil -> {:ok, Enum.map(queries, fn _ -> %{"vulns" => []} end)}
      end
    end
  end

  # ── setup ────────────────────────────────────────────────────────────

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
      |> Keyword.put_new(:cve_scan_stale_days, 30)
    )

    Application.put_env(:platform, :cve_scan_osv_client, MockOsv)

    on_exit(fn ->
      current = Application.get_env(:platform, Platform.Security, [])

      restored =
        if is_nil(prev_project_id) do
          Keyword.delete(current, :project_id)
        else
          Keyword.put(current, :project_id, prev_project_id)
        end

      Application.put_env(:platform, Platform.Security, restored)
      Application.delete_env(:platform, :cve_scan_osv_client)
      Application.delete_env(:platform, :security_scanner_repo_root)
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
      Platform.TestTemp.mkdir!("cve_scan_test")

    for {rel, contents} <- files do
      abs = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, contents)
    end

    Application.put_env(:platform, :security_scanner_repo_root, root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp fixture!(name), do: File.read!(Path.join(@fixture_root, name))

  defp osv_results(vulns_by_pkg) when is_map(vulns_by_pkg) do
    fn queries ->
      Enum.map(queries, fn %{package: %{name: name}} ->
        %{"vulns" => Map.get(vulns_by_pkg, name, [])}
      end)
    end
  end

  defp count_tasks do
    Platform.Repo.aggregate(TaskSchema, :count, :id)
  end

  # ── happy paths ────────────────────────────────────────────────────────

  describe "run_scan/2 — critical / high" do
    test "files one task per critical vuln with priority=critical + correct fingerprint" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-testcritical",
               "aliases" => ["CVE-2024-11111"],
               "summary" => "Critical RCE in plug",
               "database_specific" => %{"severity" => "CRITICAL"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [
                     %{"events" => [%{"introduced" => "0"}, %{"fixed" => "1.14.1"}]}
                   ]
                 }
               ]
             }
           ]
         })}
      )

      pre = count_tasks()

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{scanned_at: DateTime.utc_now()})
      end)

      assert count_tasks() == pre + 1

      [task] = list_cve_tasks()
      assert task.priority == "critical"
      assert task.status == "backlog"

      assert task.title ==
               "[security:security.cve_scan] CVE CVE-2024-11111 in plug 1.14.0 (severity: critical)"

      assert task.metadata["security_fingerprint"] == "cve:CVE-2024-11111:plug:1.14.0"
      assert task.metadata["security_scanner"] == "security.cve_scan"
      assert task.metadata["cve_id"] == "CVE-2024-11111"
      assert task.metadata["fixed_version"] == "1.14.1"
      assert task.description =~ "1.14.1"
      assert task.description =~ "mix deps.update plug"
    end

    test "files a high-priority task for a CVSS 7.5 vuln with no database_specific severity" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-highplug",
               "aliases" => ["CVE-2024-22222"],
               "summary" => "High-severity issue",
               "severity" => [%{"type" => "CVSS_V3", "score" => "7.5"}],
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.15.0"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      [task] = list_cve_tasks()
      assert task.priority == "high"
      assert task.metadata["security_severity"] == "high"
    end
  end

  # ── severity filtering ──────────────────────────────────────────────────

  describe "run_scan/2 — severity filter" do
    test "medium severity with a fixed version is skipped by default" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-mediumplug",
               "aliases" => ["CVE-2024-33333"],
               "database_specific" => %{"severity" => "MEDIUM"},
               "modified" => "2024-06-01T00:00:00Z",
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.5"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 0} = CveScan.run_scan(%{}, %{})
      end)

      assert list_cve_tasks() == []
    end

    test "low severity without a fix, modified > 30 days ago, DOES file a task" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      stale_modified =
        DateTime.utc_now()
        |> DateTime.add(-60 * 24 * 3600, :second)
        |> DateTime.to_iso8601()

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-staleplug",
               "aliases" => ["CVE-2024-44444"],
               "database_specific" => %{"severity" => "LOW"},
               "modified" => stale_modified,
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"introduced" => "0"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      [task] = list_cve_tasks()
      assert task.priority == "low"
    end

    test "low severity with a recent modified date is skipped" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      recent_modified =
        DateTime.utc_now()
        |> DateTime.add(-3 * 24 * 3600, :second)
        |> DateTime.to_iso8601()

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-recentlow",
               "aliases" => ["CVE-2024-55555"],
               "database_specific" => %{"severity" => "LOW"},
               "modified" => recent_modified,
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"introduced" => "0"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 0} = CveScan.run_scan(%{}, %{})
      end)
    end
  end

  # ── empty / no-lockfile paths ──────────────────────────────────────────

  describe "run_scan/2 — empty / no lockfiles" do
    test "an empty repo returns {:ok, 0}" do
      install_repo_root!(%{})

      capture_log(fn ->
        assert {:ok, 0} = CveScan.run_scan(%{}, %{})
      end)

      assert list_cve_tasks() == []
    end

    test "a lockfile with zero hex entries returns {:ok, 0} without hitting OSV" do
      install_repo_root!(%{"mix.lock" => "%{}\n"})

      Process.put(
        :mock_osv_response,
        {:raise, RuntimeError.exception("OSV must not be called for an empty lockfile")}
      )

      capture_log(fn ->
        assert {:ok, 0} = CveScan.run_scan(%{}, %{})
      end)
    end
  end

  # ── transport errors ───────────────────────────────────────────────────

  describe "run_scan/2 — OSV transport / timeout" do
    test "an OSV {:error, reason} return does NOT crash the scanner — logs + returns {:ok, 0}" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(:mock_osv_response, {:error, :timeout})

      log =
        capture_log(fn ->
          assert {:ok, 0} = CveScan.run_scan(%{}, %{})
        end)

      assert log =~ "OSV query failed"
      assert list_cve_tasks() == []
    end

    test "an OSV client raise is caught by the scanner's rescue guard" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(:mock_osv_response, {:raise, RuntimeError.exception("boom from mock")})

      log =
        capture_log(fn ->
          assert {:ok, 0} = CveScan.run_scan(%{}, %{})
        end)

      assert log =~ "scanner raised" or log =~ "boom from mock"
    end
  end

  # ── dedup ──────────────────────────────────────────────────────────────

  describe "run_scan/2 — dedup" do
    test "a second run with the same lockfile + response files 0 additional tasks" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-dedupplug",
               "aliases" => ["CVE-2024-66666"],
               "database_specific" => %{"severity" => "CRITICAL"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.1"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      assert length(list_cve_tasks()) == 1

      # Second run — same fingerprint, dedup hits + no new task row.
      capture_log(fn ->
        assert {:ok, 0} = CveScan.run_scan(%{}, %{})
      end)

      assert length(list_cve_tasks()) == 1
    end
  end

  # ── config guardrails ─────────────────────────────────────────────────

  describe "run_scan/2 — missing project_id" do
    test "returns {:ok, 0} + logs warn when project_id is not configured" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      current = Application.get_env(:platform, Platform.Security, [])
      Application.put_env(:platform, Platform.Security, Keyword.delete(current, :project_id))

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-noproject",
               "aliases" => ["CVE-2024-77777"],
               "database_specific" => %{"severity" => "CRITICAL"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.1"}]}]
                 }
               ]
             }
           ]
         })}
      )

      log =
        capture_log(fn ->
          assert {:ok, 0} = CveScan.run_scan(%{}, %{})
        end)

      assert log =~ "no project_id configured"
    end
  end

  # ── multi-ecosystem coverage ──────────────────────────────────────────

  describe "run_scan/2 — multi-ecosystem" do
    test "a mixed mix.lock + package-lock.json + Cargo.lock all get queried" do
      install_repo_root!(%{
        "mix.lock" => fixture!("mix.lock.critical"),
        "assets/package-lock.json" => fixture!("package-lock.json.high"),
        "Cargo.lock" => fixture!("Cargo.lock.medium")
      })

      # Assert the mock sees queries from all three ecosystems.
      Process.put(:seen_query_test_pid, self())

      Process.put(
        :mock_osv_response,
        {:ok,
         fn queries ->
           send(Process.get(:seen_query_test_pid), {:cve_scan_queries, queries})

           Enum.map(queries, fn q ->
             cond do
               q[:package][:name] == "lodash" ->
                 %{
                   "vulns" => [
                     %{
                       "id" => "GHSA-lodash",
                       "aliases" => ["CVE-2024-88888"],
                       "database_specific" => %{"severity" => "HIGH"},
                       "affected" => [
                         %{
                           "package" => %{"name" => "lodash", "ecosystem" => "npm"},
                           "ranges" => [%{"events" => [%{"fixed" => "4.17.21"}]}]
                         }
                       ]
                     }
                   ]
                 }

               true ->
                 %{"vulns" => []}
             end
           end)
         end}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      assert_receive {:cve_scan_queries, queries}
      ecosystems = queries |> Enum.map(& &1.package.ecosystem) |> Enum.uniq() |> Enum.sort()
      assert "Hex" in ecosystems
      assert "npm" in ecosystems
      assert "crates.io" in ecosystems

      [task] = list_cve_tasks()
      assert task.metadata["package"] == "lodash"
      assert task.metadata["ecosystem"] == "npm"
    end
  end

  # ── FindingFiler contract cross-check ──────────────────────────────────

  describe "run_scan/2 — FindingFiler contract" do
    test "the scanner emits the same shape FindingFiler consumes directly" do
      # Build a finding via the scanner path and via a direct call
      # to FindingFiler and confirm the observable task shape matches
      # (defense against a refactor that silently breaks the contract).
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-contract",
               "aliases" => ["CVE-2024-99999"],
               "database_specific" => %{"severity" => "CRITICAL"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.1"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      [scanner_task] = list_cve_tasks()

      # Delete the scanner-filed task and re-file via the shim to
      # compare shapes.
      {:ok, _} = Tasks.soft_delete_task(scanner_task)

      project_id =
        Application.get_env(:platform, Platform.Security)
        |> Keyword.fetch!(:project_id)

      finding = %{
        scanner_key: "security.cve_scan",
        severity: :critical,
        title: "CVE CVE-2024-99999 in plug 1.14.0 (severity: critical)",
        description: "manual",
        fingerprint: "cve:CVE-2024-99999:plug:1.14.0",
        project_id: project_id
      }

      assert {:ok, direct_task} = FindingFiler.file_finding(finding)

      # Same title, priority, labels, fingerprint.
      assert direct_task.title == scanner_task.title
      assert direct_task.priority == scanner_task.priority
      assert direct_task.metadata["security_scanner"] == scanner_task.metadata["security_scanner"]

      assert direct_task.metadata["security_fingerprint"] ==
               scanner_task.metadata["security_fingerprint"]

      assert direct_task.metadata["security_labels"] == scanner_task.metadata["security_labels"]
    end
  end

  # ── LLM enrichment seam (v2 stage 3) ───────────────────────────────────

  describe "run_scan/2 — LLM enrichment seam" do
    alias Platform.Test.SecurityEnrichmentHelper

    test "when an external agent is pinned to security.cve_scan, the finding is enriched" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      # Pin an external-runtime agent + plant a canned LLM response.
      _agent = SecurityEnrichmentHelper.install_llm_stub!("security.cve_scan")

      SecurityEnrichmentHelper.plant_canned!(
        "Enriched: RCE in plug 1.14.0 exposed at HTTP layer",
        "critical",
        ["mix deps.update plug", "mix test", "redeploy"]
      )

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-enrich",
               "aliases" => ["CVE-2024-77778"],
               "database_specific" => %{"severity" => "HIGH"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.1"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      # LLM was called exactly once (one finding → one enrichment).
      assert SecurityEnrichmentHelper.call_count() == 1

      [task] = list_cve_tasks()
      # Enrichment metadata is present.
      assert task.metadata["security_enriched"] == true

      assert task.metadata["security_enrichment_summary"] ==
               "Enriched: RCE in plug 1.14.0 exposed at HTTP layer"

      assert task.metadata["security_enrichment_priority"] == "critical"

      # Priority was upgraded high → critical via the LLM's judgment.
      assert task.priority == "critical"

      # Enriched description carries the summary + remediation.
      assert task.description =~ "Security Guard summary"
      assert task.description =~ "mix deps.update plug"
    end

    test "when no agent is pinned, the finding files with the raw scanner shape" do
      install_repo_root!(%{"mix.lock" => fixture!("mix.lock.critical")})

      Process.put(
        :mock_osv_response,
        {:ok,
         osv_results(%{
           "plug" => [
             %{
               "id" => "GHSA-noenrich",
               "aliases" => ["CVE-2024-88889"],
               "database_specific" => %{"severity" => "CRITICAL"},
               "affected" => [
                 %{
                   "package" => %{"name" => "plug", "ecosystem" => "Hex"},
                   "ranges" => [%{"events" => [%{"fixed" => "1.14.1"}]}]
                 }
               ]
             }
           ]
         })}
      )

      capture_log(fn ->
        assert {:ok, 1} = CveScan.run_scan(%{}, %{})
      end)

      [task] = list_cve_tasks()
      # No enrichment metadata — the noop path preserved the v1 shape.
      refute Map.has_key?(task.metadata, "security_enriched")
      refute Map.has_key?(task.metadata, "security_enrichment_summary")
    end
  end

  # ── helper ────────────────────────────────────────────────────────────

  defp list_cve_tasks do
    Platform.Repo.all(TaskSchema)
    |> Enum.filter(fn task ->
      case task.metadata do
        %{"security_scanner" => "security.cve_scan"} -> is_nil(task.deleted_at)
        _ -> false
      end
    end)
  end
end
