defmodule Platform.Experiments.Surfaces.DispatchPrompt do
  @moduledoc """
  The `dispatch.prompt` surface: which prompt template body a dispatch
  renders. Task 01a0d415, the experimentation-layer ADR-0052; the first surface,
  and the one ADR-0048 built.

  The target is a `prompt_templates.slug`. The payload is
  `%{"content" => <the FULL prompt blob>}` — ADR-0048's rejection of
  structured prompt overlays STANDS for this surface; `payload` only gives
  the blob a generic envelope. Variants written before `payload` existed keep
  their blob in `content`, and `variant_payload/1` reads it from there.

  The control is the snapshot of the template's content taken at activation,
  exactly as `Platform.Experiments.activate/2` does — `control_payload/2`
  reads the same row that function copies.
  """

  @behaviour Platform.Experiments.Surface

  import Ecto.Query

  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  @impl true
  def key, do: "dispatch.prompt"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :dispatch

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["content"],
      "properties" => %{
        "content" => %{
          "type" => "string",
          "min_length" => 1,
          "description" => "The FULL prompt template body, as it will be interpolated."
        }
      }
    }
  end

  @impl true
  def validate_payload(%{"content" => content}) when is_binary(content) and content != "",
    do: {:ok, %{"content" => content}}

  def validate_payload(%{content: content}), do: validate_payload(%{"content" => content})

  def validate_payload(_payload), do: {:error, ["content must be a non-empty string"]}

  @impl true
  def control_payload(target, _opts \\ []) when is_binary(target) do
    case Repo.get_by(PromptTemplate, slug: target) do
      %PromptTemplate{content: content} -> {:ok, %{"content" => content}}
      nil -> {:error, :template_not_found}
    end
  end

  @impl true
  def variant_payload(%Variant{payload: payload}) when is_map(payload) and map_size(payload) > 0,
    do: payload

  def variant_payload(%Variant{content: content}), do: %{"content" => content}

  @impl true
  def subject_attributes(task_id) when is_binary(task_id) do
    if Platform.UUID.valid?(task_id) do
      Repo.one(
        from(t in Platform.Tasks.Task,
          left_join: p in Platform.Tasks.Project,
          on: p.id == t.project_id,
          where: t.id == ^task_id,
          select: %{
            project_id: t.project_id,
            epic_id: t.epic_id,
            org_id: p.org_id,
            inserted_at: t.inserted_at
          }
        )
      ) || %{}
    else
      %{}
    end
  end
end
