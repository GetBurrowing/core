defmodule Platform.Mail.Triage.BriefingSection do
  @moduledoc """
  The called-out email section of the daily briefing (task 01a1f426 stage
  2, Level 1 surface), key `mail_priority`: a core provider of
  `Platform.Memory.Insights.BriefingSections` and the only one listed in
  `config/config.exs`, so it renders first, above every other section and
  above Needs your call.

  Thin over `Platform.Mail.Triage`: `prepare/2` runs the reader's triage,
  `summary/2` counts what `Triage.section_view/3` shows. Rendered by
  `PlatformWeb.Components.MailPrioritySection`. None while the Email module
  is off (`Platform.Mail.Config.enabled?/0`, no query).
  """

  alias Platform.Mail.Triage

  @key "mail_priority"
  @max_model_calls 40

  @doc "The section key."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The provider entry point read by `BriefingSections.all/0`."
  @spec briefing_sections() :: [map()]
  def briefing_sections do
    if Platform.Mail.Config.enabled?() do
      [
        %{
          key: @key,
          component: PlatformWeb.Components.MailPrioritySection,
          prepare: &prepare/2,
          summary: &summary/2
        }
      ]
    else
      []
    end
  end

  @doc """
  Delivery: triage the reader's mail received since the start of the day
  before `date` that has no item for them yet (so overnight mail is
  covered; already-triaged mail is skipped by the unique index), with at
  most #{@max_model_calls} model calls per run (the rest wait for the next
  run), then hands the called-out items to `Platform.Mail.Triage.Drafter`
  (a draft reply or a plan each, at most its daily cap; nothing is sent).
  Returns the number of called-out (`top` / `action`) items the reader has
  not had a briefing for: before this date's briefing is delivered
  (`Triage.briefing_delivered?/2`), every called-out item of the date,
  including those classified on arrival between briefings; after it, only
  the NEW ones. So a briefing is created when one lands. Idempotent per
  reader and date once delivered: a second run classifies nothing and
  returns 0. 0 when no mailbox the reader may read has an active flag
  agent. There is no single agent: each mailbox is triaged and drafted by
  its own flag-important agent (`Triage.agent_for_account/1`).

  `date` is a briefing date (`Triage.briefing_date/1`): the window is that
  local day (`Triage.day_bounds/1`), not the UTC one.
  """
  @spec prepare(binary(), Date.t()) :: non_neg_integer()
  def prepare(user_id, %Date{} = date) do
    with %{id: _} = user <- fetch_user(user_id) do
      before = length(Triage.called_out(user, date))
      {start, _finish} = Triage.day_bounds(date)

      {:ok, _summary} =
        Triage.run_for_reader(user, date,
          since: DateTime.add(start, -86_400, :second),
          max_model_calls: @max_model_calls
        )

      # Task 01a1f426 stage 4: start the work on what was called out (a
      # draft reply or a plan; drafts only, capped per reader per day).
      {:ok, _drafted} =
        Platform.Mail.Triage.Drafter.run_for_reader(user, date,
          since: DateTime.add(start, -86_400, :second)
        )

      after_run = length(Triage.called_out(user, date))

      # An item classified on arrival (the Subscriber, between briefings)
      # was already counted in `before`; until this date's briefing is
      # delivered it is still news for the reader, so it counts.
      if Triage.briefing_delivered?(user.id, date),
        do: max(after_run - before, 0),
        else: after_run
    else
      _ -> 0
    end
  end

  def prepare(_user_id, _date), do: 0

  @doc """
  A pure read. `total` is the reader's called-out items of `date`, `open`
  those still open, `calls` the `top` ones still open. nil (section absent)
  when the reader may read no mailbox: then there is neither an item nor a
  notice to show. With a readable mailbox and nothing called out (no agent,
  no mailbox granted, or a quiet day) the section counts as ONE
  informational item with nothing open, as the Digest section does, so its
  notice still renders.
  """
  @spec summary(binary(), Date.t()) :: map() | nil
  def summary(user_id, %Date{} = date) do
    case fetch_user(user_id) do
      %{id: _} = user -> counts(Triage.section_view(user, date))
      _ -> nil
    end
  end

  def summary(_user_id, _date), do: nil

  @doc "The section's counts for a `Triage.section_view/3` result."
  @spec counts(map()) :: map() | nil
  def counts(%{readable?: false}), do: nil

  def counts(%{called_out: []}), do: %{total: 1, open: 0, calls: 0}

  def counts(%{called_out: items}) do
    open = Enum.filter(items, &(&1.status == "open"))

    %{
      total: length(items),
      open: length(open),
      calls: Enum.count(open, &(&1.tier == "top"))
    }
  end

  defp fetch_user(user_id) when is_binary(user_id), do: Platform.Accounts.get_user(user_id)
  defp fetch_user(_), do: nil
end
