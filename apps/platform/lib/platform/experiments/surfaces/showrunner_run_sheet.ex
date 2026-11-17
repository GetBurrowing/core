defmodule Platform.Experiments.Surfaces.ShowrunnerRunSheet do
  @moduledoc """
  The `showrunner.run_sheet` surface: which prompt drafts a How to Computer
  episode's run sheet, and what directive rides with it. Task 01a1eaf6
  stage 1, on the experimentation layer of ADR-0052.

  ## Subject, target, path

  Subject `"episode"`, id = the episode the run sheet is drafted for. One
  target, `"showrunner.run_sheet"`. Path `:dispatch`: the arm is resolved
  inside the showrunner's run-sheet dispatch and consumed there.

  ## Payload

    * `prompt_slug`: required, a string starting with `showrunner.run_sheet`,
      the prompt template the run sheet is drafted from.
    * `directive`: a string (at most 4000 chars) rendered into the prompt as
      its experiment directive, or nil for none. Blank normalises to nil.

  The control is `%{"prompt_slug" => "showrunner.run_sheet.v1",
  "directive" => nil}`: the seeded slug with no directive.

  ## Metric

  The share of run-sheet segments kept on air
  (`Platform.Showrunner.Episode.kept_share/1`, recorded at retro); the
  secondary metric is the performance of clips cut from each segment.
  """

  @behaviour Platform.Experiments.Surface

  @target "showrunner.run_sheet"
  @slug_prefix "showrunner.run_sheet"
  @control_slug "showrunner.run_sheet.v1"
  @keys ~w(prompt_slug directive)
  @max_directive 4000
  @max_slug 128
  @control %{"prompt_slug" => @control_slug, "directive" => nil}

  @impl true
  def key, do: "showrunner.run_sheet"

  @impl true
  def subject_type, do: "episode"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @doc "The one target this surface is resolved at."
  @spec target() :: String.t()
  def target, do: @target

  @doc "The control payload: the seeded slug, no directive."
  @spec control() :: map()
  def control, do: @control

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["prompt_slug"],
      "properties" => %{
        "prompt_slug" => %{
          "type" => "string",
          "pattern" => "^showrunner\\.run_sheet",
          "maxLength" => @max_slug,
          "description" =>
            "Prompt template slug the run sheet is drafted from. Control: #{@control_slug}."
        },
        "directive" => %{
          "type" => ["string", "null"],
          "maxLength" => @max_directive,
          "description" =>
            "Text rendered into the run-sheet prompt as an experiment directive. Null for none (control)."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    slug = Map.get(payload, "prompt_slug")
    directive = normalise_directive(Map.get(payload, "directive"))

    errors =
      [
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        not valid_slug?(slug) &&
          "prompt_slug must be a string starting with #{@slug_prefix} (at most #{@max_slug} chars)",
        directive == :invalid && "directive must be a string or null",
        (is_binary(directive) and String.length(directive) > @max_directive) &&
          "directive must be at most #{@max_directive} chars"
      ]
      |> Enum.filter(&is_binary/1)

    case errors do
      [] -> {:ok, %{"prompt_slug" => slug, "directive" => directive}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, @control}

  @impl true
  def render_directive(%{"directive" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def render_directive(_payload), do: nil

  defp valid_slug?(slug) when is_binary(slug),
    do: String.starts_with?(slug, @slug_prefix) and String.length(slug) <= @max_slug

  defp valid_slug?(_slug), do: false

  defp normalise_directive(nil), do: nil

  defp normalise_directive(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalise_directive(_other), do: :invalid
end
