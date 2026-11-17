defmodule Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch do
  @moduledoc """
  `showrunner.weekly_pitch`: the Monday pitch for How to Computer (task
  01a1eaf6 stage 3). One key in the `showrunner` bundle.

  ## Trigger

  A Router cron row. Default `0 14 * * 1` (Monday 14:00 UTC). The space, the
  project, the person decisions go to and the hosts' roles live in the row's
  `trigger_config` (`Platform.Showrunner.Config`), written by an operator with
  `"operator_set" => true` so a deploy does not revert them. With no space
  configured, `gather_context/2` refuses and nothing is dispatched; with nobody
  holding the role, the Router never calls here.

  ## Context

  The last four episodes from the show journal
  (`Platform.Showrunner.Memory.recent_episodes/2`) and the space's recent
  messages. Core does NOT read Social: the prompt tells the agent to fetch
  last week's clip and its results itself, with its `social_results_get` /
  `social_clip_list` tools when it has them, and to carry on without them
  when it does not.

  ## Output

  Exactly three topics, `{"topics": [{"title", "angle", "why_now"}]}`. Any
  other count is refused with no side effect. Three topics are posted to the
  space, this week's episode board is created from the `episode_board`
  template with Pitch at `needs_you` and a "Pick this topic" item whose
  options are the three titles, the pick goes to `escalate_user_id` as one
  inbox row, and a `[show] Episode <n>` journal line records the pitch.
  A second fire in the same ISO week does nothing.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime

  @key "showrunner.weekly_pitch"
  @feature "showrunner"
  @template_slug "showrunner.weekly_pitch.v1"
  @cron_expression "0 14 * * 1"
  @topic_count 3
  @pick_id "pick-topic"
  @pick_question "Pick this topic"
  @pending_title "Topic pending"

  @system "You are the showrunner for How to Computer, a weekly show. You are dry, " <>
            "numbers-first and curious. Never invent a figure: a number you cannot " <>
            "source is a question, not a fact."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The default cron expression (Monday 14:00 UTC)."
  @spec cron_expression() :: String.t()
  def cron_expression, do: @cron_expression

  @doc "The Needs-you item id the topic pick uses."
  @spec pick_id() :: String.t()
  def pick_id, do: @pick_id

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # The DEFAULT. An operator's `Platform.Showrunner.Config.configure/3`
        # write carries `"operator_set" => true` and survives every boot.
        trigger_config: %{"expression" => @cron_expression},
        scope: "per_space",
        context_provided: ["recent_episodes", "recent_messages", "host_roles"],
        output_contract: %{"topics" => "list[object]"},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.showrunner",
          "status" => "active",
          "role" => "showrunner",
          "task" => "01a1eaf6"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    with {:ok, ctx, config} <- Runtime.context(responsibility) do
      week = Board.week_label(fired_at(trigger_meta))

      if pitched?(ctx.space_id, week) do
        {:error, {:already_pitched, week}}
      else
        {:ok,
         %{
           recent_episodes: Runtime.episodes_text(ctx.space_id),
           recent_messages: Runtime.messages_text(ctx.space_id),
           host_roles: Enum.join(config.host_roles, ", "),
           episode_number: next_number(ctx.space_id),
           week: week,
           dispatch_space_id: ctx.space_id
         }}
      end
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns = %{
      recent_episodes: Map.get(context, :recent_episodes, ""),
      recent_messages: Map.get(context, :recent_messages, ""),
      host_roles: Map.get(context, :host_roles, ""),
      episode_number: to_string(Map.get(context, :episode_number, "")),
      week: Map.get(context, :week, "")
    }

    case Runtime.render(@template_slug, @template_slug, assigns) do
      {:ok, user} -> {:ok, %{system: @system, user: user}}
      {:error, _} -> {:error, :template_missing}
    end
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, output, trigger_meta) do
    with {:ok, topics} <- topics(output),
         {:ok, ctx, _config} <- Runtime.context(responsibility) do
      week = Board.week_label(fired_at(trigger_meta))

      if pitched?(ctx.space_id, week) do
        Logger.info("[showrunner.weekly_pitch] #{week} already pitched; output discarded")
        :ok
      else
        pitch(ctx, topics, week)
      end
    else
      {:error, reason} = error ->
        Logger.warning("[showrunner.weekly_pitch] output refused: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning(
        "[showrunner.weekly_pitch] handle_output raised: #{Exception.message(error)}"
      )

      {:error, :handle_output_failed}
  end

  @impl true
  def handle_refusal(%Responsibility{} = responsibility, refusal, _trigger_meta),
    do: Runtime.refused(responsibility, refusal)

  @doc """
  Validates the pitch: exactly #{@topic_count} topics, each with a non-blank
  `title`. `{:ok, topics}` (string-keyed, trimmed, titles unique) or
  `{:error, reason}`.
  """
  @spec topics(term()) :: {:ok, [map()]} | {:error, term()}
  def topics(output) do
    with {:ok, decoded} <- Runtime.decode(output),
         {:ok, list} <- topic_list(Map.get(decoded, "topics")),
         :ok <- topic_count(list),
         {:ok, topics} <- topic_maps(list),
         :ok <- unique_titles(topics) do
      {:ok, topics}
    end
  end

  # ── internals ──

  defp topic_list(list) when is_list(list), do: {:ok, list}
  defp topic_list(_), do: {:error, :no_topics}

  defp topic_count(list) do
    if length(list) == @topic_count, do: :ok, else: {:error, {:topic_count, length(list)}}
  end

  defp topic_maps(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{} = raw, {:ok, acc} ->
        topic = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

        case topic["title"] do
          title when is_binary(title) ->
            case String.trim(title) do
              "" ->
                {:halt, {:error, :blank_topic_title}}

              trimmed ->
                {:cont,
                 {:ok,
                  acc ++
                    [
                      %{
                        "title" => trimmed,
                        "angle" => text(topic["angle"]),
                        "why_now" => text(topic["why_now"])
                      }
                    ]}}
            end

          _ ->
            {:halt, {:error, :blank_topic_title}}
        end

      _other, _acc ->
        {:halt, {:error, :topic_not_an_object}}
    end)
  end

  defp unique_titles(topics) do
    titles = Enum.map(topics, & &1["title"])
    if titles == Enum.uniq(titles), do: :ok, else: {:error, :duplicate_topic_titles}
  end

  defp pitch(ctx, topics, week) do
    number = next_number(ctx.space_id)
    titles = Enum.map(topics, & &1["title"])
    item = %{id: @pick_id, question: @pick_question, options: titles}

    with {:ok, _message} <- post_topics(ctx, number, topics),
         {:ok, episode} <- Episode.new(number: number, title: @pending_title),
         {:ok, episode} <- Episode.add_needs_you(episode, item),
         {:ok, canvas} <- Board.create(ctx, episode, %{"week" => week, "topics" => topics}) do
      Board.escalate(ctx, item, detail: "Episode #{number}, week #{week}.")

      Memory.append_journal(
        ctx.space_id,
        Memory.episode_entry(number, "pitched #{week}: " <> Enum.join(titles, "; "))
      )

      Logger.info("[showrunner.weekly_pitch] episode #{number} board #{canvas.id} (#{week})")
      :ok
    end
  end

  defp post_topics(ctx, number, topics) do
    body =
      topics
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {topic, i} ->
        [
          "#{i}. #{topic["title"]}",
          topic["angle"],
          topic["why_now"] && "Why now: #{topic["why_now"]}"
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")
      end)

    Chat.post_message(%{
      space_id: ctx.space_id,
      participant_id: ctx.participant_id,
      content_type: "text",
      content: "Episode #{number}: three topics this week.\n\n" <> body,
      metadata: %{"source" => "showrunner", "skip_mention_scan" => true}
    })
  end

  defp pitched?(space_id, week), do: Enum.any?(Board.list(space_id), &(Board.week(&1) == week))

  defp next_number(space_id) do
    boards = space_id |> Board.list() |> Enum.map(&Board.number/1)
    journal = space_id |> Memory.recent_episodes(4) |> Enum.map(& &1.number)

    case Enum.reject(boards ++ journal, &is_nil/1) do
      [] -> 1
      numbers -> Enum.max(numbers) + 1
    end
  end

  defp fired_at(meta) do
    case Runtime.meta(meta, :fired_at) do
      %DateTime{} = at -> at
      _ -> DateTime.utc_now()
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_), do: nil
end
