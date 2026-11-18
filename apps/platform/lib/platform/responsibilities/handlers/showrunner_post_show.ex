defmodule Platform.Responsibilities.Handlers.ShowrunnerPostShow do
  @moduledoc """
  `showrunner.post_show`: show notes, clip picks and social drafts after a
  How to Computer recording (task 01a1eaf6 stage 4). One key in the
  `showrunner` bundle.

  ## Trigger

  `event_topic` on `"meeting:finished"` (event `meeting_finished`, payload
  `%{transcript_id, room_id, space_id}`), the same broadcast
  `meetings.summarize` listens to. A broadcast for any other meeting is
  refused in `gather_context/2`: only the show's room (recorded on the board
  by `showrunner.recording_prep`) counts. A fire with no payload (a retry, or
  an operator firing by hand with the board's `canvas_id`) is about the
  newest board.

  ## Social is the agent's, never core's

  Core never names Social (ADR 0055). Before dispatching,
  `Platform.Showrunner.SocialBundle.guard/4` checks the agent's EFFECTIVE
  tools for the `social` bundle; without it nothing is dispatched, one
  Needs-you item says so, and the fire returns `{:handled, _}`.

  With it, the prompt (template `showrunner.post_show.v1`) tells the agent to
  call `social_clip_propose` for Clip Studio picks and `social_draft_create`
  for the titles, description, chapters, thumbnail options and social posts,
  everything left in approval, and forbids any publish or submit call:
  humans click publish.

  ## Output

  `{"show_notes", "clip_ids": [..], "draft_ids": [..]}`. Core writes the show
  notes as a `[show]` journal entry and a board section, records the ids
  under `meta["showrunner_post"]`, moves the rail to Post and raises "Approve
  posts" (one inbox row). `{"error": "missing_audio" | "upload_failed",
  "detail"}` is retried once, then becomes a Needs-you item.

  `handle_output/4` takes `opts[:fire]`, the retry's fire function
  (`Platform.Showrunner.Runtime.fire/3`).
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat.Canvas
  alias Platform.Responsibilities.Handlers.ShowrunnerRecordingPrep, as: RecordingPrep
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime
  alias Platform.Showrunner.SocialBundle

  @key "showrunner.post_show"
  @feature "showrunner"
  @template_slug "showrunner.post_show.v1"
  @meta_key "showrunner_post"
  @max_retries 1
  @retryable ~w(missing_audio upload_failed)

  @approve_item %{
    id: "approve-posts",
    question: "Approve posts",
    options: ["Approved", "Changes needed"]
  }

  @failed_item_id "post-show-failed"

  @system "You are the showrunner for How to Computer. After a recording you prepare " <>
            "everything for a human to approve. You never publish, schedule or submit."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The board meta key the post ids live under."
  @spec meta_key() :: String.t()
  def meta_key, do: @meta_key

  @doc "The Needs-you item a recorded post raises."
  @spec approve_item() :: map()
  def approve_item, do: @approve_item

  @doc "The Needs-you item id a twice-failed post raises."
  @spec failed_item_id() :: String.t()
  def failed_item_id, do: @failed_item_id

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          "topic" => "meeting:finished",
          "topic_pattern" => "meeting:finished:*",
          "event_match" => "meeting_finished"
        },
        scope: "per_space",
        context_provided: ["run_sheet", "transcript_id", "meeting_id"],
        output_contract: %{
          "show_notes" => "string",
          "clip_ids" => "list[string]",
          "draft_ids" => "list[string]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.showrunner",
          "status" => "active",
          "role" => "showrunner",
          "task" => "01a1eaf6",
          "requires_tool_bundle" => SocialBundle.bundle()
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    with {:ok, ctx, config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- ours(document, trigger_meta),
         :ok <- SocialBundle.guard(ctx, canvas, document, episode),
         :ok <- due(episode, document) do
      logistics = Board.meta(document, RecordingPrep.meta_key())
      payload = Runtime.meta(trigger_meta, :payload) || %{}

      {:ok,
       %{
         episode_number: episode.number,
         title: episode.title,
         run_sheet: RecordingPrep.run_sheet_text(episode),
         host_roles: Enum.join(config.host_roles, ", "),
         meeting_id: logistics["meeting_id"] || "",
         transcript_id: Runtime.meta(payload, :transcript_id) || "",
         retry_note: retry_note(trigger_meta),
         canvas_id: canvas.id,
         dispatch_space_id: ctx.space_id
       }}
    else
      {:parked, reason} -> {:handled, %{parked: SocialBundle.missing_item().id, reason: reason}}
      {:error, {:board_unreadable, _}} -> {:handled, %{board: :unreadable}}
      # Every meeting on the install finishes on this topic; another one is not a failure.
      {:error, :not_the_show_meeting} -> {:handled, %{skipped: :not_the_show_meeting}}
      {:error, :no_board} -> {:handled, %{skipped: :no_board}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns =
      Map.new(
        ~w(episode_number title run_sheet host_roles meeting_id transcript_id retry_note)a,
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
  def handle_output(%Responsibility{} = responsibility, output, trigger_meta, opts \\ []) do
    with {:ok, ctx, _config} <- Runtime.context(responsibility),
         %Canvas{} = canvas <- Runtime.board(ctx.space_id, trigger_meta) || {:error, :no_board},
         {:ok, episode, document} <- read(ctx, canvas),
         :ok <- due(episode, document) do
      case post(output) do
        {:ok, post} ->
          record(ctx, canvas, document, episode, post)

        {:retry, reason} ->
          retry(ctx, canvas, document, episode, reason, attempt(trigger_meta), opts)

        {:error, reason} = error ->
          Logger.warning("[showrunner.post_show] output refused: #{inspect(reason)}")
          error
      end
    else
      {:error, {:board_unreadable, _}} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("[showrunner.post_show] output refused: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("[showrunner.post_show] handle_output raised: #{Exception.message(error)}")
      {:error, :handle_output_failed}
  end

  @impl true
  def handle_refusal(%Responsibility{} = responsibility, refusal, _trigger_meta),
    do: Runtime.refused(responsibility, refusal)

  @doc """
  Reads the agent's report: `{:ok, %{show_notes, clip_ids, draft_ids}}`,
  `{:retry, reason}` for a reported missing audio or failed upload, or
  `{:error, reason}`.
  """
  @spec post(term()) :: {:ok, map()} | {:retry, String.t()} | {:error, term()}
  def post(output) do
    with {:ok, decoded} <- Runtime.decode(output) do
      case decoded["error"] do
        error when error in @retryable ->
          {:retry, error <> detail(decoded["detail"])}

        nil ->
          with {:ok, notes} <- notes(decoded["show_notes"]),
               {:ok, clip_ids} <- ids(decoded["clip_ids"] || [], :clip_ids),
               {:ok, draft_ids} <- ids(decoded["draft_ids"] || [], :draft_ids) do
            {:ok, %{show_notes: notes, clip_ids: clip_ids, draft_ids: draft_ids}}
          end

        other ->
          {:error, {:reported_error, other}}
      end
    end
  end

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

  # An event for some other meeting is not ours; a fire with no payload is.
  defp ours(document, trigger_meta) do
    case Runtime.meta(trigger_meta, :payload) do
      %{} = payload ->
        logistics = Board.meta(document, RecordingPrep.meta_key())
        space_id = Runtime.meta(payload, :space_id)
        room_id = Runtime.meta(payload, :room_id)

        cond do
          is_binary(space_id) and space_id == logistics["meeting_space_id"] -> :ok
          is_binary(room_id) and room_id == logistics["room_name"] -> :ok
          true -> {:error, :not_the_show_meeting}
        end

      _ ->
        :ok
    end
  end

  defp due(%Episode{stage: stage}, document) when stage in [:logistics, :record, :post] do
    if Board.meta(document, @meta_key)["recorded_at"],
      do: {:error, :already_posted},
      else: :ok
  end

  defp due(%Episode{stage: stage}, _document), do: {:error, {:not_due, stage}}

  defp record(ctx, canvas, document, episode, post) do
    episode = advance_to_post(episode)

    with {:ok, episode} <- Episode.add_needs_you(episode, @approve_item) do
      document =
        document
        |> Board.put_section("episode-show-notes", "Show notes", post.show_notes)
        |> Board.put_meta(@meta_key, %{
          "clip_ids" => post.clip_ids,
          "draft_ids" => post.draft_ids,
          "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

      with {:ok, _canvas} <- Board.write(ctx, canvas, document, episode) do
        Memory.append_journal(
          ctx.space_id,
          Memory.episode_entry(
            episode.number,
            "show notes: #{String.slice(post.show_notes, 0, 400)} " <>
              "(#{length(post.clip_ids)} clips, #{length(post.draft_ids)} drafts in approval)"
          )
        )

        Board.escalate(ctx, @approve_item,
          detail:
            "#{length(post.clip_ids)} clip picks and #{length(post.draft_ids)} drafts are " <>
              "waiting in approval. Nothing is published until you click publish."
        )

        :ok
      end
    end
  end

  defp advance_to_post(%Episode{stage: :post} = episode), do: episode

  defp advance_to_post(%Episode{} = episode) do
    case Episode.advance(episode, Episode.next_stage(episode.stage)) do
      {:ok, advanced} -> advance_to_post(advanced)
      {:error, _} -> episode
    end
  end

  defp retry(_ctx, canvas, _document, _episode, reason, attempt, opts)
       when attempt < @max_retries do
    Logger.info("[showrunner.post_show] #{reason}; retry #{attempt + 1}")

    Runtime.fire(
      @key,
      %{kind: :retry, canvas_id: canvas.id, retry_attempt: attempt + 1, retry_error: reason},
      Runtime.fire_fun(opts)
    )

    :ok
  end

  defp retry(ctx, canvas, document, episode, reason, _attempt, _opts) do
    Logger.warning("[showrunner.post_show] still failing (#{reason}); asking a person")

    item = %{
      id: @failed_item_id,
      question: "Post-show prep failed twice (#{reason}). Fix the recording and retry?",
      options: ["Retry", "Do it by hand"]
    }

    Board.raise_needs_you(ctx, canvas, document, episode, item)
    :ok
  end

  defp attempt(meta) do
    case Runtime.meta(meta, :retry_attempt) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp retry_note(meta) do
    case Runtime.meta(meta, :retry_error) do
      error when is_binary(error) and error != "" ->
        "The last attempt failed: #{error}. This is the one retry."

      _ ->
        ""
    end
  end

  defp notes(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank_show_notes}
      notes -> {:ok, notes}
    end
  end

  defp notes(_), do: {:error, :blank_show_notes}

  defp ids(list, field) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, Enum.uniq(list)},
      else: {:error, {:bad_ids, field}}
  end

  defp ids(_list, field), do: {:error, {:bad_ids, field}}

  defp detail(value) when is_binary(value) and value != "", do: ": " <> value
  defp detail(_), do: ""
end
