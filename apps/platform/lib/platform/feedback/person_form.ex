defmodule Platform.Feedback.PersonForm do
  @moduledoc """
  The signed-in person's feedback form (task 01a1a6a5 stage 2): maps the
  form's three fields onto the `feedback_submit` structure and submits it
  through `Platform.Feedback.Submission.submit/2`, the SAME path the agent
  tool uses. Policy, redaction, bounds, dedupe, the per-person and
  installation caps and the broker all run there; this module never calls a
  publisher itself.

  ## Params

    * `"kind"` — `"problem"` (category `bug`, the text becomes
      `observed_behavior`) or `"idea"` (category `positive_change`, the text
      becomes `expected_behavior`). Anything else is `"problem"`.
    * `"text"` — the person's words. The title is its first non-blank line,
      cut to at most 80 graphemes at a word boundary plus an ellipsis.
    * `"area"` — optional, one of `Platform.Feedback.Submission.areas/0`.

  The person is the actor ONLY as `%{user_id: id}`, for rate accounting. No
  name, email or id is put into the submission, so none can reach the issue.
  """

  alias Platform.Feedback.Submission

  @title_max 80
  @ellipsis "…"

  @doc """
  Submit `params` as `user`. Returns what `Submission.submit/2` returns.
  """
  @spec submit(%{id: binary()}, map()) :: {:ok, map()} | {:error, map()}
  def submit(%{id: user_id}, params) when is_binary(user_id) and is_map(params) do
    Submission.submit(to_args(params), %{user_id: user_id})
  end

  def submit(_user, _params),
    do: {:error, %{code: :unauthorized, message: "feedback requires a signed-in person"}}

  @doc """
  The `feedback_submit` arguments a form submission maps to. Pure.
  """
  @spec to_args(map()) :: map()
  def to_args(params) do
    text = params |> Map.get("text") |> string()

    {category, field} =
      case params |> Map.get("kind") |> string() |> String.trim() do
        "idea" -> {"positive_change", "expected_behavior"}
        _ -> {"bug", "observed_behavior"}
      end

    %{"category" => category, "title" => title(text), field => text}
    |> maybe_put("area", params |> Map.get("area") |> string())
  end

  @doc """
  The issue title for `text`: its first non-blank line, at most
  #{@title_max} graphemes, cut at a word boundary with an ellipsis when it is
  longer. Blank text gives `""` (which `Submission` refuses as missing).
  """
  @spec title(String.t()) :: String.t()
  def title(text) when is_binary(text) do
    line =
      text
      |> String.split(~r/\R/u)
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != ""))
      |> String.replace(~r/\s+/u, " ")

    if String.length(line) <= @title_max, do: line, else: truncate(line)
  end

  defp truncate(line) do
    room = @title_max - String.length(@ellipsis)
    cut = String.slice(line, 0, room)

    # Cut back to the last word boundary when the cut landed inside a word.
    at_boundary? = String.at(line, room) in [" ", nil]

    trimmed =
      case {at_boundary?, String.split(cut, " ")} do
        {true, _} -> cut
        {false, [_single]} -> cut
        {false, words} -> words |> Enum.drop(-1) |> Enum.join(" ")
      end

    String.trim_trailing(trimmed) <> @ellipsis
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
