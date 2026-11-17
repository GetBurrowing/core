defmodule Platform.Responsibilities.Handlers.ShowrunnerResearchBrief do
  @moduledoc """
  `showrunner.research_brief`: the research brief for the picked topic (task
  01a1eaf6 stage 3). One key in the `showrunner` bundle.

  ## Triggers

    * the topic pick — `pick_topic/2` resolves the board's "Pick this topic"
      item, titles the episode with the pick, moves the rail to Research and
      fires this key with the board's `canvas_id`;
    * an overnight cron fallback, default `0 7 * * *` UTC, which does nothing
      unless the newest board is at Research with no brief.

  Config (space, escalation, hosts) is the row's `trigger_config`, as for
  `Handlers.ShowrunnerWeeklyPitch`.

  ## Output

  `{"brief", "sources": [{"title", "url"}], "numbers": [{"text",
  "source_url"}], "counterpoints": [string]}`. A brief with no source, or a
  number without a `source_url`, is refused. The brief (with its sources,
  numbers and counterpoints) is written to the board and as a `[show]`
  journal entry, the rail advances to Run sheet, and the run sheet is fired.

  ## An unreadable board

  `Episode.from_document/1` returning `{:error, _}` (a hand-edited board) is
  logged, raises one Needs-you item through
  `Platform.Showrunner.Board.unreadable/3`, and returns without raising.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat.Canvas
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime

  @key "showrunner.research_brief"
  @feature "showrunner"
  @template_slug "showrunner.research_brief.v1"
  @cron_expression "0 7 * * *"
  @run_sheet_key "showrunner.run_sheet"

  @system "You are the showrunner's researcher for How to Computer. Dry, numbers-first, " <>
            "curious. Every number carries the URL it came from; a number without one is " <>
            "left out."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # Overnight fallback; the topic pick fires this key directly.
        trigger_config: %{"expression" => @cron_expression},
        scope: "per_space",
        context_provided: ["topic", "recent_episodes"],
        output_contract: %{
          "brief" => "string",
          "sources" => "list[object]",
          "numbers" => "list[object]",
          "counterpoints" => "list[string]"
        },
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

  @doc """
  The topic pick: resolves the board's pick item with `choice`, titles the
  episode with it, advances the rail to Research and fires this key. Called
  when a human answers "Pick this topic". `{:ok, canvas}` or `{:error, reason}`;
  an unreadable board takes the Needs-you path and returns
  `{:error, {:board_unreadable, reason}}`. Never raises.
  """
  @spec pick_topic(Canvas.t(), String.t()) :: {:ok, Canvas.t()} | {:error, term()}
  def pick_topic(%Canvas{} = canvas, choice) when is_binary(choice) do
    with %Responsibility{} = row <-
           Platform.Responsibilities.get_by_key(@key) || {:error, :not_registered},
         {:ok, ctx, _config} <- Runtime.context(row),
         {:ok, episode, document} <- read(ctx, canvas),
         {:ok, episode} <- Episode.resolve_needs_you(episode, pick_id(), choice),
         {:ok, episode} <- Episode.advance(%{episode | title: choice}, :research),
         {:ok, canvas} <- Board.write(ctx, canvas, document, episode) do
      Runtime.fire(@key, %{kind: :topic_pick, canvas_id: canvas.id})
      {:ok, canvas}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    with {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, _document} <- read(ctx, canvas),
         :ok <- due(episode) do
      {:ok,
       %{
         topic: episode.title,
         episode_number: episode.number,
         recent_episodes: Runtime.episodes_text(ctx.space_id),
         canvas_id: canvas.id,
         dispatch_space_id: ctx.space_id
       }}
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns = %{
      topic: Map.get(context, :topic, ""),
      episode_number: to_string(Map.get(context, :episode_number, "")),
      recent_episodes: Map.get(context, :recent_episodes, "")
    }

    case Runtime.render(@template_slug, @template_slug, assigns) do
      {:ok, user} -> {:ok, %{system: @system, user: user}}
      {:error, _} -> {:error, :template_missing}
    end
  end

  @impl true
  def output_meta(context, trigger_meta) do
    Map.put(trigger_meta || %{}, :canvas_id, Map.get(context, :canvas_id))
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, output, trigger_meta) do
    with {:ok, brief} <- brief(output),
         {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- due(episode) do
      write_brief(ctx, canvas, document, episode, brief)
    else
      {:error, {:board_unreadable, _}} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("[showrunner.research_brief] output refused: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning(
        "[showrunner.research_brief] handle_output raised: #{Exception.message(error)}"
      )

      {:error, :handle_output_failed}
  end

  @impl true
  def handle_refusal(%Responsibility{}, refusal, _trigger_meta) do
    Logger.info("[showrunner.research_brief] refused dispatch: #{inspect(refusal)}")
    :ok
  end

  @doc """
  Validates the brief: non-blank `brief`, at least one source with a `url`,
  every number with a `source_url`. `{:ok, map}` or `{:error, reason}`.
  """
  @spec brief(term()) :: {:ok, map()} | {:error, term()}
  def brief(output) do
    with {:ok, decoded} <- Runtime.decode(output),
         {:ok, body} <- non_blank(decoded["brief"], :blank_brief),
         {:ok, sources} <- sources(decoded["sources"]),
         {:ok, numbers} <- numbers(decoded["numbers"] || []),
         {:ok, counterpoints} <- strings(decoded["counterpoints"] || []) do
      {:ok, %{brief: body, sources: sources, numbers: numbers, counterpoints: counterpoints}}
    end
  end

  @doc "Renders a validated brief as the markdown the board and journal carry."
  @spec render(map()) :: String.t()
  def render(%{brief: body, sources: sources, numbers: numbers, counterpoints: counterpoints}) do
    [
      body,
      "Sources:\n" <> Enum.map_join(sources, "\n", &"- #{&1.title}: #{&1.url}"),
      numbers != [] &&
        "Numbers:\n" <> Enum.map_join(numbers, "\n", &"- #{&1.text} (#{&1.source_url})"),
      counterpoints != [] && "Counterpoints:\n" <> Enum.map_join(counterpoints, "\n", &"- #{&1}")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  # ── internals ──

  defp pick_id, do: Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch.pick_id()

  defp read(ctx, canvas) do
    case Board.read(canvas) do
      {:ok, episode, document} ->
        {:ok, episode, document}

      {:error, reason} ->
        Board.unreadable(ctx, canvas, reason)
        {:error, {:board_unreadable, reason}}
    end
  end

  defp due(%Episode{stage: :research, brief: nil}), do: :ok
  defp due(%Episode{stage: stage}), do: {:error, {:not_due, stage}}

  defp write_brief(ctx, canvas, document, episode, brief) do
    text = render(brief)
    episode = %{episode | brief: text}

    # The rail moves on only when nothing is open; an open decision (a guest
    # yes/no) keeps it at Research with the brief written.
    episode =
      case Episode.advance(episode, :run_sheet) do
        {:ok, advanced} -> advanced
        {:error, _} -> episode
      end

    with {:ok, canvas} <- Board.write(ctx, canvas, document, episode) do
      Memory.append_journal(
        ctx.space_id,
        Memory.episode_entry(
          episode.number,
          "brief on \"#{episode.title}\": #{String.slice(brief.brief, 0, 280)} Sources: " <>
            Enum.map_join(brief.sources, ", ", & &1.url)
        )
      )

      if episode.stage == :run_sheet do
        Runtime.fire(@run_sheet_key, %{kind: :brief_written, canvas_id: canvas.id})
      end

      :ok
    end
  end

  defp sources([_ | _] = list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{} = raw, {:ok, acc} ->
        case non_blank(raw["url"] || raw[:url], :unsourced_source) do
          {:ok, url} ->
            title = text(raw["title"] || raw[:title]) || url
            {:cont, {:ok, acc ++ [%{title: title, url: url}]}}

          error ->
            {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, :unsourced_source}}
    end)
  end

  defp sources(_), do: {:error, :no_sources}

  defp numbers(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{} = raw, i}, {:ok, acc} ->
        with {:ok, number_text} <- non_blank(raw["text"] || raw[:text], {:blank_number, i}),
             {:ok, url} <-
               non_blank(raw["source_url"] || raw[:source_url], {:unsourced_number, i}) do
          {:cont, {:ok, acc ++ [%{text: number_text, source_url: url}]}}
        else
          error -> {:halt, error}
        end

      {_other, i}, _acc ->
        {:halt, {:error, {:unsourced_number, i}}}
    end)
  end

  defp numbers(_), do: {:error, :bad_numbers}

  defp strings(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))},
      else: {:error, :bad_counterpoints}
  end

  defp strings(_), do: {:error, :bad_counterpoints}

  defp non_blank(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_blank(_value, error), do: {:error, error}

  defp text(value) when is_binary(value) and value != "", do: String.trim(value)
  defp text(_), do: nil
end
