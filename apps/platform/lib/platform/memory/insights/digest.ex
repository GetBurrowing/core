defmodule Platform.Memory.Insights.Digest do
  @moduledoc """
  Which open insights go into whose daily briefing. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3.

  `select/2` returns `%{user_id => [insight]}` and writes nothing. It selects
  nothing at all unless `Platform.Memory.Insights.Settings` has
  `dissemination_enabled` on, whatever the per-type toggles say. A candidate
  is an insight that is ALL of:

    * `open`, never delivered (`delivered_at` nil) and unexpired;
    * `disseminable` and of origin `dreaming`, so a migrated legacy proposal
      (`disseminable: false`) is never selected;
    * at least as confident as its run's arm requires, read from the
      `memory.insight_synthesis` surface for the insight's `run_id`:
      `auto_apply_min_confidence` (control `medium`) for a `page_edit` or a
      `task`, `min_confidence` (control `high`) for everything else.
      Re-read here, not trusted from ingest, so an arm's threshold binds
      delivery as well as ingest.

  A candidate is then routed by its tier, RE-CHECKED now with
  `Platform.Memory.Insights.Tier.classify/1` (the stored tier is from ingest,
  and membership and addressee can change in between):

    * `:reversible` — delivered to its addressee, when its type's toggle is
      on (`deliver_briefings` for `briefing`, `deliver_questions` for
      `question`, `apply_page_edits` for `page_edit`, `file_tasks` for
      `task`), the addressee is set and has not opted out
      (`Accounts.insight_delivery_opted_out?/1`), and:
      * for a question, it is not a duplicate (normalised text) of an open
        question already delivered or selected for the same addressee;
      * for a `page_edit` or a `task`, it is
        `Platform.Memory.Insights.Unattended.eligible?/1` (authored by the
        current `memory.dreaming` holder). Selection writes nothing: the
        Disseminator applies it through
        `Platform.Memory.Insights.Actions.apply_unattended/2` and lists the
        result under "Already done" for the addressee.
    * `:needs_call` — never delivered for execution and never to its
      addressee. It goes to every internal root admin who has not opted out,
      rendered under "Needs your call" as a link to `/memory/insights`.

  Each returned insight carries its re-checked tier in `tier` (in memory
  only; nothing is written), which is what `BriefingCard` sections on.

  An insight that fails a check stays `open` and undelivered: a later digest
  may select it (after an opt-in, a reroute, a toggle).
  """

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Settings
  alias Platform.Memory.Insights.Tier
  alias Platform.Memory.Insights.Unattended
  alias Platform.Repo
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @confidence_rank %{"high" => 3, "medium" => 2, "low" => 1}
  @unattended_types ["page_edit", "task"]

  @doc """
  The digest at `now`. See the moduledoc. `opts` is reserved for callers and
  currently unused.
  """
  @spec select(DateTime.t(), keyword()) :: %{binary() => [Insight.t()]}
  def select(now \\ DateTime.utc_now(), opts \\ []) when is_list(opts) do
    settings = Settings.get()

    if settings.dissemination_enabled do
      do_select(now, settings)
    else
      %{}
    end
  end

  defp do_select(now, settings) do
    types = enabled_types(settings)

    now
    |> candidates()
    |> Enum.filter(&meets_arm?/1)
    |> Enum.reduce({%{}, %{}}, fn insight, acc ->
      tier = Tier.classify(insight)
      route(tier, %{insight | tier: Tier.label(tier)}, types, now, acc)
    end)
    |> elem(0)
    |> Map.new(fn {user_id, insights} -> {user_id, Enum.reverse(insights)} end)
  end

  defp enabled_types(settings) do
    [
      settings.deliver_briefings && "briefing",
      settings.deliver_questions && "question",
      settings.apply_page_edits && "page_edit",
      settings.file_tasks && "task"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp candidates(now) do
    Repo.all(
      from(i in Insight,
        where:
          i.state == "open" and is_nil(i.delivered_at) and i.expires_at > ^now and
            i.disseminable == true and i.origin == "dreaming",
        order_by: [asc: i.inserted_at, asc: i.id]
      )
    )
  end

  # The arm's threshold for the insight's run: auto_apply_min_confidence
  # (control "medium") for a page_edit or task, min_confidence (control
  # "high") for the rest.
  defp meets_arm?(%Insight{action_type: type, run_id: run_id, confidence: confidence})
       when type in @unattended_types do
    min = Insights.auto_apply_min_confidence(run_id)
    Map.get(@confidence_rank, confidence, 0) >= Map.get(@confidence_rank, min, 3)
  end

  defp meets_arm?(%Insight{run_id: run_id, confidence: confidence}) do
    min = run_id |> Insights.synthesis_payload() |> Map.get("min_confidence", "high")
    Map.get(@confidence_rank, confidence, 0) >= Map.get(@confidence_rank, min, 3)
  end

  # acc = {by_user, seen_questions}; by_user lists are built reversed.
  defp route(:reversible, %Insight{} = insight, types, now, {by_user, seen} = acc) do
    user_id = insight.addressee_user_id

    cond do
      insight.action_type not in types -> acc
      not is_binary(user_id) -> acc
      Accounts.insight_delivery_opted_out?(user_id) -> acc
      insight.action_type == "question" -> route_question(insight, user_id, now, acc)
      insight.action_type in @unattended_types and not Unattended.eligible?(insight) -> acc
      true -> {prepend(by_user, user_id, insight), seen}
    end
  end

  defp route(:needs_call, %Insight{} = insight, _types, _now, {by_user, seen}) do
    by_user =
      root_admin_ids()
      |> Enum.reject(&Accounts.insight_delivery_opted_out?/1)
      |> Enum.reduce(by_user, &prepend(&2, &1, insight))

    {by_user, seen}
  end

  defp route_question(insight, user_id, now, {by_user, seen}) do
    open = Map.get_lazy(seen, user_id, fn -> delivered_open_questions(user_id, now) end)
    key = normalise(insight.body)

    if MapSet.member?(open, key) do
      {by_user, Map.put(seen, user_id, open)}
    else
      {prepend(by_user, user_id, insight), Map.put(seen, user_id, MapSet.put(open, key))}
    end
  end

  defp prepend(by_user, user_id, insight),
    do: Map.update(by_user, user_id, [insight], &[insight | &1])

  defp delivered_open_questions(user_id, now) do
    from(i in Insight,
      where:
        i.action_type == "question" and i.state == "open" and i.addressee_user_id == ^user_id and
          not is_nil(i.delivered_at) and i.expires_at > ^now,
      select: i.body
    )
    |> Repo.all()
    |> MapSet.new(&normalise/1)
  end

  @doc """
  The text a question is compared on for duplicates: lower-cased, with runs
  of whitespace collapsed and trailing punctuation dropped.
  """
  @spec normalise(String.t() | nil) :: String.t()
  def normalise(nil), do: ""

  def normalise(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_trailing("?")
    |> String.trim_trailing(".")
    |> String.trim()
  end

  @doc "Every internal admin of the root org: who reads \"Needs your call\"."
  @spec root_admin_ids() :: [binary()]
  def root_admin_ids do
    Repo.all(
      from(m in OrgMembership,
        join: o in Org,
        on: o.id == m.org_id,
        where: is_nil(o.parent_org_id) and m.role == "admin" and m.external == false,
        distinct: true,
        select: m.user_id
      )
    )
  end
end
