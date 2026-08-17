defmodule Platform.Files.HTMLBackfillTest do
  @moduledoc """
  Outcome tests for the HTML re-ingest backfill (task 019ff1ab stage 3).

  "The backfill ran" proves nothing, so every assertion here is about
  the state of a seeded row afterwards. The positive case (an HTML row
  held back at `human_only` ends up with extracted prose and no script
  body) is paired in the SAME test with a negative control whose
  `content_type` the dispatch table does not cover: without it, a
  backfill that indiscriminately re-ingested everything would pass.
  """

  use Platform.DataCase, async: false

  alias Platform.Files
  alias Platform.Files.HTMLBackfill
  alias Platform.Repo
  alias Platform.Tasks

  @html """
  <html>
    <head>
      <style>.zz-style-backfill-sentinel { color: red; }</style>
      <script>function zzScriptBackfillSentinel() { alert("x"); }</script>
    </head>
    <body>
      <h1>Orion Technical Stack</h1>
      <p>The prose a search index should actually contain.</p>
    </body>
  </html>
  """

  defmodule BackfillProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config), do: {:ok, length(entries)}
    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  defmodule SlowProvider do
    @moduledoc """
    Stands in for the seam a unit test cannot reach directly: the mix
    task halting the VM the instant `run/1` returns. Whatever this
    provider is still sleeping through at that moment is work that would
    have been killed. 200ms is far longer than the async spawn hop, so
    "the row is ingested the microsecond run/1 returned" can only be
    true if the caller actually waited.
    """
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      Process.sleep(200)
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  defmodule FailingProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:error, :provider_unavailable}
    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: BackfillProvider)

    root =
      Platform.TestTemp.path("platform-html-backfill-test")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, project} = Tasks.create_project(%{name: "HTML Backfill #{System.unique_integer()}"})

    {:ok, project: project, root: root}
  end

  describe "measure/1" do
    test "counts the population and reports every bucket before anything changes", ctx do
      held = seed(ctx, "held.html", "text/html", @html) |> hold_back()
      opaque = seed(ctx, "opaque.html", "application/octet-stream", @html)

      report = HTMLBackfill.measure(project_id: ctx.project.id)

      assert report.scanned == 2
      assert report.covered == 1
      assert report.candidates == [held.id]
      assert report.skipped_uncovered_content_type == %{"application/octet-stream" => 1}
      assert report.changed == 0

      # Measuring must not have moved the row it named.
      assert Files.get_file(held.id).ingest_intent == "human_only"
      assert Files.fetch_extracted_text(opaque.id) == nil

      # A run that reports nothing is indistinguishable from a run that
      # found nothing, so the zero buckets are printed too.
      rendered = HTMLBackfill.format_report(report)
      assert rendered =~ "content type not covered by the extractor): application/octet-stream=1"
      assert rendered =~ "left unchanged (soft-deleted): 0"
      assert rendered =~ "re-ingested (extracted and indexed): 0"
      assert rendered =~ "retried after being stranded at pending: 0"
    end
  end

  describe "run/1" do
    test "extracts the covered HTML row and leaves the uncovered control untouched", ctx do
      held = seed(ctx, "held.html", "text/html", @html) |> hold_back()
      opaque = seed(ctx, "opaque.html", "application/octet-stream", @html)
      plain = seed(ctx, "notes.txt", "text/plain", "plain prose that was already fine")

      :ok = Platform.Files.Ingester.ingest_async(plain)
      assert wait_for_status(plain.id, "ingested")
      plain_before = snapshot(plain.id)
      opaque_before = snapshot(opaque.id)

      report = HTMLBackfill.run(project_id: ctx.project.id)

      assert report.changed == 1
      assert report.errors == []

      # ── Positive: the held-back HTML row now has structure-preserving text.
      assert wait_for_status(held.id, "ingested")
      refreshed = Files.get_file(held.id)
      assert refreshed.ingest_intent == "attempt"

      text = Files.fetch_extracted_text(held.id).text
      assert text =~ "# Orion Technical Stack"
      assert text =~ "The prose a search index should actually contain."
      refute text =~ "zzScriptBackfillSentinel"
      refute text =~ "zz-style-backfill-sentinel"

      # ── Negative control: an uncovered content type is identical in
      # intent, status and extracted text. Without this, "the HTML row
      # changed" is compatible with "everything changed".
      assert snapshot(opaque.id) == opaque_before
      assert snapshot(opaque.id).intent == "human_only"

      # ── Second control: a non-HTML row that was already fine is untouched.
      assert snapshot(plain.id) == plain_before
    end

    test "a second run changes nothing further", ctx do
      held = seed(ctx, "held.html", "text/html", @html) |> hold_back()

      first = HTMLBackfill.run(project_id: ctx.project.id)
      assert first.changed == 1
      assert wait_for_status(held.id, "ingested")
      after_first = snapshot(held.id)

      second = HTMLBackfill.run(project_id: ctx.project.id)

      assert second.changed == 0
      assert second.candidates == []
      assert second.skipped_already_ingesting == 1
      assert snapshot(held.id) == after_first
    end

    test "the work is finished before run/1 returns, not merely requested", ctx do
      Application.put_env(:platform, :memory_service, provider: SlowProvider)
      held = seed(ctx, "held.html", "text/html", @html) |> hold_back()

      report = HTMLBackfill.run(project_id: ctx.project.id)

      # No wait_for_status, no sleep: this is the instant `mix` would
      # halt the VM. Anything unfinished here is lost, and the count
      # printed a line above would be describing a corpse.
      row = Repo.get!(Platform.Files.File, held.id)
      assert row.ingest_status == "ingested"
      assert Files.fetch_extracted_text(held.id).text =~ "Orion Technical Stack"
      assert report.changed == 1
    end

    test "a failed ingest is counted as a failure, not as re-ingested", ctx do
      Application.put_env(:platform, :memory_service, provider: FailingProvider)
      held = seed(ctx, "held.html", "text/html", @html) |> hold_back()

      report = HTMLBackfill.run(project_id: ctx.project.id)

      assert report.changed == 0
      assert [{id, :provider_unavailable}] = report.errors
      assert id == held.id
      assert HTMLBackfill.format_report(report) =~ "re-ingested (extracted and indexed): 0"
      assert HTMLBackfill.format_report(report) =~ "failed to re-ingest: 1"
      assert Repo.get!(Platform.Files.File, held.id).ingest_status == "failed"
    end

    test "a row stranded at pending is picked up again once it is stale", ctx do
      stranded = seed(ctx, "stranded.html", "text/html", @html)
      fresh = seed(ctx, "fresh.html", "text/html", @html)

      # Exactly the state the pre-fix async run left behind: intent
      # flipped, status pending, no text, and no process working on it.
      park_at_pending(stranded.id, DateTime.add(DateTime.utc_now(), -3600, :second))
      park_at_pending(fresh.id, DateTime.utc_now())

      report = HTMLBackfill.run(project_id: ctx.project.id)

      assert report.candidates == [stranded.id]
      assert report.stale_pending == 1
      assert report.changed == 1
      assert Repo.get!(Platform.Files.File, stranded.id).ingest_status == "ingested"

      # A genuinely in-flight upload is not stolen from its own worker.
      assert report.skipped_already_ingesting == 1
      assert Repo.get!(Platform.Files.File, fresh.id).ingest_status == "pending"
      assert Files.fetch_extracted_text(fresh.id) == nil
    end

    test "a soft-deleted HTML row is skipped and the skip is reported", ctx do
      deleted = seed(ctx, "gone.html", "text/html", @html) |> hold_back()

      {1, _} =
        Repo.update_all(
          from(f in Platform.Files.File, where: f.id == ^deleted.id),
          set: [deleted_at: DateTime.utc_now()]
        )

      report = HTMLBackfill.run(project_id: ctx.project.id)

      assert report.skipped_deleted == 1
      assert report.changed == 0
      assert HTMLBackfill.format_report(report) =~ "left unchanged (soft-deleted): 1"

      row = Repo.get!(Platform.Files.File, deleted.id)
      assert row.ingest_intent == "human_only"
      assert Files.fetch_extracted_text(deleted.id) == nil
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp seed(%{project: project, root: root}, filename, content_type, body) do
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
    abs_path = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: Base.encode16(:crypto.hash(:sha256, body <> filename), case: :lower)
      })

    file
  end

  # Reproduces the pre-change state: HTML uploaded before the extractor
  # covered it was held back from agents.
  defp hold_back(file) do
    {:ok, held} = Files.withdraw_from_agent_context(Files.get_file(file.id))
    held
  end

  defp park_at_pending(file_id, updated_at) do
    {1, _} =
      Repo.update_all(
        from(f in Platform.Files.File, where: f.id == ^file_id),
        set: [ingest_intent: "attempt", ingest_status: "pending", updated_at: updated_at]
      )

    :ok
  end

  defp snapshot(file_id) do
    row = Repo.get!(Platform.Files.File, file_id)

    %{
      intent: row.ingest_intent,
      status: row.ingest_status,
      text: Files.fetch_extracted_text(file_id) && Files.fetch_extracted_text(file_id).text
    }
  end

  defp wait_for_status(file_id, status, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _acc ->
      case Repo.get(Platform.Files.File, file_id) do
        %{ingest_status: ^status} -> {:halt, true}
        _ -> Process.sleep(25) && {:cont, false}
      end
    end)
  end
end
