defmodule Platform.Memory.JournalSweepTest do
  @moduledoc """
  The two journal sweep paths ingest `<synthesis-insight>` blocks (task
  01a13867 stage 1): the `OrgContext.upsert_context_file/3` post-write hook
  and `JournalSweep.sweep/2` after `Journal.append/2`. Moved here from
  `proposals_test.exs`, where the same cases covered `<synthesis-proposal>`
  ingestion. A proposal block is no longer ingested on either path.
  """

  use Platform.DataCase, async: false

  alias Platform.Memory.Insight
  alias Platform.Memory.JournalSweep
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo

  @proposal ~s(<synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
  A legacy proposal.
  </synthesis-proposal>)

  setup do
    Repo.delete_all(Insight)
    Repo.delete_all("memory_proposals")
    :ok
  end

  describe "OrgContext.upsert_context_file/3 sweep hook" do
    test "a journal write with an insight block ingests a row, and a proposal block none" do
      content = ~s"""
      # Journal

      <synthesis-insight action="briefing" confidence="high" evidence="e">
      Ingested via the sweep hook.
      </synthesis-insight>

      #{@proposal}
      """

      assert {:ok, _} =
               OrgContext.upsert_context_file("org/journal/2026-07-17.md", %{
                 content: content,
                 updated_by: nil
               })

      # A whole-file journal write carries no per-block author (task 01a15587
      # stage 2), so the insight is not eligible for unattended action.
      assert [%{body: "Ingested via the sweep hook.", authored_by: nil}] = Repo.all(Insight)
      assert Repo.aggregate("memory_proposals", :count) == 0
    end

    test "a page write with an insight block does NOT ingest" do
      assert {:ok, _} =
               OrgContext.upsert_context_file("org/page/identity.md", %{
                 content:
                   ~s(<synthesis-insight action="briefing" confidence="high">No.</synthesis-insight>),
                 updated_by: nil
               })

      assert [] = Repo.all(Insight)
    end

    test "a journal write with no blocks creates no rows" do
      assert {:ok, _} =
               OrgContext.upsert_context_file("org/journal/2026-07-17.md", %{
                 content: "just prose today",
                 updated_by: nil
               })

      assert [] = Repo.all(Insight)
    end
  end

  describe "JournalSweep.sweep/2 after Journal.append/2" do
    defp append_and_sweep(attrs, namespace) do
      case Journal.append(attrs, namespace: namespace) do
        {:ok, entry} ->
          :ok = JournalSweep.sweep(entry, namespace)
          {:ok, entry}

        other ->
          other
      end
    end

    test "an append with an insight block ingests a row, and a proposal block none" do
      content = ~s"""
      <synthesis-insight action="question" confidence="high" evidence="org/journal/2026-07-17.md">
      Ingested via the journal append hook.
      </synthesis-insight>

      #{@proposal}
      """

      assert {:ok, _} = append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")

      assert [%{body: "Ingested via the journal append hook.", action_type: "question"}] =
               Repo.all(Insight)

      assert Repo.aggregate("memory_proposals", :count) == 0
    end

    test "a namespaced append keys the insight to the namespaced journal path" do
      workspace_id = Ecto.UUID.generate()

      content =
        ~s(<synthesis-insight action="task" confidence="medium">Scoped to a project journal.</synthesis-insight>)

      assert {:ok, _} =
               append_and_sweep(
                 %{content: content, date: ~D[2026-07-18], workspace_id: workspace_id},
                 "project/#{workspace_id}"
               )

      assert [%{journal_path: path, workspace_id: ^workspace_id}] = Repo.all(Insight)
      assert path == "project/#{workspace_id}/journal/2026-07-18.md"
    end

    test "re-appending the same block does not duplicate the insight" do
      content =
        ~s(<synthesis-insight action="briefing" confidence="low">Written twice, ingested once.</synthesis-insight>)

      assert {:ok, _} = append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")
      assert {:ok, _} = append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")

      assert [%{body: "Written twice, ingested once."}] = Repo.all(Insight)
    end

    test "authored_by is stored from the entry" do
      agent =
        Repo.insert!(%Platform.Agents.Agent{
          slug: "sweep-author-#{System.unique_integer([:positive])}",
          name: "Sweep author",
          status: "active"
        })

      content =
        ~s(<synthesis-insight action="briefing" confidence="high">Written by an agent.</synthesis-insight>)

      assert {:ok, entry} =
               append_and_sweep(
                 %{content: content, date: ~D[2026-07-17], authored_by: agent.id},
                 "org"
               )

      assert entry.authored_by == agent.id
      assert [%Insight{authored_by: authored_by}] = Repo.all(Insight)
      assert authored_by == agent.id

      # An entry with no author ingests an insight with none.
      anonymous =
        ~s(<synthesis-insight action="briefing" confidence="high">Written by nobody known.</synthesis-insight>)

      assert {:ok, _} = append_and_sweep(%{content: anonymous, date: ~D[2026-07-17]}, "org")

      assert %Insight{authored_by: nil} =
               Repo.get_by!(Insight, body: "Written by nobody known.")
    end

    test "raw Journal.append/2 without the sweep ingests nothing" do
      content =
        ~s(<synthesis-insight action="briefing" confidence="high">Low-level API.</synthesis-insight>)

      assert {:ok, _} =
               Journal.append(%{content: content, date: ~D[2026-07-17]}, namespace: "org")

      # The T2 layering guard in wiki_t2_e2e_test.exs forbids a
      # Platform.Memory call site inside Journal, so the sweep is a
      # separate module callers invoke.
      assert [] = Repo.all(Insight)
    end
  end
end
