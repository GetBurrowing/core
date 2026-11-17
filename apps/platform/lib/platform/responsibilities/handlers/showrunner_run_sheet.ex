defmodule Platform.Responsibilities.Handlers.ShowrunnerRunSheet do
  @moduledoc """
  `showrunner.run_sheet`: the 45-minute run sheet (task 01a1eaf6 stage 3).
  One key in the `showrunner` bundle.

  ## Triggers

    * the written brief — `Handlers.ShowrunnerResearchBrief` fires this key
      with the board's `canvas_id` once the rail is at Run sheet;
    * a cron fallback, default `0 9 * * *` UTC, which does nothing unless the
      newest board is at Run sheet with no run sheet;
    * its own one redraft (below).

  ## Prompt: the `showrunner.run_sheet` surface

  `build_prompt/1` resolves the `showrunner.run_sheet` experiment surface
  (`Platform.Experiments.Surfaces.ShowrunnerRunSheet`, subject `"episode"`,
  id = the board's canvas id). The arm's `prompt_slug` is the template the
  run sheet is drafted from and its `directive`, if any, is appended. An arm
  whose slug has no row falls back to `showrunner.run_sheet.v1`.

  ## Output and validation

  `{"segments": [...], "through_line", "cold_open": {"a", "b"}}`: segments
  with timings, per-host talking points keyed by host ROLE, callbacks to past
  episodes and sourced stat cards, a through-line analogy, and two cold opens.
  The draft goes through `Episode.put_run_sheet/2`. Invalid (an unsourced
  stat, a gap, over 45:00): ONE redraft is fired with the reason; a second
  invalid draft raises a Needs-you item and is escalated. Never a raise.

  A valid sheet is written to the board, the cold-open A/B choice becomes a
  Needs-you item (one inbox row), and a `[show]` journal line records it.

  ## An unreadable board

  As for the brief: logged, one Needs-you item, no raise.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat.Canvas
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.ShowrunnerRunSheet, as: Surface
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime

  @key "showrunner.run_sheet"
  @feature "showrunner"
  @template_slug "showrunner.run_sheet.v1"
  @cron_expression "0 9 * * *"
  @max_redrafts 1
  @cold_open_id "cold-open"
  @invalid_id "run-sheet-invalid"

  @system "You are the showrunner for How to Computer. You write tight, dry, " <>
            "numbers-first run sheets. Every stat card carries its source URL."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The Needs-you item id the cold-open A/B choice uses."
  @spec cold_open_id() :: String.t()
  def cold_open_id, do: @cold_open_id

  @doc "The Needs-you item id a twice-invalid draft raises."
  @spec invalid_id() :: String.t()
  def invalid_id, do: @invalid_id

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression},
        scope: "per_space",
        context_provided: ["topic", "brief", "recent_episodes", "host_roles", "redraft_note"],
        output_contract: %{
          "segments" => "list[object]",
          "through_line" => "string",
          "cold_open" => "object"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.showrunner",
          "status" => "active",
          "role" => "showrunner",
          "surface" => Surface.key(),
          "task" => "01a1eaf6"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    with {:ok, ctx, config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, _document} <- read(ctx, canvas),
         :ok <- due(episode) do
      {:ok,
       %{
         topic: episode.title,
         episode_number: episode.number,
         brief: episode.brief || "",
         recent_episodes: Runtime.episodes_text(ctx.space_id),
         host_roles: Enum.join(config.host_roles, ", "),
         redraft_note: redraft_note(trigger_meta),
         canvas_id: canvas.id,
         dispatch_space_id: ctx.space_id
       }}
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    payload = payload(Map.get(context, :canvas_id))

    assigns = %{
      topic: Map.get(context, :topic, ""),
      episode_number: to_string(Map.get(context, :episode_number, "")),
      brief: Map.get(context, :brief, ""),
      recent_episodes: Map.get(context, :recent_episodes, ""),
      host_roles: Map.get(context, :host_roles, ""),
      redraft_note: Map.get(context, :redraft_note, "")
    }

    case Runtime.render(payload["prompt_slug"], @template_slug, assigns) do
      {:ok, user} ->
        user =
          case Surface.render_directive(payload) do
            nil -> user
            directive -> user <> "\n\n## Experiment directive (#{Surface.key()})\n\n" <> directive
          end

        {:ok, %{system: @system, user: user}}

      {:error, _} ->
        {:error, :template_missing}
    end
  end

  @doc """
  The `showrunner.run_sheet` payload for the episode on board `canvas_id`: the
  assigned arm's, else the promoted default, else the control. Never raises.
  """
  @spec payload(String.t() | nil) :: map()
  def payload(canvas_id) when is_binary(canvas_id) do
    subject = Subject.new(Surface.subject_type(), canvas_id)

    case Surfaces.resolve(Surface.key(), Surface.target(), subject) do
      {:variant, _experiment, _slug, %{"prompt_slug" => slug} = payload} when is_binary(slug) ->
        payload

      {:default, %{"prompt_slug" => slug} = payload} when is_binary(slug) ->
        payload

      _ ->
        Surface.control()
    end
  rescue
    _ -> Surface.control()
  end

  def payload(_canvas_id), do: Surface.control()

  @impl true
  def output_meta(context, trigger_meta) do
    Map.put(trigger_meta || %{}, :canvas_id, Map.get(context, :canvas_id))
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, output, trigger_meta) do
    with {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- due(episode) do
      draft(ctx, canvas, document, episode, output, trigger_meta)
    else
      {:error, {:board_unreadable, _}} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("[showrunner.run_sheet] output refused: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("[showrunner.run_sheet] handle_output raised: #{Exception.message(error)}")
      {:error, :handle_output_failed}
  end

  @impl true
  def handle_refusal(%Responsibility{}, refusal, _trigger_meta) do
    Logger.info("[showrunner.run_sheet] refused dispatch: #{inspect(refusal)}")
    :ok
  end

  # ── internals ──

  defp draft(ctx, canvas, document, episode, output, trigger_meta) do
    decoded =
      case Runtime.decode(output) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end

    case Episode.put_run_sheet(episode, segments(decoded)) do
      {:ok, drafted} ->
        accept(ctx, canvas, document, drafted, decoded)

      {:error, reason} ->
        reject(ctx, canvas, document, episode, reason, attempt(trigger_meta))
    end
  end

  defp accept(ctx, canvas, document, episode, decoded) do
    cold_open = cold_open(decoded["cold_open"])
    through_line = text(decoded["through_line"])

    {episode, item} =
      case cold_open do
        %{"a" => _, "b" => _} ->
          item = %{
            id: @cold_open_id,
            question: "Which cold open?",
            options: ["Cold open A", "Cold open B"]
          }

          case Episode.add_needs_you(episode, item) do
            {:ok, with_item} -> {with_item, item}
            {:error, _} -> {episode, nil}
          end

        _ ->
          {episode, nil}
      end

    document =
      Map.update(document, "meta", %{}, fn meta ->
        Map.put(meta || %{}, "showrunner_draft", %{
          "through_line" => through_line,
          "cold_open" => cold_open
        })
      end)

    with {:ok, _canvas} <- Board.write(ctx, canvas, document, episode) do
      if item do
        Board.escalate(ctx, item, detail: "A: #{cold_open["a"]}\nB: #{cold_open["b"]}")
      end

      Memory.append_journal(
        ctx.space_id,
        Memory.episode_entry(
          episode.number,
          "run sheet: #{length(episode.run_sheet)} segments" <>
            if(through_line, do: "; through-line: #{through_line}", else: "")
        )
      )

      :ok
    end
  end

  defp reject(_ctx, canvas, _document, _episode, reason, attempt) when attempt < @max_redrafts do
    Logger.info(
      "[showrunner.run_sheet] draft invalid (#{inspect(reason)}); redraft #{attempt + 1}"
    )

    Runtime.fire(@key, %{
      kind: :redraft,
      canvas_id: canvas.id,
      redraft_attempt: attempt + 1,
      redraft_error: Episode.error_message(reason)
    })

    :ok
  end

  defp reject(ctx, canvas, document, episode, reason, _attempt) do
    message = Episode.error_message(reason)
    Logger.warning("[showrunner.run_sheet] redraft still invalid (#{message}); escalating")

    item = %{
      id: @invalid_id,
      question: "The run sheet draft is still invalid (#{message}). Draft it by hand?",
      options: ["Draft by hand", "Ask again"]
    }

    episode =
      case Episode.add_needs_you(episode, item) do
        {:ok, with_item} -> with_item
        {:error, _} -> episode
      end

    case Board.write(ctx, canvas, document, episode) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("[showrunner.run_sheet] could not mark the board: #{inspect(other)}")
    end

    Board.escalate(ctx, item)
    :ok
  end

  defp read(ctx, canvas) do
    case Board.read(canvas) do
      {:ok, episode, document} ->
        {:ok, episode, document}

      {:error, reason} ->
        Board.unreadable(ctx, canvas, reason)
        {:error, {:board_unreadable, reason}}
    end
  end

  defp due(%Episode{stage: :run_sheet, run_sheet: []}), do: :ok
  defp due(%Episode{stage: stage}), do: {:error, {:not_due, stage}}

  defp segments(%{"segments" => segments}) when is_list(segments), do: segments
  defp segments(_), do: []

  defp cold_open(%{} = raw) do
    a = text(raw["a"] || raw[:a])
    b = text(raw["b"] || raw[:b])
    if a && b, do: %{"a" => a, "b" => b}, else: nil
  end

  defp cold_open(_), do: nil

  defp attempt(meta) do
    case Runtime.meta(meta, :redraft_attempt) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp redraft_note(meta) do
    case Runtime.meta(meta, :redraft_error) do
      error when is_binary(error) and error != "" ->
        "Your previous draft was refused: #{error}. Fix exactly that and keep the rest."

      _ ->
        ""
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
