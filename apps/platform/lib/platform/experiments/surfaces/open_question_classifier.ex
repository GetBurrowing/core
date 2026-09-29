defmodule Platform.Experiments.Surfaces.OpenQuestionClassifier do
  @moduledoc """
  The `meetings.open_question_classifier` surface: which program decides
  whether a meeting utterance becomes an `open_question` candidate. Task
  01a0e8b5 stage 3, on the experimentation layer of ADR-0052.

  ## Arms

    * `"prompt"` (control): today's six-way `meetings.intent_classify.v1`
      call, unchanged.
    * `"imp_program"`: arm A still runs first and keeps its other intents;
      a saved Imp program `excerpt, participants -> is_question, addressee`
      re-decides open_question / off_topic. See
      `Platform.Meetings.OpenQuestionPilot`.

  Choosing between them is DATA: an `experiments` row on this surface plus
  `experiment_variants`. Nothing is seeded. With no experiment and no
  surface default, every meeting gets the control, byte for byte what it
  got before this surface existed.

  ## Subject, target, path

  Subject `"meeting"` (id = meeting id), so the arm is sticky per meeting:
  every chunk of one meeting is decided by one arm, and a stop never moves
  a meeting that is already assigned. The one target is
  `"meetings.intent_classify"`, resolved in `IntentClassifier`'s
  `classify_and_enqueue/4` after every guard. Path `:dispatch`: the
  decision is taken inside the classifier's read point, and what it
  produces is what the dispatcher routes (ADR-0052 Decision 1). There is no
  draft for a human to see first.

  ## Payload

    * `arm` (required): `"prompt" | "imp_program"`.
    * `program`: required iff `arm` is `"imp_program"`, and absent
      otherwise. It must be a basename inside `priv/imp_pilot/open_question/`
      matching `~r/^[a-z0-9_]+\\.json$/`, naming a file that `Imp.read!/1`
      loads. This refuses traversal, absolute paths and a missing or
      corrupt artefact at validation time, before any meeting can be
      assigned the arm.
  """

  @behaviour Platform.Experiments.Surface

  import Ecto.Query

  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Repo

  @target "meetings.intent_classify"
  @arms ~w(prompt imp_program)
  @keys ~w(arm program)

  @impl true
  def key, do: "meetings.open_question_classifier"

  @impl true
  def subject_type, do: "meeting"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["arm"],
      "properties" => %{
        "arm" => %{
          "type" => "string",
          "enum" => @arms,
          "description" =>
            "prompt: the six-way intent prompt (control). imp_program: a saved Imp program re-decides open_question."
        },
        "program" => %{
          "type" => "string",
          "pattern" => "^[a-z0-9_]+\\.json$",
          "description" =>
            "Required iff arm is imp_program: basename of an Imp.save!/2 artefact in priv/imp_pilot/open_question/."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    arm = payload["arm"]
    program = payload["program"]

    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        arm not in @arms && "arm must be one of: #{Enum.join(@arms, ", ")}",
        (arm == "prompt" and Map.has_key?(payload, "program")) &&
          "program must be absent when arm is prompt"
      ] ++ program_errors(arm, program, Map.has_key?(payload, "program"))

    case Enum.filter(errors, &is_binary/1) do
      [] -> {:ok, Map.take(payload, @keys)}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  defp program_errors("imp_program", _program, false),
    do: ["program is required when arm is imp_program"]

  defp program_errors("imp_program", program, true) do
    if Programs.valid_name?(program) do
      case Programs.load(program) do
        {:ok, _program} ->
          []

        {:error, :not_found} ->
          ["program #{program} does not exist in priv/imp_pilot/open_question"]

        {:error, {:unreadable, message}} ->
          ["program #{program} is not a readable Imp program: #{message}"]
      end
    else
      ["program must be a basename matching ^[a-z0-9_]+\\.json$ (no directories)"]
    end
  end

  defp program_errors(_arm, _program, _present), do: []

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{"arm" => "prompt"}}

  @doc """
  The meeting's `org_id` (its project's) and `project_id`, for an
  org- or project-scoped experiment. Without it every scoped experiment on
  this surface answers `:no_opinion` and never assigns, which on a tenant
  install (where scientists can only create org-scoped experiments) makes
  the surface impossible to switch.

  Total: an unknown meeting, a malformed id, or a failed read is `%{}`,
  never a raise into the read point.
  """
  @impl true
  def subject_attributes(meeting_id) when is_binary(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      Repo.one(
        from(m in Platform.Meetings.Meeting,
          left_join: p in Platform.Tasks.Project,
          on: p.id == m.project_id,
          where: m.id == ^meeting_id,
          select: %{project_id: m.project_id, org_id: p.org_id}
        )
      ) || %{}
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  def subject_attributes(_meeting_id), do: %{}
end
