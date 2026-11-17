defmodule Platform.Responsibilities.Handlers.ShowrunnerRetro do
  @moduledoc """
  `showrunner.retro`: what last week's episode kept, cut and earned (task
  01a1eaf6 stage 4). One key in the `showrunner` bundle.

  ## Trigger

  A weekly Router cron, default `0 12 * * 1` UTC: Monday, two hours before
  `showrunner.weekly_pitch`, so the pitch reads a retro'd show journal.
  Operator-settable through `Platform.Showrunner.Config`.

  ## Social is the agent's

  As for post_show: `Platform.Showrunner.SocialBundle.guard/4` checks the
  agent's effective tools for the `social` bundle first; without it nothing
  is dispatched and one Needs-you item says so. With it, the prompt
  (template `showrunner.retro.v1`) asks the agent to read results with its
  `social_results_get` / `social_clip_list` tools and report per-clip
  performance plus the kept and cut segment ids.

  ## Output

  `{"kept_segment_ids", "cut_segment_ids", "clip_results"}`, validated by
  `Platform.Showrunner.Episode.put_retro/2` (disjoint, every id on the run
  sheet). Core records it on the episode, writes the board's retro section
  and a `[show]` journal entry, and emits the `showrunner.run_sheet` metric,
  `Episode.kept_share/1`:

    * telemetry `[:platform, :showrunner, :kept_share]`, measurement
      `%{kept_share: float}`, metadata `%{canvas_id, episode_number, kept,
      total}`, always;
    * one labelled `Platform.Experiments.Signals` row per experiment on the
      `showrunner.run_sheet` surface that assigned this episode (label
      `"kept_share"`, `confidence` = the share), idempotent per episode.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  import Ecto.Query

  alias Platform.Chat.Canvas
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Surfaces.ShowrunnerRunSheet, as: Surface
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.ShowrunnerPostShow, as: PostShow
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime
  alias Platform.Showrunner.SocialBundle

  @key "showrunner.retro"
  @feature "showrunner"
  @template_slug "showrunner.retro.v1"
  @cron_expression "0 12 * * 1"
  @telemetry_event [:platform, :showrunner, :kept_share]
  @signal_source_type "showrunner.retro"
  @signal_label "kept_share"

  @system "You are the showrunner for How to Computer, looking back at last week's " <>
            "episode. Numbers first; report only what the results say."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The telemetry event the kept share is emitted on."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "The `source_type` of the experiment signals the retro records."
  @spec signal_source_type() :: String.t()
  def signal_source_type, do: @signal_source_type

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression},
        scope: "per_space",
        context_provided: ["run_sheet", "clip_ids", "draft_ids"],
        output_contract: %{
          "kept_segment_ids" => "list[string]",
          "cut_segment_ids" => "list[string]",
          "clip_results" => "list[object]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.showrunner",
          "status" => "active",
          "role" => "showrunner",
          "surface" => Surface.key(),
          "task" => "01a1eaf6",
          "requires_tool_bundle" => SocialBundle.bundle()
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    with {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- SocialBundle.guard(ctx, canvas, document, episode),
         :ok <- due(episode) do
      post = Board.meta(document, PostShow.meta_key())

      {:ok,
       %{
         episode_number: episode.number,
         title: episode.title,
         segments: Enum.map_join(episode.run_sheet, "\n", fn s -> "- #{s.id}: #{s.name}" end),
         clip_ids: Enum.join(post["clip_ids"] || [], ", "),
         draft_ids: Enum.join(post["draft_ids"] || [], ", "),
         canvas_id: canvas.id,
         dispatch_space_id: ctx.space_id
       }}
    else
      {:parked, reason} -> {:handled, %{parked: SocialBundle.missing_item().id, reason: reason}}
      {:error, {:board_unreadable, _}} -> {:handled, %{board: :unreadable}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns =
      Map.new(
        ~w(episode_number title segments clip_ids draft_ids)a,
        &{&1, to_string(Map.get(context, &1, ""))}
      )

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
    with {:ok, decoded} <- Runtime.decode(output),
         {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- due(episode),
         {:ok, episode} <- Episode.put_retro(episode, decoded) do
      record(ctx, canvas, document, episode)
    else
      {:error, {:board_unreadable, _}} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("[showrunner.retro] output refused: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("[showrunner.retro] handle_output raised: #{Exception.message(error)}")
      {:error, :handle_output_failed}
  end

  @impl true
  def handle_refusal(%Responsibility{} = responsibility, refusal, _trigger_meta),
    do: Runtime.refused(responsibility, refusal)

  # ── internals ──

  defp read(ctx, canvas) do
    case Board.read(canvas) do
      {:ok, episode, document} ->
        {:ok, episode, document}

      {:error, reason} ->
        Board.unreadable(ctx, canvas, reason)
        {:error, {:board_unreadable, reason}}
    end
  end

  defp due(%Episode{stage: stage, run_sheet: [_ | _], retro: retro})
       when stage in [:post, :retro] do
    if retro.kept_segment_ids == [] and retro.cut_segment_ids == [],
      do: :ok,
      else: {:error, :already_retroed}
  end

  defp due(%Episode{stage: stage}), do: {:error, {:not_due, stage}}

  defp record(ctx, canvas, document, episode) do
    share = Episode.kept_share(episode)
    kept = length(episode.retro.kept_segment_ids)
    total = length(episode.run_sheet)

    # The rail reaches Retro only once Post's decision is made; the retro is
    # recorded either way.
    episode =
      case Episode.advance(episode, :retro) do
        {:ok, advanced} -> advanced
        {:error, _} -> episode
      end

    body =
      "Kept #{kept} of #{total} segments (#{percent(share)}). " <>
        "Cut: #{Enum.join(episode.retro.cut_segment_ids, ", ")}." <>
        clips_line(episode.retro.clip_results)

    document = Board.put_section(document, "episode-retro", "Retro", body)

    with {:ok, _canvas} <- Board.write(ctx, canvas, document, episode) do
      Memory.append_journal(
        ctx.space_id,
        Memory.episode_entry(episode.number, "retro: " <> body)
      )

      emit_kept_share(canvas, episode, share, kept, total)
      :ok
    end
  end

  defp emit_kept_share(canvas, episode, share, kept, total) do
    :telemetry.execute(@telemetry_event, %{kept_share: share}, %{
      canvas_id: canvas.id,
      episode_number: episode.number,
      kept: kept,
      total: total,
      surface: Surface.key()
    })

    subject_type = Surface.subject_type()

    from(a in Assignment,
      join: e in Experiment,
      on: e.id == a.experiment_id,
      where:
        a.subject_type == ^subject_type and a.subject_id == ^canvas.id and
          e.surface_key == ^Surface.key() and is_nil(a.excluded_reason),
      select: a.experiment_id
    )
    |> Repo.all()
    |> Enum.each(fn experiment_id ->
      Signals.record(%{
        experiment_id: experiment_id,
        subject_type: subject_type,
        subject_id: canvas.id,
        label: @signal_label,
        confidence: share,
        reason: "kept #{kept} of #{total} segments",
        source_type: @signal_source_type,
        source_id: "#{canvas.id}:#{@signal_label}",
        labeler: @key,
        status: "labelled"
      })
    end)
  rescue
    error ->
      Logger.warning("[showrunner.retro] kept_share signal failed: #{Exception.message(error)}")
      :ok
  end

  defp percent(nil), do: "no run sheet"
  defp percent(share), do: "#{round(share * 100)}%"

  defp clips_line([]), do: ""

  defp clips_line(results) do
    " Clips: " <>
      Enum.map_join(results, "; ", fn result ->
        id = result["clip_id"] || result[:clip_id] || "clip"

        stats =
          result
          |> Map.drop(["clip_id", :clip_id])
          |> Enum.map_join(", ", fn {k, v} -> "#{k} #{inspect(v)}" end)

        "#{id} (#{stats})"
      end) <> "."
  end
end
