defmodule Platform.ArtifactsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Platform.Artifacts
  alias Platform.Context
  alias Platform.Execution

  defmodule SuccessfulDestination do
    @behaviour Platform.Artifacts.Destination

    @impl true
    def id, do: :preview_route

    @impl true
    def publish(artifact, opts) do
      {:ok,
       %{
         "external_ref" => Keyword.get(opts, :external_ref, "preview://#{artifact.id}"),
         "destination_path" => Keyword.get(opts, :destination_path, "/preview/#{artifact.id}")
       }}
    end
  end

  defmodule FailingDestination do
    @behaviour Platform.Artifacts.Destination

    @impl true
    def id, do: :canvas

    @impl true
    def publish(_artifact, _opts), do: {:error, :canvas_offline}
  end

  describe "register_execution_artifact/2" do
    test "registers a run-scoped artifact and mirrors an artifact_ref into context" do
      %{project_id: project_id, epic_id: epic_id, task_id: task_id, run_id: run_id} = ids = unique_ids()

      assert {:ok, _run} =
               Execution.start_run(task_id,
                 run_id: run_id,
                 project_id: project_id,
                 epic_id: epic_id
               )

      on_exit(fn -> _ = Execution.stop_run(run_id) end)

      assert {:ok, artifact} =
               Execution.register_artifact(run_id,
                 kind: :file,
                 name: "verify.txt",
                 locator: %{path: "/tmp/#{run_id}/verify.txt"},
                 content_type: "text/plain",
                 byte_size: 42,
                 metadata: %{phase: "verify"}
               )

      artifact_id = artifact.id

      assert artifact.task_id == task_id
      assert artifact.run_id == run_id
      assert artifact.source == :execution
      assert [%{id: ^artifact_id}] = Artifacts.list_artifacts(task_id: task_id, run_id: run_id)

      assert {:ok, snapshot} = Context.snapshot(ids)

      artifact_item = Enum.find(snapshot.items, &(&1.key == "artifact:#{artifact.id}"))
      assert artifact_item.kind == :artifact_ref
      assert artifact_item.value["artifact_id"] == artifact.id
      assert artifact_item.value["latest_publication"] == nil
    end
  end

  describe "publish_artifact/3" do
    test "records failed and successful publication attempts in append-only order" do
      %{project_id: project_id, epic_id: epic_id, task_id: task_id, run_id: run_id} = unique_ids()

      assert {:ok, _run} =
               Execution.start_run(task_id,
                 run_id: run_id,
                 project_id: project_id,
                 epic_id: epic_id
               )

      on_exit(fn -> _ = Execution.stop_run(run_id) end)

      assert {:ok, artifact} =
               Artifacts.register_artifact(%{
                 project_id: project_id,
                 epic_id: epic_id,
                 task_id: task_id,
                 run_id: run_id,
                 source: :execution,
                 kind: :document,
                 name: "summary.md",
                 locator: %{path: "/tmp/#{run_id}/summary.md"}
               })

      assert {:error, :canvas_offline, failed_publication} =
               Artifacts.publish_artifact(artifact.id, FailingDestination)

      assert failed_publication.status == :failed
      assert failed_publication.attempt == 1
      assert failed_publication.destination == :canvas

      assert {:ok, updated_artifact, successful_publication} =
               Artifacts.publish_artifact(artifact.id, SuccessfulDestination,
                 external_ref: "preview://artifact/#{artifact.id}"
               )

      assert successful_publication.status == :published
      assert successful_publication.attempt == 2
      assert successful_publication.destination == :preview_route
      assert successful_publication.external_ref == "preview://artifact/#{artifact.id}"

      assert updated_artifact.latest_publication["status"] == "published"
      assert updated_artifact.latest_publication["destination"] == "preview_route"

      assert [first, second] = Artifacts.list_publications(artifact.id)
      assert first.status == :failed
      assert second.status == :published

      assert {:ok, snapshot} =
               Context.snapshot(%{
                 project_id: project_id,
                 epic_id: epic_id,
                 task_id: task_id,
                 run_id: run_id
               })

      artifact_item = Enum.find(snapshot.items, &(&1.key == "artifact:#{artifact.id}"))
      assert artifact_item.value["latest_publication"]["status"] == "published"
      assert artifact_item.value["latest_publication"]["external_ref"] == "preview://artifact/#{artifact.id}"
    end

    test "built-in destination ids resolve through the shared registry and record failure history" do
      task_id = unique_id("task")

      assert {:ok, artifact} =
               Artifacts.register_artifact(%{
                 task_id: task_id,
                 source: :canvas,
                 kind: :canvas,
                 name: "retrospective board",
                 locator: %{canvas_id: unique_id("canvas")}
               })

      assert {:error, {:unconfigured_destination, :github}, publication} =
               Artifacts.publish_artifact(artifact, :github)

      assert publication.destination == :github
      assert publication.status == :failed
      assert publication.attempt == 1
      assert hd(Artifacts.list_publications(artifact.id)).destination == :github
    end
  end

  describe "register_artifact/1" do
    test "accepts non-run chat/canvas artifacts without requiring execution context" do
      task_id = unique_id("task")
      canvas_id = unique_id("canvas")

      assert {:ok, artifact} =
               Artifacts.register_artifact(%{
                 task_id: task_id,
                 source: :canvas,
                 kind: :canvas,
                 name: "live roadmap",
                 locator: %{canvas_id: canvas_id},
                 metadata: %{space: "startup-suite"}
               })

      artifact_id = artifact.id

      assert artifact.run_id == nil
      assert artifact.source == :canvas
      assert [%{id: ^artifact_id}] = Artifacts.list_artifacts(task_id: task_id, source: :canvas)
    end
  end

  defp unique_ids do
    %{
      project_id: unique_id("proj"),
      epic_id: unique_id("epic"),
      task_id: unique_id("task"),
      run_id: unique_id("run")
    }
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
