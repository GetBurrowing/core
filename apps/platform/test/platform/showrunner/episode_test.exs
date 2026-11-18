defmodule Platform.Showrunner.EpisodeTest do
  @moduledoc "Task 01a1eaf6 stage 1: the How to Computer episode state model."

  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasDocument
  alias Platform.Showrunner.Episode

  @stage2_kinds ~w(production_rail needs_you run_sheet)

  defp episode!(attrs \\ %{}) do
    {:ok, episode} =
      Episode.new(
        Map.merge(
          %{
            number: 12,
            title: "Passwords, honestly",
            records_at: ~U[2026-11-20 17:00:00.123456Z],
            room_status: "booked",
            brief: "Why password managers beat memory.",
            guests: [%{name: "Ada", role: "security researcher"}]
          },
          attrs
        )
      )

    episode
  end

  defp segments do
    [
      %{
        id: "cold-open",
        starts_at_s: 0,
        ends_at_s: 120,
        name: "Cold open",
        talking_points: %{"host" => "The sticky note on the monitor."},
        callback_episode: 7,
        stat_cards: [
          %{
            text: "81% of breaches involve weak passwords",
            source_url: "https://example.org/dbir"
          }
        ]
      },
      %{
        id: "main",
        starts_at_s: 120,
        ends_at_s: 1800,
        name: "Main topic",
        talking_points: %{"host" => "Demo the manager.", "guest" => "Threat model."},
        callback_episode: nil,
        stat_cards: []
      },
      %{
        id: "mailbag",
        starts_at_s: 1800,
        ends_at_s: 2700,
        name: "Mailbag",
        talking_points: %{},
        callback_episode: nil,
        stat_cards: []
      }
    ]
  end

  defp full_episode! do
    episode = episode!()
    {:ok, episode} = Episode.put_run_sheet(episode, segments())

    {:ok, episode} =
      Episode.add_needs_you(episode, %{
        id: "guest-slot",
        question: "Ada or Grace for the guest slot?",
        options: ["Ada", "Grace"]
      })

    {:ok, episode} =
      Episode.put_retro(episode, %{
        kept_segment_ids: ["cold-open", "main"],
        cut_segment_ids: ["mailbag"],
        clip_results: [%{segment_id: "main", views: 1200}]
      })

    episode
  end

  describe "new/1" do
    test "starts at :pitch in progress with every later stage not started" do
      episode = episode!()

      assert episode.stage == :pitch
      assert episode.stages.pitch == :in_progress

      for stage <- tl(Episode.stages()), do: assert(episode.stages[stage] == :not_started)

      assert episode.records_at == ~U[2026-11-20 17:00:00Z]
      assert episode.guests == [%{"name" => "Ada", "role" => "security researcher"}]
    end

    test "refuses a missing number or a blank title" do
      assert {:error, {:bad_prop, :number}} = Episode.new(%{title: "x"})
      assert {:error, {:bad_prop, :title}} = Episode.new(%{number: 1, title: "  "})
      assert {:error, :attrs_must_be_a_map} = Episode.new("x")
    end
  end

  describe "stages and advance/2" do
    test "exactly seven stages, in order" do
      assert Episode.stages() ==
               [:pitch, :research, :run_sheet, :logistics, :record, :post, :retro]

      assert Episode.stage_states() == [:ready, :in_progress, :needs_you, :not_started]
    end

    test "advance walks every stage in order, marking each one left :ready" do
      final =
        Enum.reduce(tl(Episode.stages()), episode!(), fn next, episode ->
          from = episode.stage
          assert {:ok, advanced} = Episode.advance(episode, next)
          assert advanced.stage == next
          assert advanced.stages[from] == :ready
          assert advanced.stages[next] == :in_progress
          advanced
        end)

      assert final.stage == :retro
      assert Episode.next_stage(:retro) == nil
      assert {:error, {:invalid_transition, :retro, :pitch}} = Episode.advance(final, :pitch)
    end

    test "advance refuses a skipped, backward or unknown stage" do
      episode = episode!()

      assert {:error, {:invalid_transition, :pitch, :run_sheet}} =
               Episode.advance(episode, :run_sheet)

      assert {:error, {:invalid_transition, :pitch, :pitch}} = Episode.advance(episode, :pitch)
      assert {:error, {:invalid_transition, :pitch, :edit}} = Episode.advance(episode, :edit)
    end

    test "an open needs_you holds the stage until it is resolved" do
      {:ok, episode} =
        Episode.add_needs_you(episode!(), %{
          id: "q1",
          question: "Which topic?",
          options: ["A", "B"]
        })

      assert episode.stages.pitch == :needs_you
      assert {:error, :needs_you_open} = Episode.advance(episode, :research)

      assert {:error, {:invalid_choice, "q1", "C"}} =
               Episode.resolve_needs_you(episode, "q1", "C")

      assert {:error, {:unknown_needs_you, "q9"}} = Episode.resolve_needs_you(episode, "q9", "A")

      assert {:ok, resolved} = Episode.resolve_needs_you(episode, "q1", "B")
      assert resolved.needs_you == []
      assert resolved.stages.pitch == :in_progress
      assert {:ok, %{stage: :research}} = Episode.advance(resolved, :research)
    end

    test "needs_you refuses a duplicate id or an item without options" do
      item = %{id: "q1", question: "Which?", options: ["A"]}
      {:ok, episode} = Episode.add_needs_you(episode!(), item)

      assert {:error, {:duplicate_needs_you, "q1"}} = Episode.add_needs_you(episode, item)

      assert {:error, {:bad_prop, {:needs_you, "q2", :options}}} =
               Episode.add_needs_you(episode, %{id: "q2", question: "Which?", options: []})
    end
  end

  describe "put_run_sheet/2" do
    test "accepts a contiguous sheet from 00:00 of exactly 45:00" do
      assert {:ok, episode} = Episode.put_run_sheet(episode!(), segments())
      assert Enum.map(episode.run_sheet, & &1.id) == ["cold-open", "main", "mailbag"]
      assert List.last(episode.run_sheet).ends_at_s == Episode.max_run_s()
    end

    test "a stat card without a source is refused" do
      for bad <- [nil, "", "   "] do
        [first | rest] = segments()
        card = %{text: "9 in 10 people reuse passwords", source_url: bad}
        unsourced = [%{first | stat_cards: [card]} | rest]

        assert {:error, {:unsourced_stat, "cold-open"}} =
                 Episode.put_run_sheet(episode!(), unsourced)
      end

      [first | rest] = segments()
      no_key = [%{first | stat_cards: [%{text: "9 in 10"}]} | rest]
      assert {:error, {:unsourced_stat, "cold-open"}} = Episode.put_run_sheet(episode!(), no_key)
    end

    test "a run longer than 45:00 is refused" do
      long = List.update_at(segments(), 2, &%{&1 | ends_at_s: 2701})
      assert {:error, {:run_too_long, 2701, 2700}} = Episode.put_run_sheet(episode!(), long)
    end

    test "segments must run contiguously from 00:00" do
      late_start = List.update_at(segments(), 0, &%{&1 | starts_at_s: 5})

      assert {:error, {:not_contiguous, "cold-open", 0}} =
               Episode.put_run_sheet(episode!(), late_start)

      gap = List.update_at(segments(), 1, &%{&1 | starts_at_s: 130})
      assert {:error, {:not_contiguous, "main", 120}} = Episode.put_run_sheet(episode!(), gap)

      assert {:error, :empty_run_sheet} = Episode.put_run_sheet(episode!(), [])
    end

    test "a duplicate or zero-length segment is refused" do
      dup = List.update_at(segments(), 1, &%{&1 | id: "cold-open"})
      assert {:error, {:duplicate_segment, "cold-open"}} = Episode.put_run_sheet(episode!(), dup)

      zero = [%{hd(segments()) | ends_at_s: 0}]
      assert {:error, {:empty_segment, "cold-open"}} = Episode.put_run_sheet(episode!(), zero)
    end
  end

  describe "kept_share/1" do
    test "is kept segments over total run-sheet segments" do
      assert_in_delta Episode.kept_share(full_episode!()), 2 / 3, 1.0e-9
    end

    test "is 0.0 with nothing kept, 1.0 with everything kept, nil with no run sheet" do
      episode = full_episode!()
      {:ok, none} = Episode.put_retro(episode, %{kept_segment_ids: [], cut_segment_ids: []})
      assert Episode.kept_share(none) == 0.0

      {:ok, all} =
        Episode.put_retro(episode, %{kept_segment_ids: ["cold-open", "main", "mailbag"]})

      assert Episode.kept_share(all) == 1.0
      assert Episode.kept_share(episode!()) == nil
    end

    test "put_retro refuses ids off the sheet and a segment both kept and cut" do
      episode = full_episode!()

      assert {:error, :retro_off_sheet} =
               Episode.put_retro(episode, %{kept_segment_ids: ["nope"]})

      assert {:error, :kept_and_cut_overlap} =
               Episode.put_retro(episode, %{kept_segment_ids: ["main"], cut_segment_ids: ["main"]})
    end
  end

  describe "documents" do
    test "round-trips through to_document/1 and from_document/1, including via JSON" do
      episode = full_episode!()
      document = Episode.to_document(episode)

      assert {:ok, ^episode} = Episode.from_document(document)

      assert {:ok, ^episode} =
               document |> Jason.encode!() |> Jason.decode!() |> Episode.from_document()

      bare = episode!(%{records_at: nil, brief: nil, guests: []})
      assert {:ok, ^bare} = bare |> Episode.to_document() |> Episode.from_document()
    end

    test "is a structurally valid canvas document whose only gaps are the stage-2 kinds" do
      document = Episode.to_document(full_episode!())

      assert %{"version" => 1, "revision" => 1, "root" => %{"type" => "stack"} = root} = document
      assert Enum.map(root["children"], & &1["type"]) == @stage2_kinds
      assert CanvasDocument.get_node(document, "run_sheet")["props"]["total_s"] == 2700

      # Stage 2 registers the three kinds; until then they are the ONLY errors.
      case CanvasDocument.validate(document) do
        {:ok, _} ->
          :ok

        {:error, reasons} ->
          for reason <- reasons do
            assert Enum.any?(@stage2_kinds, &(reason =~ ~s(unknown kind "#{&1}"))), reason
          end
      end
    end

    test "a hand-edited, partial or invalid document returns {:error, _} and never raises" do
      good = Episode.to_document(full_episode!())
      children = get_in(good, ["root", "children"])

      put_children = fn fun -> put_in(good, ["root", "children"], fun.(children)) end

      update_props = fn type, fun ->
        put_children.(fn kids ->
          Enum.map(kids, fn
            %{"type" => ^type} = node -> Map.update!(node, "props", fun)
            node -> node
          end)
        end)
      end

      update_segment = fn fun ->
        update_props.("run_sheet", fn props ->
          Map.update!(props, "segments", &List.update_at(&1, 0, fun))
        end)
      end

      cases = [
        {"nil", nil},
        {"a string", "not a document"},
        {"a list", [good]},
        {"an empty map", %{}},
        {"no root", Map.delete(good, "root")},
        {"no meta", Map.delete(good, "meta")},
        {"a non-map root", Map.put(good, "root", "stack")},
        {"root children not a list", put_in(good, ["root", "children"], %{"a" => 1})},
        {"a missing run_sheet node",
         put_children.(&Enum.reject(&1, fn n -> n["type"] == "run_sheet" end))},
        {"a renamed production_rail type",
         put_children.(
           &Enum.map(&1, fn
             %{"type" => "production_rail"} = n -> %{n | "type" => "rail"}
             n -> n
           end)
         )},
        {"a non-map child",
         put_children.(&["junk" | Enum.reject(&1, fn n -> n["type"] == "needs_you" end)])},
        {"props not a map", update_props.("needs_you", fn _ -> "items" end)},
        {"a string episode number",
         update_props.("production_rail", &Map.put(&1, "number", "12"))},
        {"a blank title", update_props.("production_rail", &Map.put(&1, "title", ""))},
        {"an unknown stage", update_props.("production_rail", &Map.put(&1, "stage", "edit"))},
        {"a stage as a non-string", update_props.("production_rail", &Map.put(&1, "stage", 3))},
        {"a bad records_at",
         update_props.("production_rail", &Map.put(&1, "records_at", "Friday"))},
        {"stages with one missing",
         update_props.("production_rail", &Map.update!(&1, "stages", fn s -> tl(s) end))},
        {"stages with an unknown state",
         update_props.(
           "production_rail",
           &Map.update!(&1, "stages", fn [h | t] -> [%{h | "state" => "done"} | t] end)
         )},
        {"stages duplicated",
         update_props.(
           "production_rail",
           &Map.update!(&1, "stages", fn [h | t] -> [h, h | t] end)
         )},
        {"stages not a list", update_props.("production_rail", &Map.put(&1, "stages", %{}))},
        {"needs_you items not a list", update_props.("needs_you", &Map.put(&1, "items", "q"))},
        {"a needs_you item without a question",
         update_props.("needs_you", &Map.put(&1, "items", [%{"id" => "q", "options" => ["a"]}]))},
        {"segments not a list", update_props.("run_sheet", &Map.put(&1, "segments", nil))},
        {"a segment that is a string",
         update_props.("run_sheet", &Map.put(&1, "segments", ["x"]))},
        {"an unsourced stat in a hand edit",
         update_segment.(&Map.put(&1, "stat_cards", [%{"text" => "9 in 10", "source_url" => ""}]))},
        {"stat_cards not a list", update_segment.(&Map.put(&1, "stat_cards", "none"))},
        {"a string start time", update_segment.(&Map.put(&1, "starts_at_s", "0:00"))},
        {"talking points as a list", update_segment.(&Map.put(&1, "talking_points", ["a"]))},
        {"a talking point that is a number",
         update_segment.(&Map.put(&1, "talking_points", %{"j" => 1}))},
        {"a run sheet over 45:00",
         update_props.("run_sheet", fn props ->
           Map.update!(
             props,
             "segments",
             &List.update_at(&1, -1, fn s -> %{s | "ends_at_s" => 9999} end)
           )
         end)},
        {"meta.showrunner missing", Map.put(good, "meta", %{})},
        {"meta.showrunner not a map", put_in(good, ["meta", "showrunner"], "x")},
        {"meta not a map", Map.put(good, "meta", "x")},
        {"guests not a list", put_in(good, ["meta", "showrunner", "guests"], "Ada")},
        {"a guest map with a tuple key",
         put_in(good, ["meta", "showrunner", "guests"], [%{{:a, 1} => 1}])},
        {"retro not a map", put_in(good, ["meta", "showrunner", "retro"], [])},
        {"retro kept ids off the sheet",
         put_in(good, ["meta", "showrunner", "retro", "kept_segment_ids"], ["ghost"])},
        {"a brief that is a number", put_in(good, ["meta", "showrunner", "brief"], 7)}
      ]

      for {label, doc} <- cases do
        result =
          try do
            Episode.from_document(doc)
          rescue
            exception -> flunk("#{label}: raised #{Exception.format(:error, exception)}")
          end

        assert {:error, _reason} = result,
               "#{label}: expected {:error, _}, got #{inspect(result)}"
      end
    end
  end
end
