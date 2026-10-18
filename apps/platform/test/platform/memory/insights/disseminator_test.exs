defmodule Platform.Memory.Insights.DisseminatorTest do
  @moduledoc """
  Task 01a13867 stage 3: the daily delivery run.

  Mutation probe (c): dropping the `(user_id, digest_date)` lookup turns
  "one digest per person per day" red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InsightFixtures

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.Participant
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Repo

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_humans(participant_ids, payload, _opts) do
      send(self(), {:push, participant_ids, payload})
      :ok
    end
  end

  # 12:00 UTC on 2026-10-18 is 07:00 America/Chicago (CDT).
  @now ~U[2026-10-18 12:00:00.000000Z]

  defp run!(opts \\ []) do
    Disseminator.run(Keyword.merge([now: @now, notifications_module: PushRecorder], opts))
  end

  defp canvases_in(space_id),
    do: Repo.all(from(c in Canvas, where: c.space_id == ^space_id and is_nil(c.deleted_at)))

  defp dm_canvases(user_id) do
    Repo.all(
      from(c in Canvas,
        join: p in Participant,
        on: p.space_id == c.space_id,
        where: p.participant_type == "user" and p.participant_id == ^user_id,
        select: c
      )
    )
  end

  defp text_values(document) do
    walk = fn
      %{"children" => children} = node, walk -> [node | Enum.flat_map(children, &walk.(&1, walk))]
      node, _walk -> [node]
    end

    for %{"type" => "text", "props" => %{"value" => v}} <- walk.(document["root"], walk), do: v
  end

  test "run/1 delivers nothing while dissemination is off" do
    dreaming_agent!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0}} = run!()

    assert dm_canvases(person.id) == []
    assert Repo.aggregate(Briefing, :count) == 0
    assert %Insight{delivered_at: nil, state: "open"} = Repo.get!(Insight, insight.id)
    refute_received {:push, _, _}

    # Positive control: the same fixture with dissemination on delivers.
    enable_dissemination!()
    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [_canvas] = dm_canvases(person.id)
  end

  test "one digest per person per day" do
    enable_dissemination!()
    agent = dreaming_agent!()
    person = person!()
    first = insight!(addressee: person, body: "First line.")

    assert {:ok, %{users: 1, items: 1}} = run!()

    assert [%Briefing{} = briefing] = Repo.all(Briefing)
    assert briefing.user_id == person.id
    assert briefing.digest_date == ~D[2026-10-18]
    assert briefing.items == %{BriefingCard.node_key(first) => first.id}

    assert [canvas] = canvases_in(briefing.space_id)
    assert canvas.id == briefing.canvas_id
    assert text_values(canvas.document) |> Enum.count(&(&1 == "First line.")) == 1

    # The canvas is posted by the dreaming agent into the person's DM.
    assert Repo.exists?(
             from(p in Participant,
               where:
                 p.space_id == ^briefing.space_id and p.participant_type == "agent" and
                   p.participant_id == ^agent.id
             )
           )

    assert %Insight{delivered_at: %DateTime{}} = Repo.get!(Insight, first.id)

    user_p =
      Repo.get_by!(Participant,
        space_id: briefing.space_id,
        participant_type: "user",
        participant_id: person.id
      )

    assert_received {:push, [participant_id], %{title: "Your briefing"}}
    assert participant_id == user_p.id

    # Same day, nothing new: no canvas, no row, no push.
    assert {:ok, %{users: 0, items: 0}} = run!(now: DateTime.add(@now, 3600))
    assert Repo.aggregate(Briefing, :count) == 1
    assert length(canvases_in(briefing.space_id)) == 1
    refute_received {:push, _, _}

    # Same day, a new insight: appended to the SAME canvas, no duplicate line.
    second = insight!(addressee: person, body: "Second line.")
    assert {:ok, %{users: 1, items: 1}} = run!(now: DateTime.add(@now, 7200))

    assert [%Briefing{} = again] = Repo.all(Briefing)
    assert again.id == briefing.id
    assert again.canvas_id == briefing.canvas_id
    assert map_size(again.items) == 2
    assert again.items[BriefingCard.node_key(second)] == second.id

    assert [updated] = canvases_in(briefing.space_id)
    values = text_values(updated.document)
    assert Enum.count(values, &(&1 == "First line.")) == 1
    assert Enum.count(values, &(&1 == "Second line.")) == 1
    assert {:ok, _} = CanvasDocument.validate(updated.document)
    assert_received {:push, [_], _}

    # The next day gets its own canvas.
    insight!(addressee: person, body: "Tomorrow's line.")
    assert {:ok, %{users: 1}} = run!(now: DateTime.add(@now, 86_400))
    assert Repo.aggregate(Briefing, :count) == 2
    assert length(canvases_in(briefing.space_id)) == 2
  end

  test "with no agent holding memory.dreaming nothing is delivered" do
    enable_dissemination!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0, reason: :no_agent}} = run!()
    assert dm_canvases(person.id) == []
    assert %Insight{delivered_at: nil} = Repo.get!(Insight, insight.id)
  end

  test "a needs_call insight reaches the admin's briefing as a link only" do
    enable_dissemination!()
    dreaming_agent!()
    admin = person!("admin")
    guest = person!("member", external: true)
    insight!(addressee: guest, action_type: "question", body: "Can you renew the cert?")

    assert {:ok, %{items: items}} = run!()
    assert items >= 1

    assert dm_canvases(guest.id) == []
    assert [canvas] = dm_canvases(admin.id)
    assert CanvasDocument.get_node(canvas.document, "section-call")
    refute CanvasDocument.get_node(canvas.document, "section-questions")
    assert "Can you renew the cert?" in text_values(canvas.document)
  end

  test "the next fire is 07:00 America/Chicago" do
    ms = Disseminator.ms_until_next_fire(~U[2026-10-18 11:00:00Z])
    assert ms == 60 * 60 * 1000
    assert Disseminator.local_date(~U[2026-10-19 03:00:00Z]) == ~D[2026-10-18]
  end
end
