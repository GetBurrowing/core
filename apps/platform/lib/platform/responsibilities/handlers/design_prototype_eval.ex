defmodule Platform.Responsibilities.Handlers.DesignPrototypeEval do
  @moduledoc """
  `design.prototype_eval`: score a prototype the designer published (UX
  super agent spec, L3; task 01a1f048).

  ## Trigger

  `event_topic`, fired directly by `Platform.Designer.Loop` when the
  designer's `prototype_publish` succeeds, with the prototype id and
  version.

  ## Two paths, decided by configuration, never by the designer

    * **Evaluator configured** (`Platform.Designer.Evaluator.status/0` is
      `:ok`): the server grades the published bundle on the OpenAI model,
      saves the scorecard as a page in the designer's private
      `evaluations/` folder, fires `design.reflect` with it, and returns
      `{:handled, summary}`. Nothing is dispatched to the designer, which
      never sees the rubric and cannot grade itself.
    * **Not configured** (the default): the designer is dispatched a prompt
      to run its read-only `critic` subagent against the same five criteria
      and journal the result as a SELF-assessment, which is not evidence
      and moves no card.

  An unreadable prototype version is a refusal (`:prototype_not_found`),
  never an evaluation of nothing.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Designer.Cards
  alias Platform.Designer.Evaluator
  alias Platform.Designer.Loop
  alias Platform.Org.Wiki
  alias Platform.Prototypes
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles

  @key "design.prototype_eval"
  @feature "design"
  @template_slug "design.prototype_eval.v1"

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
        trigger_config: %{"topic" => "prototype:published"},
        scope: "global",
        context_provided: ["prototype", "scorecard"],
        output_contract: %{},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "role" => "designer",
          "status" => "active",
          "loop" => "L3"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{}, ctx) when is_map(ctx) do
    payload = Map.get(ctx, :payload) || %{}
    prototype_id = fetch(ctx, :prototype_id) || fetch(payload, :prototype_id)
    version = to_int(fetch(ctx, :version) || fetch(payload, :version))

    with {:ok, html} <- prototype_html(prototype_id, version) do
      label = "prototype #{prototype_id} v#{version}"

      case Evaluator.status() do
        :ok -> evaluate(prototype_id, version, html, label)
        _ -> {:ok, %{prototype_id: prototype_id, version: version, evaluator: :off}}
      end
    end
  end

  def gather_context(_responsibility, _ctx), do: {:error, :prototype_not_found}

  @impl true
  def build_prompt(context) when is_map(context) do
    system =
      "You are the designer on this Burrow install. A prototype you published needs a score, " <>
        "and no independent evaluator is configured on this install."

    user = """
    ## Prototype

    #{Map.get(context, :prototype_id)} version #{Map.get(context, :version)}

    ## Do this

    1. Spawn your read-only `critic` subagent on this prototype. Ask it to score each criterion from 1 to 5: task_success, steps_to_goal, clarity, consistency, accessibility, and to name the single most serious issue.
    2. Write ONE journal entry with the scores, marked SELF-ASSESSMENT. It is not evidence: it moves no card's weight and does not count as an evaluator score.
    3. If the critic found a blocker, fix it and publish a new version rather than defending it.
    """

    {:ok, %{system: system, user: String.trim_trailing(user)}}
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta), do: :ok

  # ── internals ──

  defp evaluate(prototype_id, version, html, label) do
    agent = assignee()

    case Evaluator.grade(html, label) do
      {:ok, card} ->
        path = save_scorecard(agent, prototype_id, version, card)

        if agent do
          Loop.job_finished(agent.id, "prototype_publish", %{
            prototype_id: prototype_id,
            scorecard: card,
            scorecard_path: path
          })
        end

        {:handled, %{evaluator: :graded, overall: card.overall, scorecard_path: path}}

      {:error, reason} ->
        Logger.warning(
          "[design.prototype_eval] evaluator failed (#{inspect(reason)}); " <>
            "falling back to the designer's critic"
        )

        {:ok, %{prototype_id: prototype_id, version: version, evaluator: {:failed, reason}}}
    end
  end

  defp save_scorecard(%Agent{} = agent, prototype_id, version, card) do
    case Cards.prefix(agent) do
      nil ->
        nil

      prefix ->
        path =
          String.replace_suffix(prefix, "patterns/", "evaluations/") <>
            "#{prototype_id}-v#{version}.md"

        content = """
        ---
        kind: evaluation
        prototype_id: "#{prototype_id}"
        version: #{version}
        overall: #{card.overall}
        model: "#{card[:model] || "unknown"}"
        graded_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
        ---
        # Evaluator scorecard: prototype #{prototype_id} v#{version}

        Graded by an independent model from a different vendor than the designer.

        #{Enum.map_join(card.scores, "\n", fn {k, v} -> "- #{k}: #{v}/5" end)}

        Top issue: #{card.top_issue || "none named"}

        #{card.notes || ""}
        """

        case Wiki.upsert_page(path, %{content: content, updated_by: agent.id}) do
          {:ok, _} -> path
          {:error, _} -> nil
        end
    end
  end

  defp save_scorecard(_agent, _prototype_id, _version, _card), do: nil

  defp prototype_html(id, version) when is_binary(id) and is_integer(version) do
    case Prototypes.embed_html(id, version) do
      {:ok, html} when is_binary(html) -> {:ok, html}
      _ -> {:error, :prototype_not_found}
    end
  rescue
    _ -> {:error, :prototype_not_found}
  end

  defp prototype_html(_id, _version), do: {:error, :prototype_not_found}

  defp assignee do
    case Roles.assignee_for(@key) do
      %{id: id} when is_binary(id) -> Platform.Repo.get(Agent, id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_map, _key), do: nil
end
