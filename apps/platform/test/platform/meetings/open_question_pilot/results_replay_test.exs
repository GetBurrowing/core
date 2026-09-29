defmodule Platform.Meetings.OpenQuestionPilot.ResultsReplayTest do
  @moduledoc """
  The checked-in result of the pilot run (task 01a0e8b5 stage 4) reproduces
  offline. Each arm is replayed over its checked-in TEST cassette through
  the same `Score.run/3` the run used, with no network, and precision,
  recall, the confusion matrix, the error classes and privacy at both
  levels must equal `results.json` EXACTLY. `program_b.json` must load with
  `Imp.read!/1`, and must be the program whose cassette replays.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Meetings.OpenQuestionPilot.Dataset
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Meetings.OpenQuestionPilot.Runner
  alias Platform.Meetings.OpenQuestionPilot.Score

  @dir Programs.dir()

  setup_all do
    {:ok, results: @dir |> Path.join("results.json") |> File.read!() |> Jason.decode!()}
  end

  setup %{results: results} do
    room = Runner.setup_artefact_room!()
    agent = %{model: results["provider"]["model"], base_url: results["provider"]["base_url"]}

    %{
      test_rows: Dataset.split(Dataset.load(), "test"),
      args_for: Runner.arm_a_args_fn(Runner.arm_a_config(), agent),
      check: Score.gather_context_check(room.meeting_id, room.room_id)
    }
  end

  defp replay(ctx, arm, cassette) do
    meter =
      Meter.new(
        cap: 10_000,
        mode: :replay,
        cassette_path: Path.join([@dir, "cassettes", cassette])
      )

    {report, _log} =
      with_log(fn ->
        Score.run(ctx.test_rows, arm,
          args_for: ctx.args_for,
          meter: meter,
          artefact_check: ctx.check
        )
      end)

    assert Meter.misses(meter) == 0
    report
  end

  defp assert_reproduces(report, recorded) do
    assert report.n == recorded["n"]
    assert report.precision == recorded["precision"]
    assert report.recall == recorded["recall"]
    assert Map.new(report.confusion, fn {k, v} -> {to_string(k), v} end) == recorded["confusion"]
    assert Map.new(report.errors, fn {k, v} -> {to_string(k), v} end) == recorded["errors"]
    assert Map.new(report.privacy, fn {k, v} -> {to_string(k), v} end) == recorded["privacy"]
  end

  test "the results carry what the stage requires", %{results: results} do
    assert results["dataset"]["n"]["test"]["n"] == 35
    assert results["prompt_a"]["sha256"] == Runner.arm_a_config()["prompt_sha256"]
    assert results["optimiser"]["max_metric_calls"] == 300
    assert results["optimiser"]["hard_call_cap"] == 400
    assert results["optimiser"]["reflection_cap"] == 40
    assert results["optimiser"]["stop_reason"] not in [nil, ""]
    assert results["provider"]["model"] == "classifier"
    assert results["spend"]["cost_usd"] == 0.0
    assert is_boolean(results["selection"]["admissible"])
  end

  test "arm A replays to exactly the recorded TEST numbers", ctx do
    assert_reproduces(replay(ctx, :prompt, "test_prompt.jsonl"), ctx.results["arms"]["prompt"])
  end

  test "arm B: program_b.json loads and replays exactly, or B is recorded as inadmissible", ctx do
    path = Path.join(@dir, "program_b.json")

    if ctx.results["selection"]["admissible"] do
      program = Imp.read!(path)
      assert %Imp.Predict{} = program

      assert ctx.results["program_b"]["sha256"] ==
               :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

      # No credential and no endpoint in the artefact.
      refute File.read!(path) =~ "192.168."
      refute File.read!(path) =~ "api_key"

      report = replay(ctx, {:imp_program, program}, "test_imp_program.jsonl")
      assert_reproduces(report, ctx.results["arms"]["imp_program"])
    else
      assert ctx.results["arms"]["imp_program"] == nil
      assert ctx.results["program_b"] == nil
      refute File.exists?(path)
    end
  end

  test "the Priya row is in TEST and leaves no artefact under either arm", %{results: results} do
    assert Enum.find(Dataset.load(), &(&1["id"] == "corpus-privacy-01"))["split"] == "test"

    for {arm, block} <- results["arms"], block != nil do
      priya = Enum.find(block["rows"], &(&1["id"] == "corpus-privacy-01"))
      assert priya, "#{arm} has no row for the Priya line"
      assert priya["artefact"] in ["refused", "not_checked"], "#{arm}: #{inspect(priya)}"
    end
  end
end
