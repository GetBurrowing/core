defmodule Platform.Experiments.Surfaces.MailDraftGenerator do
  @moduledoc """
  The `mail.draft.generator` surface: which generator (and optional
  directive) a job-application task uses to WRITE its resume, cover letter
  and application draft. Task 01a0d415 stage 4, the experimentation-layer
  ADR-0052.

  ## What it governs, and what it never does

  It governs how an application is GENERATED. It never governs whether an
  application is sent, when, or how. There is no send-path surface anywhere
  in the registry (`Platform.Experiments.Surface` has no `:send` path), and
  the Mail send path (`Mail.Sender`, `Mail.Outbox`, delivery) reads nothing
  from the experiments layer. An arm's directive reaches the executor as
  text in its dispatch prompt; any draft it writes still goes through the
  normal draft review before anything leaves the system.

  ## Where it is resolved

  At the executor dispatch (`dispatch.in_progress`, see
  `Platform.Orchestration.HeartbeatScheduler.append_experiment_directive/4`),
  NOT inside `mail_draft_create`. The generator choice must reach the agent
  before it writes the resume and cover letter; the draft tool fires after
  generation and is agent-optional. Sticky assignment means planning, every
  stage and any re-dispatch of the same task see the same generator.

  The surface is resolved on EVERY in_progress render. Only the experiment's
  scope (its `org_id` / `project_id` columns plus its `assignment_policy`)
  keeps it off non-job tasks, so an out-of-scope render is byte-identical to
  a render with no experiment at all.

  ## Target

  The only target is `"dispatch.in_progress"` (`targets/0`). An experiment
  created on any other target would never be resolved, so
  `experiment_create` refuses one.

  ## Payload

  `%{"generator" => string (required, at most 64 chars), "directive" =>
  string (optional, at most 4000 chars)}`, e.g. generator `voice_model` or
  `claude`. The control is `%{"generator" => "default"}` with no directive,
  and renders no directive block.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Experiments.Surfaces.DispatchPrompt

  @target "dispatch.in_progress"
  @control_generator "default"
  @max_generator 64
  @max_directive 4000

  @impl true
  def key, do: "mail.draft.generator"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :draft

  @doc "The dispatch slugs this surface is resolved at."
  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["generator"],
      "properties" => %{
        "generator" => %{
          "type" => "string",
          "min_length" => 1,
          "max_length" => @max_generator,
          "description" =>
            "Which generator writes the application, e.g. voice_model or claude. " <>
              "\"default\" is the control."
        },
        "directive" => %{
          "type" => "string",
          "max_length" => @max_directive,
          "description" => "Optional free-text instruction on how to write the application."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    generator = field(payload, "generator", :generator)
    directive = field(payload, "directive", :directive)

    errors =
      generator_errors(generator) ++ directive_errors(directive) ++ unknown_key_errors(payload)

    case errors do
      [] -> {:ok, normalize(generator, directive)}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{"generator" => @control_generator}}

  @impl true
  def render_directive(%{"generator" => @control_generator} = payload) do
    case Map.get(payload, "directive") do
      nil -> nil
      directive -> "Generator: #{@control_generator}\n\n#{directive}"
    end
  end

  def render_directive(%{"generator" => generator} = payload) do
    case Map.get(payload, "directive") do
      nil -> "Generator: #{generator}"
      directive -> "Generator: #{generator}\n\n#{directive}"
    end
  end

  def render_directive(_payload), do: nil

  @impl true
  defdelegate subject_attributes(task_id), to: DispatchPrompt

  defp field(payload, key, atom), do: Map.get(payload, key, Map.get(payload, atom))

  defp generator_errors(g) when is_binary(g) do
    cond do
      String.trim(g) == "" -> ["generator must be a non-empty string"]
      String.length(g) > @max_generator -> ["generator must be at most #{@max_generator} chars"]
      true -> []
    end
  end

  defp generator_errors(_g), do: ["generator must be a non-empty string"]

  defp directive_errors(nil), do: []

  defp directive_errors(d) when is_binary(d) do
    if String.length(d) > @max_directive,
      do: ["directive must be at most #{@max_directive} chars"],
      else: []
  end

  defp directive_errors(_d), do: ["directive must be a string"]

  defp unknown_key_errors(payload) do
    case Enum.reject(Map.keys(payload), &(to_string(&1) in ["generator", "directive"])) do
      [] ->
        []

      keys ->
        ["unknown keys: #{keys |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"]
    end
  end

  # A blank directive is the same as none, so the control stays blockless.
  defp normalize(generator, directive) do
    base = %{"generator" => String.trim(generator)}

    case directive && String.trim(directive) do
      nil -> base
      "" -> base
      trimmed -> Map.put(base, "directive", trimmed)
    end
  end
end
