defmodule Platform.Secretary.Fallback do
  @moduledoc """
  The deterministic view when no model verdict can be had (task 01a1b721
  stage 3 item 6): no AI login, the budget is spent, or the batch failed,
  timed out or was rejected. `model_version` is `"fallback"`.

  Groups, by the input's kind (`group_key` is `"fallback:<key>"`):

    * `reviews` "Reviews and approvals" — `task_plan_review`,
      `review_request_pending`, `task_sponsor_assigned`,
      `lifecycle_step_failed`, `social_post_approval`,
      `social_account_disconnected` and ANY other inbox kind, including an
      extension's. This restates `PlatformWeb.InboxLive`'s private
      `section_for/1` catch-all ("Awaiting your review"); it is a web-layer
      private function, so it cannot be called from here;
    * `mentions` "Mentions" — `chat_mention`, and a chat message that
      mentions the person;
    * `meetings` "Meetings" — `meeting_starting`, `meeting_invited`,
      `meeting_cancelled`, and calendar events;
    * `briefings` "Briefings" — `briefing`, `meeting_briefing`;
    * `todos` "Your to-dos" — the person's own list.

  Anything else (other chat, meeting action items) is `quiet`. There is no
  brief and `needs_you_now` is always false: the fallback never nudges.
  """

  alias Platform.Secretary.{Overrides, Store}

  @groups [
    {"reviews", "Reviews and approvals"},
    {"mentions", "Mentions"},
    {"meetings", "Meetings"},
    {"briefings", "Briefings"},
    {"todos", "Your to-dos"}
  ]

  @meeting_kinds ~w(meeting_starting meeting_invited meeting_cancelled)
  @briefing_kinds ~w(briefing meeting_briefing)

  @doc "The groups, in display order: `[{key, label}]`."
  @spec groups() :: [{String.t(), String.t()}]
  def groups, do: @groups

  @doc "The `group_key` prefix of a fallback group."
  @spec group_key(String.t()) :: String.t()
  def group_key(key), do: "fallback:" <> key

  @doc """
  The fallback group and tag for an input kind (as `Platform.Secretary.Input`
  writes it), and whether it mentions the person: `{group | nil, tag}`.
  """
  @spec classify(String.t(), boolean()) :: {String.t() | nil, String.t()}
  def classify(kind, mentioned? \\ false)

  def classify("inbox:chat_mention", _), do: {"mentions", "waiting"}
  def classify("inbox:" <> kind, _) when kind in @meeting_kinds, do: {"meetings", "fyi"}
  def classify("inbox:" <> kind, _) when kind in @briefing_kinds, do: {"briefings", "fyi"}
  def classify("inbox:" <> _kind, _), do: {"reviews", "decide"}
  def classify("chat:" <> _, true), do: {"mentions", "waiting"}
  def classify("calendar:" <> _, _), do: {"meetings", "fyi"}
  def classify("todo:" <> _, _), do: {"todos", "todo"}
  def classify(_kind, _), do: {nil, "quiet"}

  @doc """
  Writes the fallback evaluation for every ref in `refs` (batch `item_refs`
  maps: `ref_type`, `ref_id`, `kind`, `kind_key`, `mentioned`) for
  `user_id`, then applies the person's overrides. Options: `:batch_id`,
  `:failed?` (true when the batch failed, timed out or was rejected: each
  ref's `failed_attempts` goes up by one). Returns the count written.
  """
  @spec apply(Ecto.UUID.t(), [map()], keyword()) :: non_neg_integer()
  def apply(user_id, refs, opts \\ []) when is_list(refs) do
    failed? = Keyword.get(opts, :failed?, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    refs
    |> Enum.with_index(1)
    |> Enum.map(fn {ref, index} ->
      {group, tag} = classify(ref["kind"] || "", ref["mentioned"] == true)
      existing = Store.get_evaluation(user_id, ref["ref_type"], ref["ref_id"])
      attempts = (existing && existing.failed_attempts) || 0

      %{
        "ref_type" => ref["ref_type"],
        "ref_id" => ref["ref_id"],
        "kind_key" => ref["kind_key"],
        "tag" => tag,
        "group_key" => if(group, do: group_key(group), else: "none"),
        "reason" => nil,
        "rank" => index,
        "brief_rank" => nil,
        "brief_line" => nil,
        "brief_action_label" => nil,
        "brief_tag" => nil,
        "family" => false,
        "needs_you_now" => false,
        "model_version" => "fallback",
        "batch_id" => Keyword.get(opts, :batch_id),
        "failed_attempts" => if(failed?, do: attempts + 1, else: attempts),
        "evaluated_at" => now
      }
    end)
    |> then(&Overrides.apply(user_id, &1))
    |> Enum.count(fn attrs -> match?({:ok, _}, Store.upsert_evaluation(user_id, attrs)) end)
  end
end
