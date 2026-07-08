defmodule Platform.Security.FindingFilerDigestTest do
  @moduledoc """
  Tests for the `Platform.Security.FindingFiler.file_findings/1` batch
  path added in task `019f3e8e-4406` stage 5.

  The batch path collapses runs > `finding_digest_threshold` into a
  single weekly-digest task instead of N per-finding rows. Below the
  threshold, delegates to the existing per-finding `file_finding/1`
  path (already covered by `finding_filer_test.exs`).
  """
  use Platform.DataCase, async: false

  alias Platform.Security.FindingFiler
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    prev = Application.get_env(:platform, Platform.Security)

    Application.put_env(
      :platform,
      Platform.Security,
      Keyword.merge(prev || [], finding_digest_threshold: 10)
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, Platform.Security, prev)
      else
        Application.delete_env(:platform, Platform.Security)
      end
    end)

    :ok
  end

  defp create_security_project! do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Security Digest Project #{suffix}"})
    project
  end

  defp build_findings(project_id, count, scanner_key \\ "security.secret_leak") do
    for n <- 1..count do
      %{
        scanner_key: scanner_key,
        severity: severity_for(n),
        title: "Finding ##{n}",
        description: "Body of finding ##{n}",
        fingerprint: "test:digest:#{scanner_key}:#{n}",
        project_id: project_id,
        suggested_fix: "Fix number #{n}"
      }
    end
  end

  defp severity_for(n) when rem(n, 4) == 0, do: :critical
  defp severity_for(n) when rem(n, 4) == 1, do: :high
  defp severity_for(n) when rem(n, 4) == 2, do: :medium
  defp severity_for(_), do: :low

  describe "file_findings/1 — below threshold (≤ 10)" do
    test "files each finding individually and returns the count" do
      project = create_security_project!()
      findings = build_findings(project.id, 5)

      before = Tasks.list_tasks_by_project(project.id) |> length()
      count = FindingFiler.file_findings(findings)
      after_count = Tasks.list_tasks_by_project(project.id) |> length()

      assert count == 5
      assert after_count - before == 5

      # Every task's title uses the per-finding shape (no digest prefix).
      tasks = Tasks.list_tasks_by_project(project.id)
      assert Enum.all?(tasks, fn t -> String.contains?(t.title, "Finding #") end)
      refute Enum.any?(tasks, fn t -> String.contains?(t.title, "Weekly digest") end)
    end

    test "empty batch is a no-op" do
      count = FindingFiler.file_findings([])
      assert count == 0
    end

    test "at exactly the threshold, still files individually" do
      project = create_security_project!()
      findings = build_findings(project.id, 10)

      count = FindingFiler.file_findings(findings)
      assert count == 10

      tasks = Tasks.list_tasks_by_project(project.id)
      refute Enum.any?(tasks, fn t -> String.contains?(t.title, "Weekly digest") end)
    end
  end

  describe "file_findings/1 — above threshold (> 10)" do
    test "files ONE digest task with a markdown table containing every finding" do
      project = create_security_project!()
      findings = build_findings(project.id, 15)

      before = Tasks.list_tasks_by_project(project.id) |> length()
      count = FindingFiler.file_findings(findings)
      after_count = Tasks.list_tasks_by_project(project.id) |> length()

      assert count == 1
      assert after_count - before == 1

      [digest] = Tasks.list_tasks_by_project(project.id)
      assert digest.title =~ ~r/Weekly digest — 15 findings/

      # The description carries a markdown table with every finding.
      assert digest.description =~ "| Severity | Title | Fingerprint | Suggested fix |"

      # Every finding's title should appear in the digest description.
      for n <- 1..15 do
        assert digest.description =~ "Finding ##{n}"
      end
    end

    test "digest fingerprint is week-bucketed and dedups within the ISO week" do
      project = create_security_project!()

      # First batch of 15 → 1 digest task
      count1 = FindingFiler.file_findings(build_findings(project.id, 15))
      assert count1 == 1

      # Second batch of 15 (different fingerprints, same scanner + week)
      # → 0 additional tasks because the digest fingerprint collides.
      more_findings =
        for n <- 100..114 do
          %{
            scanner_key: "security.secret_leak",
            severity: :high,
            title: "Later finding ##{n}",
            description: "Body #{n}",
            fingerprint: "test:digest:security.secret_leak:#{n}",
            project_id: project.id,
            suggested_fix: "Fix #{n}"
          }
        end

      count2 = FindingFiler.file_findings(more_findings)
      assert count2 == 0

      # Exactly one digest task total.
      digests =
        Tasks.list_tasks_by_project(project.id)
        |> Enum.filter(&String.contains?(&1.title, "Weekly digest"))

      assert length(digests) == 1
    end

    test "digest task carries the digest fingerprint in metadata" do
      project = create_security_project!()
      FindingFiler.file_findings(build_findings(project.id, 12))

      [digest] = Tasks.list_tasks_by_project(project.id)

      assert digest.metadata["security_fingerprint"] =~
               ~r/^digest:security\.secret_leak:\d{4}-W\d{2}$/

      assert digest.metadata["digest_scanner_key"] == "security.secret_leak"
      assert digest.metadata["digest_count"] == 12
    end

    test "digest severity is the highest severity in the batch" do
      project = create_security_project!()

      # 12 medium + 1 critical → digest priority "critical"
      findings =
        for n <- 1..11 do
          %{
            scanner_key: "security.secret_leak",
            severity: :medium,
            title: "Med #{n}",
            fingerprint: "test:sev:med:#{n}",
            project_id: project.id
          }
        end

      critical_finding = %{
        scanner_key: "security.secret_leak",
        severity: :critical,
        title: "Critical worst",
        fingerprint: "test:sev:crit:1",
        project_id: project.id
      }

      FindingFiler.file_findings([critical_finding | findings])

      [%Task{} = digest] = Tasks.list_tasks_by_project(project.id)
      assert digest.priority == "critical"
    end
  end

  describe "file_findings/1 — mixed scanner_keys" do
    test "batches split by scanner_key and each sub-batch decides digest independently" do
      project = create_security_project!()

      secrets = build_findings(project.id, 15, "security.secret_leak")
      cves = build_findings(project.id, 5, "security.cve_scan")

      total = FindingFiler.file_findings(secrets ++ cves)

      # 1 digest for secrets (15 > 10) + 5 per-finding for CVE (5 ≤ 10).
      assert total == 6

      tasks = Tasks.list_tasks_by_project(project.id)
      digests = Enum.filter(tasks, &String.contains?(&1.title, "Weekly digest"))
      per_finding = tasks -- digests

      assert length(digests) == 1
      assert length(per_finding) == 5
    end
  end

  describe "list_tasks_by_metadata_key/2 helper" do
    test "returns tasks whose metadata->>key matches value" do
      project = create_security_project!()

      finding = %{
        scanner_key: "security.cve_scan",
        severity: :critical,
        title: "Test",
        fingerprint: "test:jsonb:one",
        project_id: project.id
      }

      {:ok, task} = FindingFiler.file_finding(finding)

      # Direct helper call finds the task by its fingerprint.
      assert [%Task{id: id}] =
               Tasks.list_tasks_by_metadata_key("security_fingerprint", "test:jsonb:one")

      assert id == task.id
    end

    test "returns [] for a fingerprint no task carries" do
      assert [] =
               Tasks.list_tasks_by_metadata_key(
                 "security_fingerprint",
                 "cve:nothing-yet:pkg:0.0.0"
               )
    end

    test "excludes soft-deleted tasks" do
      project = create_security_project!()

      finding = %{
        scanner_key: "security.cve_scan",
        severity: :critical,
        title: "Test",
        fingerprint: "test:jsonb:softdelete",
        project_id: project.id
      }

      {:ok, task} = FindingFiler.file_finding(finding)
      {:ok, _} = Tasks.soft_delete_task(task)

      assert [] =
               Tasks.list_tasks_by_metadata_key("security_fingerprint", "test:jsonb:softdelete")
    end
  end
end
