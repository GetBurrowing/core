defmodule Platform.Org.Wiki.ContextIntegrationTest do
  @moduledoc """
  Stage-3 integration test (ADR-0041 T4).

  Exercises the full path from `Wiki.upsert_page/3` → `WikiContext.build_preamble/1`,
  including frontmatter parsing, scope filtering, and annotation. The
  pure-algorithm tests live in `context_test.exs`; this file proves the
  wiring back to the database surface still works the way call sites
  (`ContextAssembler.build/2`, `ContextPlane.build_context_bundle/1`)
  consume it.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Context, as: WikiContext
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  test "build_preamble end-to-end: only preamble:true page returned, annotated" do
    {:ok, _kept} =
      Wiki.upsert_page("org/identity.md", %{
        content: "---\npreamble: true\n---\nMission statement."
      })

    {:ok, _skipped} =
      Wiki.upsert_page("org/notes.md", %{
        content: "---\npreamble: false\n---\nNot for preamble."
      })

    result = WikiContext.build_preamble([])

    assert Map.keys(result) == ["org/identity.md"]
    value = result["org/identity.md"]
    assert String.starts_with?(value, ~s(<!-- BEGIN org-preamble page="org/identity.md"))
    assert String.contains?(value, "Mission statement.")
    assert String.ends_with?(value, ~s(<!-- END org-preamble page="org/identity.md" -->))
  end

  test "build_preamble end-to-end: project scope honors task.project_id" do
    {:ok, _} =
      Wiki.upsert_page("org/global.md", %{content: "---\npreamble: true\n---\nglobal"})

    {:ok, _} =
      Wiki.upsert_page("project/proj-xyz/runbook.md", %{
        content: "---\npreamble: true\n---\nxyz runbook"
      })

    {:ok, _} =
      Wiki.upsert_page("project/other-proj/runbook.md", %{
        content: "---\npreamble: true\n---\nother runbook"
      })

    task = %Platform.Tasks.Task{project_id: "proj-xyz"}
    result = WikiContext.build_preamble(task: task)

    assert Map.has_key?(result, "org/global.md")
    assert Map.has_key?(result, "project/proj-xyz/runbook.md")
    refute Map.has_key?(result, "project/other-proj/runbook.md")
  end
end
