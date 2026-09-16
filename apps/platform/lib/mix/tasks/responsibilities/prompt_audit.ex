defmodule Mix.Tasks.Responsibilities.PromptAudit do
  @moduledoc """
  Print every registered responsibility's declared prompt-template slug and
  whether a row actually carries it (task `01a0a74d` stage 3, acceptance
  item 5).

  ## Why this exists as a command rather than a one-off measurement

  `memory.daily_summary.v1` was declared by a cron responsibility, named in
  source, fired nightly at 23:00 UTC, and had no row. Nothing failed. The
  Historian — the one agent with write access to org-wide pages — received
  an empty prompt and nothing errored. Fixing that one slug protects
  nothing: the next declaration with a typo'd slug fails identically and
  just as quietly. This task makes the sweep repeatable, so the question
  "is any responsibility dispatching an empty prompt right now?" is a
  command anyone can run against any install rather than an investigation
  somebody has to repeat.

  ## Exit status

  Exits **non-zero when any CRON-triggered key reads MISSING or BLANK**.
  Cron is the discriminator on purpose: an unattended clock fire has no
  human in the loop to notice a degraded answer, so it is the case worth
  failing a wrapper over.

  A non-cron key that reads MISSING is **printed and does not fail the
  run**. That is the rule behaving correctly, not a hole in it. At the time
  of writing `meetings.summarize.v1` is exactly that case: declared by
  `Handlers.MeetingSummarize.register/0`, trigger `event`
  (`meeting_finished`), no descriptor and no row. It degrades to a legacy
  fallback MFA rather than to an empty prompt, it only fires behind a
  meeting a human just held, and deciding what body it should get is a
  different piece of work with a different owner. **Do not widen the exit
  rule to catch it and do not seed it to make the table read clean** — the
  row is here to be seen, and losing the distinction between "fires
  unattended on a clock" and "fires behind a human" is the point of having
  a rule at all.

  ## Usage

      mix responsibilities.prompt_audit

  ## Example output

      Responsibilities prompt-template audit
      ======================================

      KEY                             TRIGGER     SLUG                            VERDICT
      memory.daily_summary            cron        memory.daily_summary.v1         RESOLVED
      meetings.summarize              event       meetings.summarize.v1           MISSING
      chat.triage                     event       (none)                          none

      34 responsibilities · 33 resolved · 1 missing · 0 blank · 0 declaring no template
      OK — no cron-triggered responsibility names a missing or blank template.
  """
  use Mix.Task

  alias Platform.Responsibilities

  @shortdoc "Audit every responsibility's declared prompt template against the templates table."

  # `trigger_kind` values that fire with nobody watching. Kept as a list
  # rather than `== "cron"` so a future unattended trigger is a one-word
  # change at the place the rule is stated.
  @unattended_triggers ~w(cron)

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:platform)

    entries = Responsibilities.prompt_template_audit()

    Mix.shell().info(format_report(entries))

    failures = failing_entries(entries)

    if failures == [] do
      Mix.shell().info("OK — no cron-triggered responsibility names a missing or blank template.")

      :ok
    else
      Mix.shell().error(
        "FAIL — #{length(failures)} cron-triggered responsibilit#{plural(failures)} " <>
          "name a template that is missing or blank: " <>
          Enum.map_join(failures, ", ", fn e -> "#{e.key} -> #{slug_of(e)}" end)
      )

      exit({:shutdown, 1})
    end
  end

  @doc false
  # Public for tests: renders an arbitrary entry list without standing up
  # a database, and lets the sort/column contract be asserted directly.
  @spec format_report([map()]) :: String.t()
  def format_report(entries) when is_list(entries) do
    rows =
      entries
      |> Enum.sort_by(& &1.key)
      |> Enum.map_join("\n", &format_row/1)

    """

    Responsibilities prompt-template audit
    ======================================

    #{header()}
    #{rows}

    #{summary_line(entries)}
    """
  end

  @doc false
  # Public for tests: the exit rule is the deliverable, so it is asserted
  # directly rather than inferred from the printed text. A text assertion
  # on a runbook is not an assertion of its effect.
  @spec failing_entries([map()]) :: [map()]
  def failing_entries(entries) when is_list(entries) do
    Enum.filter(entries, fn entry ->
      entry.trigger_kind in @unattended_triggers and verdict(entry) in ["MISSING", "BLANK"]
    end)
  end

  # 14, not 12: `chat_pattern` is exactly 12 characters, so a 12-wide column
  # renders `chat_patterndesign.brand_check.v1` with no separator at all —
  # measured on moon at 3ab3b019 against the real 26-row table. A column
  # whose width equals its widest value is a column with no gutter.
  @trigger_width 14

  defp header do
    pad("KEY", 32) <> pad("TRIGGER", @trigger_width) <> pad("SLUG", 32) <> "VERDICT"
  end

  defp format_row(entry) do
    pad(entry.key, 32) <>
      pad(entry.trigger_kind || "(unknown)", @trigger_width) <>
      pad(slug_of(entry), 32) <> verdict(entry)
  end

  defp slug_of(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp slug_of(_), do: "(none)"

  defp verdict(%{status: :resolved}), do: "RESOLVED"
  defp verdict(%{status: {:missing, _}}), do: "MISSING"
  defp verdict(%{status: {:blank, _}}), do: "BLANK"
  defp verdict(%{status: :none}), do: "none"

  defp summary_line(entries) do
    counts = Enum.frequencies_by(entries, &verdict/1)

    "#{length(entries)} responsibilities · " <>
      "#{Map.get(counts, "RESOLVED", 0)} resolved · " <>
      "#{Map.get(counts, "MISSING", 0)} missing · " <>
      "#{Map.get(counts, "BLANK", 0)} blank · " <>
      "#{Map.get(counts, "none", 0)} declaring no template"
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)

  defp plural([_one]), do: "y"
  defp plural(_), do: "ies"
end
