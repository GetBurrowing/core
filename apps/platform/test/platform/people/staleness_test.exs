defmodule Platform.People.StalenessTest do
  @moduledoc "Task 01a1aa47 stage 3 — the pure `Platform.People.Staleness.compute/4` report."
  use ExUnit.Case, async: true

  alias Platform.People.Staleness

  @t0 ~U[2026-10-01 10:00:00Z]
  @t1 ~U[2026-10-10 10:00:00Z]
  @t2 ~U[2026-10-20 10:00:00Z]

  defp card(slug, name, opts \\ []) do
    %{
      slug: slug,
      path: "org/page/people/#{slug}.md",
      name: name,
      aliases: Keyword.get(opts, :aliases, []),
      user_id: nil,
      relation: "team",
      organisation: nil,
      role: nil,
      last_seen: nil,
      updated_at: Keyword.get(opts, :updated_at, @t1),
      legacy: Keyword.get(opts, :legacy, false)
    }
  end

  defp seen(name, at, extra \\ %{}) do
    Map.merge(
      %{
        raw_name: name,
        kind: :human,
        user_id: nil,
        agent_id: nil,
        source: :chat_author,
        space_id: nil,
        meeting_id: nil,
        project_id: nil,
        task_id: nil,
        at: at,
        citation: "chat:s:m"
      },
      extra
    )
  end

  defp roster do
    [
      card("marisol-tennebrook", "Marisol Tennebrook", aliases: ["Mari"]),
      card("oskar-vellinghausen", "Oskar Vellinghausen"),
      card("oskar-kalloway", "Oskar Kalloway")
    ]
  end

  defp index, do: %{names: ["Marisol Tennebrook", "Priya Kalloway"], paths: []}

  test "a person seen with no card is no_profile" do
    report = Staleness.compute([seen("Fixture Founder", @t2)], roster(), index())

    assert report.no_profile == ["Fixture Founder"]
    assert report.resolved == []
  end

  test "a card older than the latest appearance is stale" do
    report =
      Staleness.compute(
        [seen("Marisol Tennebrook", @t0), seen("Mari", @t2), seen("Oskar Vellinghausen", @t1)],
        roster(),
        index()
      )

    # Oskar's card was updated AT his latest appearance: older means strictly
    # earlier, so only Marisol's card is stale.
    assert [%{slug: "marisol-tennebrook", page_updated_at: @t1, last_seen_at: @t2}] = report.stale

    assert [
             %{slug: "marisol-tennebrook", name: "Marisol Tennebrook", appearances: [_, _]},
             %{slug: "oskar-vellinghausen"}
           ] =
             report.resolved
  end

  test "a card updated at exactly the latest appearance is not stale" do
    report = Staleness.compute([seen("Marisol Tennebrook", @t1)], roster(), index())
    assert report.stale == []
  end

  test "a legacy card is always stale" do
    roster = [card("priya-kalloway", "Priya Kalloway", legacy: true, updated_at: @t2)]
    report = Staleness.compute([], roster, %{names: [], paths: []})

    assert [%{slug: "priya-kalloway", page_updated_at: @t2, last_seen_at: nil}] = report.stale
  end

  test "an ambiguous name lands in review" do
    report = Staleness.compute([seen("Oskar", @t2)], roster(), index())

    assert report.review == [
             %{raw_name: "Oskar", candidates: ["oskar-kalloway", "oskar-vellinghausen"]}
           ]

    assert report.no_profile == []
    assert report.stale == []
  end

  test "an index-only name is reported" do
    report = Staleness.compute([], roster(), index())
    assert report.index_only == ["Priya Kalloway"]
  end

  test "agents are skipped and staleness_days bounds the lookback" do
    appearances = [
      seen("Scribe", @t2, %{kind: :agent}),
      seen("Marisol Tennebrook", @t2)
    ]

    assert %{no_profile: [], stale: [%{slug: "marisol-tennebrook"}]} =
             Staleness.compute(appearances, roster(), index())

    assert %{stale: [], resolved: []} =
             Staleness.compute(appearances, roster(), index(),
               staleness_days: 3,
               now: ~U[2026-10-30 10:00:00Z]
             )
  end
end
