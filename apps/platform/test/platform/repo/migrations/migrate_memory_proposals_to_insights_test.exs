defmodule Platform.Repo.Migrations.MigrateMemoryProposalsToInsightsTest do
  @moduledoc """
  Behavioural coverage for `20261018000100_migrate_memory_proposals_to_insights`
  (task 01a13867 stage 1).

  The suite runs against an empty, freshly migrated database, so the
  migration has already run over zero rows by the time this file starts.
  Every test seeds `memory_proposals`, calls the SHIPPED `up/0` / `down/0`,
  and reads the tables back.

  Stage 5 retired the `Platform.Memory.MemoryProposal` schema with the
  Proposals UI; the table stays (dropping it is a separate one-way
  follow-up), so this file seeds and reads it schemaless.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Memory.Insight
  alias Platform.Memory.InsightVerdict
  alias Platform.Repo

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.MigrateMemoryProposalsToInsights

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261018000100_migrate_memory_proposals_to_insights.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    Repo.delete_all("memory_proposals")
    Repo.delete_all(Insight)
    Repo.delete_all(InsightVerdict)
    :ok
  end

  @proposal_fields [
    :id,
    :workspace_id,
    :journal_path,
    :block_hash,
    :category,
    :confidence,
    :evidence,
    :body,
    :status,
    :feedback,
    :expires_at,
    :target_page_key,
    :inserted_at,
    :updated_at
  ]

  defp proposal!(attrs) do
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()

    row =
      Map.merge(
        %{
          id: Ecto.UUID.dump!(id),
          workspace_id: nil,
          journal_path: "org/journal/2026-10-10.md",
          block_hash: "h-#{System.unique_integer([:positive])}",
          category: "recurring-theme",
          confidence: "high",
          evidence: nil,
          body: "body",
          status: "pending",
          feedback: nil,
          expires_at: DateTime.add(now, 3, :day),
          target_page_key: nil,
          inserted_at: now,
          updated_at: now
        },
        attrs
      )

    {1, _} = Repo.insert_all("memory_proposals", [row])
    Map.put(row, :id, id)
  end

  defp snapshot do
    Repo.all(from(p in "memory_proposals", order_by: p.id, select: map(p, ^@proposal_fields)))
  end

  defp seed! do
    past = DateTime.add(DateTime.utc_now(), -1, :day)

    %{
      live_question:
        proposal!(%{category: "unresolved-question", body: "Who owns X?", block_hash: "q"}),
      live_risk:
        proposal!(%{category: "emerging-risk", body: "Disk fills weekly.", block_hash: "r"}),
      live_theme: proposal!(%{category: "strategic-insight", body: "Theme.", block_hash: "t"}),
      expired: proposal!(%{body: "Old.", block_hash: "old", expires_at: past}),
      approved: proposal!(%{body: "Approved.", block_hash: "ok", status: "approved"}),
      rejected:
        proposal!(%{body: "Bad.", block_hash: "bad", status: "rejected", feedback: "wrong"}),
      rejected_silent: proposal!(%{body: "Meh.", block_hash: "meh", status: "rejected"})
    }
  end

  test "up copies rejected proposals to verdicts and live pending ones to insights" do
    seeded = seed!()

    assert %{verdicts: 2, insights: 3} = apply(@migration_module, :up, [])

    verdicts = Map.new(Repo.all(InsightVerdict), &{&1.block_hash, &1})
    assert Map.keys(verdicts) |> Enum.sort() == ["bad", "meh"]
    assert verdicts["bad"].reason == "wrong"
    assert verdicts["meh"].reason == "legacy rejection; no reason recorded"

    assert Enum.all?(
             Map.values(verdicts),
             &(&1.kind == "rejected" and &1.origin == "legacy_proposal")
           )

    insights = Map.new(Repo.all(Insight), &{&1.block_hash, &1})
    assert Map.keys(insights) |> Enum.sort() == ["q", "r", "t"]
    assert insights["q"].action_type == "question"
    assert insights["r"].action_type == "question"
    assert insights["t"].action_type == "briefing"
    assert insights["t"].action == %{"legacy_category" => "strategic-insight"}

    for {_hash, i} <- insights do
      assert i.origin == "legacy_proposal"
      assert i.state == "open"
      refute i.disseminable
      assert is_nil(i.addressee_user_id)
    end

    assert DateTime.compare(insights["q"].expires_at, seeded.live_question.expires_at) == :eq
  end

  test "up is idempotent" do
    seed!()
    apply(@migration_module, :up, [])
    assert %{verdicts: 0, insights: 0} = apply(@migration_module, :up, [])
    assert Repo.aggregate(Insight, :count) == 3
    assert Repo.aggregate(InsightVerdict, :count) == 2
  end

  test "down removes the copied rows and leaves memory_proposals unchanged" do
    seed!()
    before = snapshot()
    count = Repo.aggregate("memory_proposals", :count)

    # A row ingested by dreaming survives down/0: only legacy rows go.
    Repo.insert!(%InsightVerdict{block_hash: "native", kind: "flagged", reason: "x"})

    apply(@migration_module, :up, [])
    assert snapshot() == before

    assert %{verdicts: 2, insights: 3} = apply(@migration_module, :down, [])
    assert Repo.aggregate(Insight, :count) == 0
    assert [%InsightVerdict{block_hash: "native"}] = Repo.all(InsightVerdict)

    assert Repo.aggregate("memory_proposals", :count) == count
    assert snapshot() == before
  end
end
