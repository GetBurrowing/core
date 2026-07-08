defmodule Platform.Security.FindingFilerTest do
  @moduledoc """
  Tests for `Platform.Security.FindingFiler` (task `019f3e8e-4406`
  stage 2, ADR-0043).

  Stage-2 scope for the shim body:

    * `file_finding/1` creates a Suite task with the ADR-0043
      title convention + severity → priority mapping + metadata
      carrying the scanner fingerprint.
    * The dedup gate returns `{:error, :duplicate_fingerprint}`
      when a non-deleted task already carries the same
      `metadata["security_fingerprint"]`.

  Stage 5 folds in `file_findings/1` (plural) with the digest rule.
  """
  use Platform.DataCase, async: false

  alias Platform.Security.FindingFiler
  alias Platform.Tasks
  alias Platform.Tasks.Task

  defp create_security_project! do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Security Project #{suffix}"})
    project
  end

  defp base_finding(project_id, overrides \\ %{}) do
    Map.merge(
      %{
        scanner_key: "security.cve_scan",
        severity: :critical,
        title: "CVE-2024-1234 in plug 1.14.0",
        description: "Advisory: https://example.test",
        fingerprint: "cve:CVE-2024-1234:plug:1.14.0",
        project_id: project_id
      },
      overrides
    )
  end

  describe "file_finding/1 — happy path" do
    test "creates a task with the ADR-0043 title prefix + severity → priority mapping" do
      project = create_security_project!()
      finding = base_finding(project.id)

      assert {:ok, %Task{} = task} = FindingFiler.file_finding(finding)

      assert task.title ==
               "[security:security.cve_scan] CVE-2024-1234 in plug 1.14.0"

      assert task.priority == "critical"
      assert task.status == "backlog"
      assert task.description == "Advisory: https://example.test"
      assert task.project_id == project.id
    end

    test "carries the fingerprint + scanner + labels in metadata" do
      project = create_security_project!()
      finding = base_finding(project.id)

      assert {:ok, %Task{metadata: meta}} = FindingFiler.file_finding(finding)

      assert meta["security_fingerprint"] == "cve:CVE-2024-1234:plug:1.14.0"
      assert meta["security_scanner"] == "security.cve_scan"
      assert meta["security_severity"] == "critical"
      assert meta["security_labels"] == ["security-finding", "security.cve_scan"]
    end

    test "maps each severity to the matching priority string" do
      project = create_security_project!()

      severity_pairs = [
        {:critical, "critical"},
        {:high, "high"},
        {:medium, "medium"},
        {:low, "low"}
      ]

      for {severity, priority} <- severity_pairs do
        finding =
          base_finding(project.id, %{
            severity: severity,
            fingerprint: "test:sev:#{severity}"
          })

        assert {:ok, %Task{priority: ^priority}} = FindingFiler.file_finding(finding)
      end
    end

    test "sponsor_user_id passes through when supplied and stays nil otherwise" do
      project = create_security_project!()

      finding = base_finding(project.id)
      assert {:ok, %Task{sponsor_user_id: nil}} = FindingFiler.file_finding(finding)
    end

    test "extra caller-supplied metadata merges into the task metadata" do
      project = create_security_project!()

      finding =
        base_finding(project.id, %{
          fingerprint: "test:meta:merge",
          metadata: %{"upstream_url" => "https://osv.dev/vuln/CVE-2024-1234"}
        })

      assert {:ok, %Task{metadata: meta}} = FindingFiler.file_finding(finding)

      assert meta["upstream_url"] == "https://osv.dev/vuln/CVE-2024-1234"
      # Canonical keys still win over caller-supplied metadata.
      assert meta["security_fingerprint"] == "test:meta:merge"
      assert meta["security_scanner"] == "security.cve_scan"
    end
  end

  describe "file_finding/1 — dedup gate" do
    test "the second file_finding/1 with the same fingerprint returns :duplicate_fingerprint" do
      project = create_security_project!()
      finding = base_finding(project.id, %{fingerprint: "test:dedup:same"})

      assert {:ok, %Task{}} = FindingFiler.file_finding(finding)
      assert {:error, :duplicate_fingerprint} = FindingFiler.file_finding(finding)
    end

    test "different fingerprints don't collide" do
      project = create_security_project!()

      f1 = base_finding(project.id, %{fingerprint: "test:dedup:one"})
      f2 = base_finding(project.id, %{fingerprint: "test:dedup:two"})

      assert {:ok, %Task{}} = FindingFiler.file_finding(f1)
      assert {:ok, %Task{}} = FindingFiler.file_finding(f2)
    end

    test "the dedup gate ignores soft-deleted tasks" do
      project = create_security_project!()

      finding = base_finding(project.id, %{fingerprint: "test:dedup:softdelete"})

      assert {:ok, task} = FindingFiler.file_finding(finding)
      {:ok, _} = Tasks.soft_delete_task(task)

      # After soft delete, the same fingerprint files a new task.
      assert {:ok, %Task{}} = FindingFiler.file_finding(finding)
    end
  end

  describe "file_finding/1 — required-key validation" do
    test "missing scanner_key returns {:error, {:missing_key, :scanner_key}}" do
      project = create_security_project!()
      finding = project.id |> base_finding() |> Map.delete(:scanner_key)

      assert {:error, {:missing_key, :scanner_key}} = FindingFiler.file_finding(finding)
    end

    test "missing fingerprint returns {:error, {:missing_key, :fingerprint}}" do
      project = create_security_project!()
      finding = project.id |> base_finding() |> Map.delete(:fingerprint)

      assert {:error, {:missing_key, :fingerprint}} = FindingFiler.file_finding(finding)
    end

    test "missing project_id returns {:error, {:missing_key, :project_id}}" do
      project = create_security_project!()
      finding = project.id |> base_finding() |> Map.delete(:project_id)

      assert {:error, {:missing_key, :project_id}} = FindingFiler.file_finding(finding)
    end

    test "missing severity returns {:error, {:missing_key, :severity}}" do
      project = create_security_project!()
      finding = project.id |> base_finding() |> Map.delete(:severity)

      assert {:error, {:missing_key, :severity}} = FindingFiler.file_finding(finding)
    end

    test "missing title returns {:error, {:missing_key, :title}}" do
      project = create_security_project!()
      finding = project.id |> base_finding() |> Map.delete(:title)

      assert {:error, {:missing_key, :title}} = FindingFiler.file_finding(finding)
    end
  end
end
