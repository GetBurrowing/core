defmodule Platform.Meetings.OpenQuestionPilot.Arm do
  @moduledoc """
  Which arm of the open_question pilot a meeting's chunks are decided
  under (task 01a0e8b5 stage 3). Called by `IntentClassifier` at its read
  point, AFTER every guard (agent speaker, no assignee, muted, no content),
  so a chunk that is never classified never creates an assignment.

  Resolution mirrors `Platform.Chat.ContextSummary`'s `resolve_arm/1`:

    * `{:variant, experiment, _slug, payload}` -> the payload's arm;
    * `{:default, payload}` (a promoted surface default) -> the payload's arm;
    * `:none`, or no meeting id -> `:prompt`.

  A program that cannot be loaded never raises into the read point
  (ADR-0052). It is caught in one of two places:

    * a VARIANT payload is re-validated by `Surfaces.resolve/4` on every
      resolution (the surface's `validate_payload/1` loads the program), so
      a broken one is refused there, logged by the resolver, and falls
      through to the surface default: with none, the control;
    * a promoted surface DEFAULT is served without re-validation, so here
      an `imp_program` arm whose program will not load logs a warning,
      emits `[:platform, :meetings, :intent_classifier, :arm_unavailable]`
      and falls back to `:prompt`.
  """

  require Logger

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Meetings.OpenQuestionPilot.Programs

  @surface "meetings.open_question_classifier"
  @target "meetings.intent_classify"

  @type t :: %{
          arm: :prompt | {:imp_program, struct()},
          name: String.t(),
          experiment_id: String.t() | nil
        }

  @doc "The surface key."
  def surface, do: @surface

  @doc "The read point's target."
  def target, do: @target

  @doc "Resolve the arm for `meeting_id`."
  @spec resolve(String.t() | nil) :: t()
  def resolve(meeting_id) when is_binary(meeting_id) do
    case Surfaces.resolve(@surface, @target, Subject.new("meeting", meeting_id)) do
      {:variant, experiment, _slug, payload} -> from_payload(payload, experiment.id, meeting_id)
      {:default, payload} -> from_payload(payload, nil, meeting_id)
      _ -> prompt(nil)
    end
  end

  def resolve(_meeting_id), do: prompt(nil)

  defp from_payload(%{"arm" => "imp_program", "program" => name}, experiment_id, meeting_id) do
    case Programs.load(name) do
      {:ok, program} ->
        %{arm: {:imp_program, program}, name: "imp_program", experiment_id: experiment_id}

      {:error, reason} ->
        Logger.warning(
          "[IntentClassifier] open_question arm imp_program unavailable, using prompt " <>
            "meeting_id=#{inspect(meeting_id)} program=#{inspect(name)} reason=#{inspect(reason)}"
        )

        :telemetry.execute(
          [:platform, :meetings, :intent_classifier, :arm_unavailable],
          %{count: 1},
          %{
            meeting_id: meeting_id,
            experiment_id: experiment_id,
            program: name,
            reason: inspect(reason)
          }
        )

        prompt(experiment_id)
    end
  end

  defp from_payload(_payload, experiment_id, _meeting_id), do: prompt(experiment_id)

  defp prompt(experiment_id), do: %{arm: :prompt, name: "prompt", experiment_id: experiment_id}
end
