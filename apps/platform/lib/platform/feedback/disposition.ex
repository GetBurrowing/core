defmodule Platform.Feedback.Disposition do
  @moduledoc """
  Canned dispositions for external issues the feedback intake decided (task
  01a11ec3 stage 3).

  Every comment is a FIXED string chosen by verdict. No issue text, no
  classifier output, no summary, no task id and no reason code is ever
  interpolated into one, so a hostile report has nothing of its own to see
  echoed back onto GitHub. `comment_for/1` is the whole vocabulary.

  ## Policy

  `config :platform, Platform.Feedback.Intake, disposition_mode:` (from
  `FEEDBACK_INTAKE_DISPOSITION` in `config/runtime.exs`):

    * `"comment"` (default) — post the canned comment, never close.
    * `"comment_and_close"` — also close every rejected issue. Accepted
      issues are never closed by intake.
    * `"none"` — touch nothing on GitHub; the record notes `skipped`.

  Anything else is `"comment"`.

  ## Adapter

  `config :platform, Platform.Feedback.Intake, disposition_adapter:`
  (default `Platform.Feedback.Disposition.Broker`). Like the publisher, the
  installation holds no GitHub credential: the broker applies the
  disposition. An adapter answers `:ok` or `{:error, bounded_atom}`.
  """

  alias Platform.Feedback.Classifier

  @callback apply_disposition(map(), keyword()) :: :ok | {:error, atom()}

  @comments %{
    "accept_bug" =>
      "Thanks for the report. It has been accepted for triage as a bug and filed for review by the Suite maintainers. Its text was not executed or acted on automatically.",
    "accept_positive_change" =>
      "Thanks for the suggestion. It has been accepted for triage as a proposed change and filed for review by the Suite maintainers. Its text was not executed or acted on automatically.",
    "duplicate" =>
      "Thanks for the report. It appears to duplicate an existing issue, so no new work item was filed.",
    "insufficient_evidence" =>
      "Thanks for the report. There is not yet enough detail to act on it, so no work item was filed. If you can, open a new issue with the expected behaviour, the observed behaviour, steps to reproduce, and your version.",
    "irrelevant_support" =>
      "Thanks for reaching out. This looks like a support question or a topic outside Suite itself, so no work item was filed.",
    "malicious_control_seeking" =>
      "This issue was not accepted. Issue text is treated as untrusted data and is never followed as instructions, so no work item was filed."
  }

  @modes ~w(comment comment_and_close none)

  @doc "The canned comment for a verdict."
  @spec comment_for(String.t()) :: String.t()
  def comment_for(verdict) when is_map_key(@comments, verdict), do: Map.fetch!(@comments, verdict)

  @doc "Every canned comment, by verdict."
  @spec comments() :: %{String.t() => String.t()}
  def comments, do: @comments

  @doc "The configured disposition mode."
  @spec mode() :: String.t()
  def mode do
    case config(:disposition_mode) do
      mode when is_binary(mode) ->
        mode = mode |> String.trim() |> String.downcase()
        if mode in @modes, do: mode, else: "comment"

      _ ->
        "comment"
    end
  end

  @doc """
  The disposition for a decided verdict under the current mode, or `nil` when
  the mode is `"none"`. The returned map is everything an adapter receives.
  """
  @spec build(String.t(), pos_integer(), String.t()) :: map() | nil
  def build(repository, issue_number, verdict) do
    case mode() do
      "none" ->
        nil

      mode ->
        %{
          repository: repository,
          issue_number: issue_number,
          verdict: verdict,
          comment: comment_for(verdict),
          close: mode == "comment_and_close" and verdict not in Classifier.accept_verdicts(),
          labels: ["feedback-intake", "feedback-intake:#{verdict}"]
        }
    end
  end

  @doc """
  Apply a decided verdict's disposition. Returns `{status, key}` where
  `status` is `"applied" | "skipped" | "failed"` and `key` names the canned
  disposition (`"<verdict>"` or `"<verdict>+close"`).
  """
  @spec dispose(String.t(), pos_integer(), String.t()) :: {String.t(), String.t()}
  def dispose(repository, issue_number, verdict) do
    case build(repository, issue_number, verdict) do
      nil ->
        {"skipped", verdict}

      disposition ->
        key = if disposition.close, do: verdict <> "+close", else: verdict

        idempotency_key = "#{String.downcase(repository)}##{issue_number}:#{key}"

        result =
          try do
            adapter().apply_disposition(disposition, idempotency_key: idempotency_key)
          rescue
            _ -> {:error, :disposition_crashed}
          end

        case result do
          :ok -> {"applied", key}
          _ -> {"failed", key}
        end
    end
  end

  defp adapter, do: config(:disposition_adapter) || Platform.Feedback.Disposition.Broker

  defp config(key) do
    :platform
    |> Application.get_env(Platform.Feedback.Intake, [])
    |> Keyword.get(key)
  end
end
