defmodule Platform.Responsibilities.Handlers.DesignReflect do
  @moduledoc """
  `design.reflect`: the designer reflects after each design job (L4 of the
  UX super agent spec; task 01a1f048).

  ## Trigger

  `event_topic`, fired directly by `Platform.Designer.Loop` (the topic is
  documentation, the `design.task_direction` convention) when the designer
  finishes a job: a critique returned, direction attached or declined, or a
  prototype's evaluation landed. The Router resolves the assignee first, so
  an unassigned key never reaches here.

  ## What the server does before the prompt

  `gather_context/2` applies settled post-ship outcomes to the card weights
  (`Platform.Designer.Cards.reweigh/2`), so the moves the reflection reads
  are already made, and reads the install's friction drop
  (`Platform.Ux.FrictionDrop.summary/1`). Neither is a model call.

  ## The prompt

  Owned here (`build_prompt/1`), like `design.critique`, so a hand-edited DB
  template cannot change what the designer is told to do with its own
  confidence. The rules are the manifest's: one journal entry, outcome
  evidence only, a reflection-only raise capped at 0.7, never a prompt edit.
  The phase 1 end-of-job instruction in `design.task_direction.v1` stays;
  this prompt tells the designer not to write a second entry for a job it
  already journaled.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Designer.Cards
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Ux.FrictionDrop

  @key "design.reflect"
  @feature "design"
  @template_slug "design.reflect.v1"

  @doc "Canonical key."
  @spec key() :: String.t()
  def key, do: @key

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "design:job_finished"},
        scope: "global",
        context_provided: ["job", "card_moves", "friction_drop", "scorecard"],
        output_contract: %{},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "role" => "designer",
          "status" => "active",
          "loop" => "L4"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{}, ctx) when is_map(ctx) do
    agent = assignee()
    payload = Map.get(ctx, :payload) || %{}

    {:ok,
     %{
       job: fetch(ctx, :job) || fetch(payload, :job) || "design job",
       task_id: fetch(ctx, :task_id) || fetch(payload, :task_id),
       canvas_id: fetch(ctx, :canvas_id) || fetch(payload, :canvas_id),
       scorecard: fetch(ctx, :scorecard),
       scorecard_path: fetch(ctx, :scorecard_path),
       card_prefix: agent && Cards.prefix(agent),
       card_moves: card_moves(agent),
       friction_drop: safe_friction_drop()
     }}
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def build_prompt(context) when is_map(context) do
    system =
      "You are the designer on this Burrow install, finishing one job. Reflect on it in ONE " <>
        "journal entry and update pattern cards only on outcome evidence. You never edit a " <>
        "prompt template, this one included."

    user = """
    ## The job that just ended

    #{job_line(context)}

    #{scorecard_block(context)}

    ## Pattern cards

    Your cards live at `#{Map.get(context, :card_prefix) || "space/<your space id>/private/<your agent id>/patterns/"}`.
    #{moves_block(Map.get(context, :card_moves))}

    ## Friction after ship (your north star)

    #{drop_line(Map.get(context, :friction_drop))}

    ## Do this

    1. If you already wrote a journal entry for this job, stop here.
    2. Otherwise write ONE entry in your private journal: what you did and which cards you used; what you would do differently; which cards should move and why.
    3. For each card this job used, add the task id to its `used_in_tasks` list (frontmatter) when the work is tied to a task, so the server can weigh it after ship. Do not edit `weight` for an outcome move; the server applies those.
    4. You may raise a card on evidence from this job only up to 0.7, and only on evidence: an evaluator score, a kept finding, a merged change. A human agreeing with you is not evidence and never raises a card.
    5. A pattern that failed becomes a "don't" card, kept, not deleted.
    6. `memory_view` the exact path before `memory_create`: create overwrites.
    """

    {:ok, %{system: system, user: String.trim_trailing(user)}}
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    # The designer writes its journal and cards with tools; a reply carries
    # nothing to persist.
    :ok
  end

  # ── internals ──

  defp assignee do
    case Roles.assignee_for(@key) do
      %{id: id} when is_binary(id) -> Platform.Repo.get(Agent, id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp card_moves(%Agent{} = agent) do
    case Cards.reweigh(agent) do
      {:ok, moves} -> moves
      _ -> []
    end
  rescue
    error ->
      Logger.warning("[design.reflect] reweigh raised: #{Exception.message(error)}")
      []
  end

  defp card_moves(_agent), do: []

  defp safe_friction_drop do
    FrictionDrop.summary() |> Map.drop([:outcomes])
  rescue
    _ -> nil
  end

  defp job_line(context) do
    [
      "Job: #{Map.get(context, :job)}",
      Map.get(context, :task_id) && "Task: #{Map.get(context, :task_id)}",
      Map.get(context, :canvas_id) && "Canvas: #{Map.get(context, :canvas_id)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp scorecard_block(context) do
    case Map.get(context, :scorecard) do
      %{} = card ->
        """
        ## Independent evaluator scorecard (a different vendor's model graded this)

        #{Jason.encode!(Map.take(card, [:scores, :overall, :top_issue, :notes, "scores", "overall", "top_issue", "notes"]))}
        #{if p = Map.get(context, :scorecard_path), do: "Saved at `#{p}`.", else: ""}
        This is evidence. Use it.
        """
        |> String.trim_trailing()

      _ ->
        ""
    end
  end

  defp moves_block([]), do: "No card weights moved since the last reflection."

  defp moves_block(moves) when is_list(moves) do
    "The server just moved these weights from post-ship outcomes:\n" <>
      Enum.map_join(moves, "\n", fn m ->
        "- #{m.path}: task #{m.task_id}, friction drop #{inspect(m.drop)}, #{m.from} -> #{m.to}"
      end)
  end

  defp moves_block(_), do: ""

  defp drop_line(%{value: value, n: n, pending: pending}) when is_float(value),
    do:
      "Pooled friction drop #{Float.round(value, 2)} over #{n} shipped finding(s); #{pending} " <>
        "still inside their 4-week window."

  defp drop_line(%{pending: pending}),
    do: "No settled post-ship outcome yet; #{pending} shipped finding(s) inside their window."

  defp drop_line(_), do: "Not available."

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_map, _key), do: nil
end
