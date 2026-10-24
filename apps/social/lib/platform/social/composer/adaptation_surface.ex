defmodule Platform.Social.Composer.AdaptationSurface do
  @moduledoc """
  The `social.composer.adaptation` experiment surface (task 01a14aca,
  Composer 1/5; ADR 0052, registered through ADR 0055's
  `Platform.Extension.experiment_surfaces/0`, never core's `@surfaces`).

  It varies HOW the composer drafts one platform's column: which prompt
  template and which model. It is a `:draft` surface: what it changes is a
  draft a human reads, edits and then sends into the approval gate. Nothing
  here touches whether, when or how a post is published.

  ## Subject and target

  The subject is one composition (`subject_type` `"social_composition"`, the
  composition id `Platform.Social.Composer.adapt/3` returns). The target is
  the platform (`linkedin`, `x`, `instagram`), so an experiment runs per
  platform and its metric (approval rate, edits before approve) is per
  platform. The `Platform.Experiments.Assignment` row is the single record
  of which arm a composition saw; posts carry only the composition id.

  ## Payload

  `%{"prompt_slug" => string (required, a `social.composer.` slug, at most
  255 chars), "model" => string (optional, at most 128 chars)}`. No model
  means the drafting agent's own model. The control is the config default:
  the platform's `.v1` slug and `config :social, :composer, model:`.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Social.Composer
  alias Platform.Social.Composer.Prompts

  @max_slug 255
  @max_model 128
  @keys ["prompt_slug", "model"]

  @impl true
  def key, do: "social.composer.adaptation"

  @impl true
  def subject_type, do: "social_composition"

  @impl true
  def path, do: :draft

  @impl true
  def targets, do: Prompts.platforms()

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["prompt_slug"],
      "properties" => %{
        "prompt_slug" => %{
          "type" => "string",
          "min_length" => 1,
          "max_length" => @max_slug,
          "description" =>
            "The prompt_templates slug that adapts the idea for this platform; " <>
              "must start with social.composer."
        },
        "model" => %{
          "type" => "string",
          "max_length" => @max_model,
          "description" => "Model name passed to the drafting agent's provider. Omit for its own."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    slug = field(payload, "prompt_slug", :prompt_slug)
    model = field(payload, "model", :model)

    case slug_errors(slug) ++ model_errors(model) ++ unknown_key_errors(payload) do
      [] -> {:ok, normalize(slug, model)}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(target, _opts \\ []) do
    if target in Prompts.platforms() do
      {:ok, normalize(Prompts.adapt_slug(target), Composer.config(:model))}
    else
      {:error, :unknown_target}
    end
  end

  defp field(payload, key, atom), do: Map.get(payload, key, Map.get(payload, atom))

  defp slug_errors(slug) when is_binary(slug) do
    trimmed = String.trim(slug)

    cond do
      trimmed == "" ->
        ["prompt_slug must be a non-empty string"]

      String.length(trimmed) > @max_slug ->
        ["prompt_slug must be at most #{@max_slug} chars"]

      not String.starts_with?(trimmed, "social.composer.") ->
        ["prompt_slug must start with social.composer."]

      true ->
        []
    end
  end

  defp slug_errors(_slug), do: ["prompt_slug must be a non-empty string"]

  defp model_errors(nil), do: []

  defp model_errors(model) when is_binary(model) do
    if String.length(model) > @max_model,
      do: ["model must be at most #{@max_model} chars"],
      else: []
  end

  defp model_errors(_model), do: ["model must be a string"]

  defp unknown_key_errors(payload) do
    case Enum.reject(Map.keys(payload), &(to_string(&1) in @keys)) do
      [] ->
        []

      keys ->
        ["unknown keys: #{keys |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"]
    end
  end

  defp normalize(slug, model) do
    base = %{"prompt_slug" => String.trim(slug)}

    case model && String.trim(model) do
      nil -> base
      "" -> base
      trimmed -> Map.put(base, "model", trimmed)
    end
  end
end
