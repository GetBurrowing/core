defmodule Platform.Design.Critique.Verdict do
  @moduledoc """
  Parse and render a design critique reply (task `019fe844` stage 2).

  ## Fall open, always

  An unparseable reply returns
  `%{issues: [], raw: content, unparseable?: true}` — never an error, never
  a raise. The consumer of this verdict is a HUMAN GATE: a malformed model
  reply must not be able to park a review request, and the prose the model
  did produce is still worth putting in front of the reviewer, who can read
  it perfectly well without a JSON envelope. Same posture, and the same
  reasoning, as `Handlers.ArchitectureReviewPlan.parse_verdict/2`'s
  documented fall-open.

  ## Tolerated shapes

  `Platform.ExternalAgents.ContractValidator` classifies this
  responsibility's `%{"issues" => "list[map]"}` contract as `:unknown` and
  therefore FREEFORM, so the dispatcher hands back a raw content binary,
  not a decoded map. Three shapes have to land:

    * a map already carrying `"issues"` (a future contract kind, or a
      caller passing pre-parsed output),
    * a bare JSON object as the whole body,
    * a ```` ```json ```` fence with prose either side of it — the common
      case, not the exception.
  """

  @type t :: %{
          issues: [map()],
          raw: binary(),
          unparseable?: boolean()
        }

  @doc "Parse a dispatcher reply into a critique. Never raises, never errors."
  @spec parse(term()) :: t()
  def parse(%{"issues" => issues} = output) when is_list(issues) do
    %{issues: normalize_issues(issues), raw: encode(output), unparseable?: false}
  end

  def parse(%{issues: issues} = output) when is_list(issues) do
    %{issues: normalize_issues(issues), raw: encode(output), unparseable?: false}
  end

  def parse(content) when is_binary(content) do
    case decode_embedded_json(content) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        %{issues: normalize_issues(issues), raw: content, unparseable?: false}

      _ ->
        %{issues: [], raw: content, unparseable?: true}
    end
  end

  def parse(other), do: %{issues: [], raw: encode(other), unparseable?: true}

  @doc """
  Render a critique as the markdown that lands on the review request and
  in the execution space.

  An unparseable reply renders its RAW PROSE rather than "no issues
  raised": the two are opposite facts, and collapsing them would tell a
  reviewer the design is sound when in truth nobody could read the answer.
  """
  @spec render(t()) :: binary()
  def render(%{unparseable?: true, raw: raw}) do
    """
    **Design review (Saru)** — reply could not be parsed as the expected
    JSON contract. Raw response, verbatim:

    #{String.trim(to_string(raw))}
    """
    |> String.trim()
  end

  def render(%{issues: []}) do
    "**Design review (Saru)** — no issues raised."
  end

  def render(%{issues: issues}) when is_list(issues) do
    body = Enum.map_join(issues, "\n\n", &render_issue/1)

    "**Design review (Saru)** — #{length(issues)} issue(s):\n\n" <> body
  end

  def render(_other), do: "**Design review (Saru)** — no verdict available."

  # ── Internals ─────────────────────────────────────────────────────────────

  defp render_issue(issue) when is_map(issue) do
    severity = string_at(issue, "severity") || "unspecified"
    location = string_at(issue, "location") || "(location not given)"
    text = string_at(issue, "issue") || "(no description)"
    suggestion = string_at(issue, "suggestion")

    base = "- **[#{severity}] #{location}** — #{text}"

    if suggestion, do: base <> "\n  - Suggestion: #{suggestion}", else: base
  end

  defp render_issue(other), do: "- #{inspect(other)}"

  defp string_at(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      nil -> nil
      other -> to_string(other)
    end
  rescue
    ArgumentError -> nil
  end

  # Keep only map-shaped entries; a model that emitted `["too grey"]`
  # produced prose in a list, not issues, and passing it through would
  # make `render_issue/1` the place that discovers it.
  defp normalize_issues(issues) do
    Enum.map(issues, fn
      issue when is_map(issue) -> stringify_keys(issue)
      other -> %{"issue" => to_string_safe(other)}
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  # Cheapest candidate first: the whole trimmed body, then each fenced
  # block, then the widest brace span.
  defp decode_embedded_json(binary) do
    candidates = [String.trim(binary)] ++ fenced_blocks(binary) ++ brace_span(binary)

    Enum.find_value(candidates, :error, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{"issues" => issues} = map} when is_list(issues) -> {:ok, map}
        _ -> nil
      end
    end)
  end

  defp fenced_blocks(binary) do
    ~r/```(?:[a-zA-Z0-9_-]+)?[ \t]*\r?\n?(.*?)```/s
    |> Regex.scan(binary, capture: :all_but_first)
    |> Enum.map(fn [body] -> String.trim(body) end)
  end

  defp brace_span(binary) do
    with [{open, _} | _] <- :binary.matches(binary, "{"),
         [_ | _] = closes <- :binary.matches(binary, "}"),
         {close, len} <- List.last(closes),
         true <- close + len > open do
      [binary_part(binary, open, close + len - open)]
    else
      _ -> []
    end
  end

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      _ -> inspect(term)
    end
  end
end
