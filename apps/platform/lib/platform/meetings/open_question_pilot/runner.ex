defmodule Platform.Meetings.OpenQuestionPilot.Runner do
  @moduledoc """
  The open_question pilot's one measured run (task 01a0e8b5 stage 4), driven
  by `mix platform.open_question_pilot.run`. The steps are fixed and run in
  this order; there is no flag to skip or reorder one:

    1. **Baseline A.** `Score` on the TEST split under `:prompt`, with arm
       A's prompt rendered from `prompt_a.txt` and the roster pinned in
       `arm_a.json`. Recorded to `cassettes/test_prompt.jsonl`.
    2. **Optimise once.** GEPA over `Program.new/0` on TRAIN, validated on
       VAL. The task model and the reflection model are both
       `ProviderLM`s over the configured classifier endpoint, each behind
       its own HARD meter cap (`:hard_call_cap`, `:reflection_cap`). GEPA
       checks `max_metric_calls` only between iterations, so the meters are
       the real ceiling. A cap that is reached ends the run with
       `stop_reason: :budget_exhausted`, and that is recorded as the result,
       not retried.
    3. **Select.** `select_admissible/2` walks the accepted candidates best
       validation score first, and takes the first with ZERO privacy
       violations over the privacy rows of TRAIN and VAL. Privacy is a
       constraint, not a weight: when no candidate is clean, B is
       INADMISSIBLE.
    4. **Compare.** `Score` on the same TEST split under the chosen B,
       recorded to `cassettes/test_imp_program.jsonl`.
    5. **Save.** `program_b.json` (`Imp.save!/2`, which stores no LM, no
       credentials and no URL) and `results.json`.

  Everything is written under `:out_dir`. Inputs (dataset, prompt, arm
  config) are always read from the shipped priv directory.

  ## The metric GEPA optimises

  Per example: `1.0` when the predicted `is_question` matches the label and
  `0.0` otherwise, with feedback naming the expected value. The exception is
  a privacy row: predicting `true` there scores `0.0` with feedback
  "privacy violation: candid register must never become a question",
  whatever the label says, and predicting `false` scores `1.0`. A candid
  question is still a question, but under the constraint it must never be
  surfaced as one.
  """

  require Logger

  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentEval.Harness
  alias Platform.Meetings.OpenQuestionPilot.Dataset
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.Program
  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Meetings.OpenQuestionPilot.ProviderLM
  alias Platform.Meetings.OpenQuestionPilot.Score

  @privacy_feedback "privacy violation: candid register must never become a question"

  @defaults [
    max_metric_calls: 300,
    hard_call_cap: 400,
    reflection_cap: 40,
    selection_cap: 120,
    seed: 20_260_929,
    base_url: "http://localhost:8085/v1",
    model: "classifier",
    timeout_ms: 120_000
  ]

  @doc """
  The defaults the Mix task falls back to. `INTENT_EVAL_BASE_URL`, when set
  and not blank, replaces the shipped `base_url` (the same variable the
  intent-eval harness reads, `Platform.Meetings.IntentEval.Harness`).
  """
  def defaults do
    case Platform.Meetings.IntentEval.Harness.env_base_url() do
      nil -> @defaults
      url -> Keyword.put(@defaults, :base_url, url)
    end
  end

  @doc "The feedback a privacy violation carries."
  def privacy_feedback, do: @privacy_feedback

  @doc """
  Run the pilot. Returns the results map, which is also written to
  `<out_dir>/results.json`.

  Options: everything in `defaults/0`, plus `:out_dir` (required),
  `:live_module` (default `Platform.Agents.Providers.Ollama`),
  `:artefact_check` (default: a scratch meeting seated by
  `setup_artefact_room!/0`), `:props` (the endpoint's `/props`, fetched when
  absent) and `:git_sha`.
  """
  @spec run(keyword()) :: map()
  def run(opts) do
    opts = Keyword.merge(defaults(), opts)
    out_dir = Keyword.fetch!(opts, :out_dir)
    live = Keyword.get(opts, :live_module, Platform.Agents.Providers.Ollama)
    File.mkdir_p!(Path.join(out_dir, "cassettes"))

    started = System.monotonic_time(:millisecond)
    rows = Dataset.load()
    [train, val, test] = Enum.map(Dataset.splits(), &Dataset.split(rows, &1))

    config = arm_a_config()
    agent = %{model: opts[:model], base_url: opts[:base_url]}
    args_for = arm_a_args_fn(config, agent)

    check =
      Keyword.get_lazy(opts, :artefact_check, fn ->
        room = setup_artefact_room!()
        Score.gather_context_check(room.meeting_id, room.room_id)
      end)

    # 1. Baseline A.
    {a_report, a_meter} =
      score_recorded(
        test,
        :prompt,
        args_for,
        check,
        live,
        out_dir,
        "test_prompt",
        length(test) + 5
      )

    # 2. Optimise once.
    optimisation = optimise(train, val, agent, live, opts)

    # 3. Select.
    selection =
      case optimisation.candidates do
        [] ->
          %{admissible: false, chosen: nil, checked: [], reason: "no candidates"}

        candidates ->
          sel_meter = Meter.new(cap: opts[:selection_cap], live_module: live)
          privacy_rows = Enum.filter(train ++ val, & &1["privacy"])

          result =
            select_admissible(candidates, fn candidate ->
              privacy_violations(candidate, privacy_rows, sel_meter, agent)
            end)

          Map.put(result, :calls, Meter.tickets(sel_meter))
      end

    # 4. Compare, and 5. save.
    {b_report, b_meter, program_b} =
      case selection do
        %{admissible: true, chosen: chosen} ->
          program = apply_candidate(chosen)

          {report, meter} =
            score_recorded(
              test,
              {:imp_program, program},
              args_for,
              check,
              live,
              out_dir,
              "test_imp_program",
              length(test) * 4
            )

          path = Path.join(out_dir, "program_b.json")
          Imp.save!(program, path)
          File.chmod!(path, 0o644)
          {report, meter, path}

        _ ->
          {nil, nil, nil}
      end

    results =
      results(%{
        opts: opts,
        rows: rows,
        config: config,
        a_report: a_report,
        a_meter: a_meter,
        optimisation: optimisation,
        selection: selection,
        b_report: b_report,
        b_meter: b_meter,
        program_b: program_b,
        wall_seconds: (System.monotonic_time(:millisecond) - started) / 1000
      })

    File.write!(Path.join(out_dir, "results.json"), Jason.encode!(results, pretty: true) <> "\n")
    results
  end

  # ── re-scoring the artefact level in replay ──────────────────────────────

  @doc """
  Re-score the artefact-level privacy of every recorded arm in `dir`'s
  `results.json` by REPLAYING its TEST cassette: no model call is made (the
  meter has no live module) and the cassette is not written. Everything
  downstream of the model (the gates and `gather_context/2`) is
  deterministic code, so this is how a floor change is measured without a
  second, differently-behaving live run.

  Only each arm's `privacy` block and its rows' `artefact` values are
  replaced; precision, recall and errors must come out identical to what
  was recorded, and the function raises if they do not. Latency is left as
  recorded. A `rescored` entry records when, at which sha and why.
  """
  @spec rescore_replay!(String.t(), String.t(), keyword()) :: map()
  def rescore_replay!(dir, reason, opts \\ []) do
    path = Path.join(dir, "results.json")
    results = path |> File.read!() |> Jason.decode!()
    test = Dataset.split(Dataset.load(), "test")

    agent = %{model: results["provider"]["model"], base_url: results["provider"]["base_url"]}
    args_for = arm_a_args_fn(arm_a_config(), agent)

    check =
      Keyword.get_lazy(opts, :artefact_check, fn ->
        room = setup_artefact_room!()
        Score.gather_context_check(room.meeting_id, room.room_id)
      end)

    arms =
      Map.new(results["arms"], fn
        {name, nil} ->
          {name, nil}

        {name, block} ->
          arm =
            case name do
              "prompt" -> :prompt
              "imp_program" -> {:imp_program, Imp.read!(Path.join(dir, "program_b.json"))}
            end

          cassette = Path.join([dir, "cassettes", "test_#{name}.jsonl"])
          meter = Meter.new(cap: 100_000, mode: :replay, cassette_path: cassette)

          report =
            Score.run(test, arm, args_for: args_for, meter: meter, artefact_check: check)

          fresh = arm_block(report)

          for key <- ["precision", "recall", "confusion", "errors"],
              fresh[key] != block[key] do
            raise "replay of #{name} changed #{key}: #{inspect(block[key])} -> #{inspect(fresh[key])}"
          end

          artefacts = Map.new(fresh["rows"], &{&1["id"], &1["artefact"]})

          rows =
            Enum.map(block["rows"], &Map.put(&1, "artefact", Map.fetch!(artefacts, &1["id"])))

          {name, %{block | "privacy" => fresh["privacy"], "rows" => rows}}
      end)

    rescored =
      (results["rescored"] || []) ++
        [
          %{
            "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "sha" => Keyword.get_lazy(opts, :git_sha, &git_sha/0),
            "mode" => "replay; no model calls",
            "reason" => reason
          }
        ]

    results = %{results | "arms" => arms} |> Map.put("rescored", rescored)
    File.write!(path, Jason.encode!(results, pretty: true) <> "\n")
    results
  end

  # ── re-recording arm A after a prompt change ─────────────────────────────

  @doc """
  Re-record arm A's TEST cassette LIVE after `prompt_a.txt` changed, and
  replace arm A's block in `dir`'s `results.json` with the new measurement.

  A cassette key covers the whole system prompt, so an edit to
  `prompt_a.txt` leaves every recorded answer unreachable. Re-keying the old
  answers would claim the model said something it was never asked, so this
  asks again: one live call per TEST row (cap: TEST rows + 5), through the
  same `Score.run/3` and recorder `run/1` uses for baseline A.

  Only arm A's results change: `prompt_a`, `arms.prompt`, and the
  `baseline_a` entries of `spend.calls` and `spend.tokens`. The optimiser,
  selection and arm B blocks are the original run's and are left as they
  are. A `rerecorded` entry records when, at which sha, against which model
  build, and why.

  Options: `:base_url` and `:model` (required: the live endpoint),
  `:live_module` (default `Platform.Agents.Providers.Ollama`),
  `:artefact_check`, `:props` and `:git_sha`, as for `run/1`.
  """
  @spec rerecord_arm_a!(String.t(), String.t(), keyword()) :: map()
  def rerecord_arm_a!(dir, reason, opts) when is_binary(reason) and reason != "" do
    path = Path.join(dir, "results.json")
    results = path |> File.read!() |> Jason.decode!()
    test = Dataset.split(Dataset.load(), "test")
    live = Keyword.get(opts, :live_module, Platform.Agents.Providers.Ollama)

    config = arm_a_config()
    agent = %{model: Keyword.fetch!(opts, :model), base_url: Keyword.fetch!(opts, :base_url)}
    args_for = arm_a_args_fn(config, agent)

    check =
      Keyword.get_lazy(opts, :artefact_check, fn ->
        room = setup_artefact_room!()
        Score.gather_context_check(room.meeting_id, room.room_id)
      end)

    {report, meter} =
      score_recorded(test, :prompt, args_for, check, live, dir, "test_prompt", length(test) + 5)

    props = Keyword.get_lazy(opts, :props, fn -> fetch_props(agent.base_url) end) || %{}

    entry = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "sha" => Keyword.get_lazy(opts, :git_sha, &git_sha/0),
      "mode" => "live; arm A TEST only",
      "reason" => reason,
      "base_url_host" => URI.parse(agent.base_url).host,
      "model" => agent.model,
      "model_file" => props["model_path"],
      "build_info" => props["build_info"],
      "lm_calls" => Meter.tickets(meter),
      "previous_prompt_a_sha256" => get_in(results, ["prompt_a", "sha256"])
    }

    results =
      results
      |> Map.put("prompt_a", %{
        "file" => config["prompt_file"],
        "sha256" => config["prompt_sha256"]
      })
      |> put_in(["arms", "prompt"], arm_block(report))
      |> put_in(["spend", "calls", "baseline_a"], Meter.tickets(meter))
      |> put_in(["spend", "tokens", "baseline_a"], jsonable(report.tokens))
      |> Map.put("rerecorded", (results["rerecorded"] || []) ++ [entry])

    File.write!(path, Jason.encode!(results, pretty: true) <> "\n")
    results
  end

  # ── arm A ────────────────────────────────────────────────────────────────

  @doc "Arm A's pinned config (`arm_a.json`), with its prompt loaded and checked."
  @spec arm_a_config() :: map()
  def arm_a_config do
    config = Programs.dir() |> Path.join("arm_a.json") |> File.read!() |> Jason.decode!()
    template = Programs.dir() |> Path.join(config["prompt_file"]) |> File.read!()

    unless sha256(template) == config["prompt_sha256"] do
      raise ArgumentError,
            "prompt_a.txt sha256 #{sha256(template)} does not match arm_a.json " <>
              config["prompt_sha256"]
    end

    Map.put(config, "template", template)
  end

  @doc """
  `fn row -> decide/1 args end` for arm A: the prompt rendered for the row
  through the intent-eval harness's own interpolation (the classifier's
  variables), the pinned roster as both the rendered block and the gate's
  entries, and the row's participants for the addressee gate.
  """
  @spec arm_a_args_fn(map(), map()) :: (map() -> map())
  def arm_a_args_fn(config, agent) do
    roster = Harness.roster_entries(config)
    roster_text = IntentClassifier.format_agent_roster(roster)

    fn row ->
      assigns =
        %{"text" => row["text"], "prior" => [], "speaker" => config["speaker"]}
        |> Harness.assigns_for(config["correction_exemplars"], roster_text)

      %{
        provider_module: Platform.Agents.Providers.Ollama,
        agent: agent,
        prompt: Harness.interpolate(config["template"], assigns),
        chunk_text: row["text"],
        room_id: nil,
        roster: roster,
        participants: Enum.map(row["participants"], &%{display_name: &1}),
        participant_names: row["participants"]
      }
    end
  end

  defp score_recorded(rows, arm, args_for, check, live, out_dir, name, cap) do
    path = Path.join([out_dir, "cassettes", name <> ".jsonl"])
    File.rm(path)
    meter = Meter.new(cap: cap, mode: :record, live_module: live, cassette_path: path)

    report = Score.run(rows, arm, args_for: args_for, meter: meter, artefact_check: check)
    :ok = Meter.flush!(meter)
    {report, meter}
  end

  # ── the artefact room ────────────────────────────────────────────────────

  @doc """
  A scratch meeting for the level-(ii) privacy check: a meeting, a room in
  an execution space with NO canvas, and every participant name the dataset
  uses seated in it. The replay test builds the same room, so a replayed
  artefact count is comparable with the recorded one.
  """
  @spec setup_artefact_room!() :: %{meeting_id: String.t(), room_id: String.t()}
  def setup_artefact_room! do
    alias Platform.Meetings

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "open_question pilot #{System.unique_integer([:positive])}"
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{project_id: project.id, name: "open_question pilot"})

    {:ok, space} = Platform.Chat.create_space(%{kind: "execution"})

    room =
      %Meetings.Room{}
      |> Meetings.Room.changeset(%{space_id: space.id, livekit_room_name: "space:#{space.id}"})
      |> Platform.Repo.insert!()

    for name <-
          Dataset.load() |> Enum.flat_map(& &1["participants"]) |> Enum.uniq() |> Enum.sort() do
      %Meetings.Participant{}
      |> Meetings.Participant.changeset(%{
        room_id: room.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })
      |> Platform.Repo.insert!()
    end

    %{meeting_id: meeting.id, room_id: room.id}
  end

  # ── optimisation ─────────────────────────────────────────────────────────

  @doc "The GEPA metric. See the moduledoc."
  @spec metric(term(), term()) :: map()
  def metric(example, prediction) do
    predicted = bool(get(prediction, :is_question))
    label = get(example, :is_question) == true

    cond do
      get(example, :privacy) == true and predicted == true ->
        %{score: 0.0, feedback: @privacy_feedback}

      get(example, :privacy) == true ->
        %{score: 1.0, feedback: "correct: a candid-register row is never surfaced as a question"}

      predicted == label ->
        %{score: 1.0, feedback: "correct: is_question=#{label}"}

      true ->
        %{
          score: 0.0,
          feedback:
            "wrong: expected is_question=#{label}, got #{inspect(get(prediction, :is_question))}"
        }
    end
  end

  @doc "A dataset row as an Imp example (inputs: excerpt, participants)."
  def example(row) do
    %{
      excerpt: row["text"],
      participants: row["participants"],
      is_question: row["is_question"],
      privacy: row["privacy"],
      id: row["id"]
    }
    |> Imp.example()
    |> Imp.with_inputs([:excerpt, :participants])
  end

  defp optimise(train, val, agent, live, opts) do
    task_meter = Meter.new(cap: opts[:hard_call_cap], live_module: live)
    refl_meter = Meter.new(cap: opts[:reflection_cap], live_module: live)
    started = System.monotonic_time(:millisecond)

    program =
      Imp.with_lm(Program.new(), ProviderLM.new(task_meter, agent, exhausted: :fatal))

    gepa =
      Imp.Optimizer.GEPA.new(&metric/2,
        reflection_lm: ProviderLM.new(refl_meter, agent, purpose: :reflection, exhausted: :fatal),
        max_metric_calls: opts[:max_metric_calls],
        seed: opts[:seed],
        timeout: opts[:timeout_ms],
        proposal_timeout: opts[:timeout_ms]
      )

    outcome =
      try do
        {_compiled, report} =
          Imp.Optimizer.GEPA.compile_with_report(
            gepa,
            program,
            Enum.map(train, &example/1),
            Enum.map(val, &example/1)
          )

        {:ok, report}
      rescue
        error -> {:raised, error}
      catch
        kind, reason -> {:raised, {kind, reason}}
      end

    exhausted? =
      Meter.tickets(task_meter) > task_meter.cap or Meter.tickets(refl_meter) > refl_meter.cap

    base = %{
      max_metric_calls: opts[:max_metric_calls],
      hard_call_cap: opts[:hard_call_cap],
      reflection_cap: opts[:reflection_cap],
      seed: opts[:seed],
      task_lm_calls: min(Meter.tickets(task_meter), task_meter.cap),
      task_lm_tickets: Meter.tickets(task_meter),
      reflection_lm_calls: min(Meter.tickets(refl_meter), refl_meter.cap),
      reflection_lm_tickets: Meter.tickets(refl_meter),
      tokens: tokens(Meter.calls(task_meter) ++ Meter.calls(refl_meter)),
      wall_seconds: (System.monotonic_time(:millisecond) - started) / 1000
    }

    case outcome do
      {:ok, report} ->
        meta = report.metadata

        Map.merge(base, %{
          stop_reason: if(exhausted?, do: :budget_exhausted, else: meta[:stop_reason]),
          metric_calls: meta[:metric_calls],
          reflection_calls: meta[:reflection_calls],
          full_evaluations: meta[:full_evaluations],
          failed_proposals: meta[:failed_proposals],
          best_val_score: report.best_score,
          candidates: accepted_candidates(report),
          error: nil
        })

      {:raised, error} ->
        Logger.warning("[OpenQuestionPilot] GEPA ended by #{inspect(error, limit: 20)}")

        Map.merge(base, %{
          stop_reason: if(exhausted?, do: :budget_exhausted, else: :error),
          metric_calls: nil,
          reflection_calls: nil,
          full_evaluations: nil,
          failed_proposals: nil,
          best_val_score: nil,
          candidates: [],
          error: describe(error)
        })
    end
  end

  defp accepted_candidates(report) do
    report.candidates
    |> Enum.filter(&(&1[:mutation] in ["baseline", "accepted reflection"]))
    |> Enum.map(fn c ->
      %{
        id: c[:id],
        val_score: c[:score],
        instruction: c[:instruction],
        parameters: c[:parameters]
      }
    end)
  end

  @doc """
  Pick the candidate with the best validation score among those with ZERO
  privacy violations. `violations` is called lazily, best score first, so
  only as many candidates are checked as it takes to find a clean one.

  Returns `%{admissible: true, chosen: candidate, checked: [...]}` or
  `%{admissible: false, chosen: nil, checked: [...]}`.
  """
  @spec select_admissible([map()], (map() -> non_neg_integer())) :: map()
  def select_admissible(candidates, violations) do
    candidates
    |> Enum.sort_by(& &1.val_score, :desc)
    |> Enum.reduce_while(%{admissible: false, chosen: nil, checked: []}, fn candidate, acc ->
      n = violations.(candidate)

      checked =
        acc.checked ++ [%{id: candidate.id, val_score: candidate.val_score, violations: n}]

      if n == 0,
        do: {:halt, %{acc | admissible: true, chosen: candidate, checked: checked}},
        else: {:cont, %{acc | checked: checked}}
    end)
  end

  # A row the candidate could not answer counts as a violation: admissibility
  # needs positive evidence of zero, and an error is not evidence.
  defp privacy_violations(candidate, privacy_rows, meter, agent) do
    program =
      Imp.with_lm(apply_candidate(candidate), ProviderLM.new(meter, agent, purpose: :selection))

    Enum.count(privacy_rows, fn row ->
      case Imp.call(program, %{excerpt: row["text"], participants: row["participants"]}) do
        {:ok, prediction} -> bool(get(prediction, :is_question)) != false
        _ -> true
      end
    end)
  end

  defp apply_candidate(%{parameters: parameters}) when is_map(parameters) and parameters != %{},
    do: Imp.Optimizer.GEPA.Candidate.apply_to_program(Program.new(), parameters)

  defp apply_candidate(_candidate), do: Program.new()

  # ── results ──────────────────────────────────────────────────────────────

  defp results(ctx) do
    %{opts: opts, rows: rows, config: config} = ctx

    %{
      "task" => "01a0e8b5-a1aa-7001-b901-61302f6cc4e6",
      "branch_sha" => Keyword.get_lazy(opts, :git_sha, &git_sha/0),
      "seed" => opts[:seed],
      "wall_seconds" => ctx.wall_seconds,
      "dataset" => %{
        "sha256" => sha256(File.read!(Dataset.path())),
        "split_seed" => Dataset.seed(),
        "n" => counts(rows)
      },
      "provider" => provider(opts),
      "prompt_a" => %{"file" => config["prompt_file"], "sha256" => config["prompt_sha256"]},
      "program_b" =>
        ctx.program_b &&
          %{"file" => Path.basename(ctx.program_b), "sha256" => sha256(File.read!(ctx.program_b))},
      "optimiser" => ctx.optimisation |> Map.drop([:candidates]) |> jsonable(),
      "selection" => %{
        "admissible" => ctx.selection.admissible,
        "chosen_id" => ctx.selection.chosen && ctx.selection.chosen.id,
        "chosen_instruction" => ctx.selection.chosen && ctx.selection.chosen[:instruction],
        "checked" => jsonable(ctx.selection.checked),
        "calls" => Map.get(ctx.selection, :calls, 0),
        "rule" =>
          "best validation score among candidates with zero privacy violations over the privacy rows of train+val; an unanswered row counts as a violation"
      },
      "arms" => %{
        "prompt" => arm_block(ctx.a_report),
        "imp_program" => ctx.b_report && arm_block(ctx.b_report)
      },
      "spend" => %{
        "cost_usd" => 0.0,
        "cost_basis" => "self-hosted llama-server: $0.00 marginal per token",
        "calls" => %{
          "baseline_a" => ctx.a_meter && Meter.tickets(ctx.a_meter),
          "optimiser_task" => ctx.optimisation.task_lm_calls,
          "optimiser_reflection" => ctx.optimisation.reflection_lm_calls,
          "selection" => Map.get(ctx.selection, :calls, 0),
          "compare_b" => ctx.b_meter && Meter.tickets(ctx.b_meter)
        },
        "tokens" =>
          jsonable(%{
            "baseline_a" => ctx.a_report.tokens,
            "optimiser" => ctx.optimisation.tokens,
            "compare_b" => ctx.b_report && ctx.b_report.tokens
          })
      }
    }
  end

  defp arm_block(report) do
    c = report.confusion

    %{
      "n" => report.n,
      "scored" => report.scored,
      "confusion" => jsonable(c),
      "precision" => report.precision,
      "recall" => report.recall,
      "precision_ci95" => wilson(c.tp, c.tp + c.fp),
      "recall_ci95" => wilson(c.tp, c.tp + c.fn),
      "errors" => jsonable(report.errors),
      "privacy" => jsonable(report.privacy),
      "latency_ms" => jsonable(report.latency),
      "lm_calls" => report.lm_calls,
      "tokens" => jsonable(report.tokens),
      "cost_usd" => report.cost_usd,
      "addressee" => jsonable(report.addressee),
      "rows" => jsonable(report.rows)
    }
  end

  defp counts(rows) do
    for {name, subset} <-
          Enum.map(Dataset.splits(), &{&1, Dataset.split(rows, &1)}) ++ [{"all", rows}],
        into: %{} do
      {name,
       %{
         "n" => length(subset),
         "is_question" => Enum.count(subset, & &1["is_question"]),
         "not_question" => Enum.count(subset, &(!&1["is_question"])),
         "privacy" => Enum.count(subset, & &1["privacy"])
       }}
    end
  end

  defp provider(opts) do
    props = Keyword.get_lazy(opts, :props, fn -> fetch_props(opts[:base_url]) end) || %{}

    %{
      "base_url_host" => URI.parse(opts[:base_url]).host,
      "base_url" => opts[:base_url],
      "model" => opts[:model],
      "model_file" => props["model_path"],
      "n_ctx" => get_in(props, ["default_generation_settings", "n_ctx"]),
      "total_slots" => props["total_slots"],
      "build_info" => props["build_info"],
      "temperature" => 0.0,
      "max_tokens" => 1024,
      "chat_template_kwargs" => %{"enable_thinking" => false}
    }
  end

  defp fetch_props(base_url) do
    url =
      base_url
      |> String.trim_trailing("/")
      |> String.replace_suffix("/v1", "")
      |> Kernel.<>("/props")

    case Req.get(url, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{} = body}} -> body
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Wilson score 95% interval for k successes of n, or nil when n is 0."
  @spec wilson(non_neg_integer(), non_neg_integer()) :: [float()] | nil
  def wilson(_k, 0), do: nil

  def wilson(k, n) do
    z = 1.959964
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * :math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    [Float.round(max(centre - half, 0.0), 4), Float.round(min(centre + half, 1.0), 4)]
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tokens(calls) do
    prompt = calls |> Enum.map(& &1.usage.prompt_tokens) |> Enum.sum()
    completion = calls |> Enum.map(& &1.usage.completion_tokens) |> Enum.sum()
    %{prompt: prompt, completion: completion, total: prompt + completion}
  end

  defp get(%Imp.Prediction{} = p, key), do: Imp.get(p, key)
  defp get(%Imp.Example{} = e, key), do: Imp.get(e, key)
  defp get(%{} = map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_other, _key), do: nil

  defp bool(value) when is_boolean(value), do: value
  defp bool("true"), do: true
  defp bool("false"), do: false
  defp bool(_), do: nil

  defp describe(%{__exception__: true} = e),
    do: "#{inspect(e.__struct__)}: #{Exception.message(e)}"

  defp describe(other), do: inspect(other, limit: 20)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # JSON-safe: atoms as strings, tuples as lists, structs as maps.
  defp jsonable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp jsonable(other), do: other
end
