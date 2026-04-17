defmodule Platform.Meetings.Summarizer do
  @moduledoc """
  Async meeting transcript summarization pipeline.

  When a meeting ends, `summarize_async/1` spawns a Task under
  `Platform.TaskSupervisor` that:

  1. Formats the transcript segments into speaker-attributed text
  2. Calls the Anthropic provider to generate a structured summary
  3. Stores the summary on the transcript record
  4. Posts the summary as a system message to the space

  The async pattern keeps the webhook response fast — the caller doesn't
  wait for the LLM round-trip.
  """

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.Config
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI

  @doc """
  Spawns an async task to summarize the given transcript.

  The transcript must have status "processing" and a non-empty segments list.
  Returns `{:ok, pid}` on successful spawn, or `{:error, reason}` if the
  transcript is not ready for summarization.
  """
  def summarize_async(%{id: id, segments: segments, status: status} = transcript)
      when is_list(segments) do
    cond do
      status not in ["processing", "recording"] ->
        Logger.warning("[Summarizer] Transcript #{id} has status #{status}, skipping")
        {:error, :invalid_status}

      segments == [] ->
        Logger.info(
          "[Summarizer] Transcript #{id} has no segments, marking complete with empty summary"
        )

        handle_empty_transcript(transcript)
        {:ok, :empty}

      true ->
        {:ok, pid} =
          Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
            run_summary(transcript)
          end)

        Logger.info("[Summarizer] Started summary task #{inspect(pid)} for transcript #{id}")
        {:ok, pid}
    end
  end

  def summarize_async(%{id: id}) do
    Logger.warning("[Summarizer] Transcript #{id} missing required fields for summarization")
    {:error, :missing_fields}
  end

  def summarize_async(_), do: {:error, :invalid_transcript}

  @doc """
  Synchronous summary generation — used by tests and when you want to
  wait for the result.
  """
  def run_summary(%{id: id, space_id: space_id, segments: segments} = _transcript) do
    Logger.info(
      "[Summarizer] Generating summary for transcript #{id} (#{length(segments)} segments)"
    )

    formatted_text = SummaryPrompt.format_segments(segments)

    messages = [
      %{
        role: "user",
        content: "Please summarize the following meeting transcript:\n\n#{formatted_text}"
      }
    ]

    cfg = Config.summary()

    opts =
      [
        system: SummaryPrompt.system_prompt(),
        model: cfg.model,
        max_tokens: cfg.max_tokens,
        temperature: cfg.temperature
      ]
      |> maybe_put(:base_url, cfg.base_url)

    case call_llm(cfg, messages, opts) do
      {:ok, summary_text} ->
        Logger.info(
          "[Summarizer] Summary generated for transcript #{id} (#{String.length(summary_text)} chars)"
        )

        case Meetings.complete_transcript(id, summary_text) do
          {:ok, _transcript} ->
            if is_binary(space_id) do
              Meetings.post_summary_to_space(space_id, id, summary_text)
            else
              Logger.info("[Summarizer] No space_id for transcript #{id}, skipping summary post")
            end

            :ok

          {:error, reason} ->
            Logger.error("[Summarizer] Failed to complete transcript #{id}: #{inspect(reason)}")
            Meetings.fail_transcript(id)
            {:error, {:complete_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("[Summarizer] LLM call failed for transcript #{id}: #{inspect(reason)}")
        Meetings.fail_transcript(id)
        {:error, {:llm_failed, reason}}
    end
  rescue
    e ->
      Logger.error("[Summarizer] Unexpected error for transcript #{id}: #{Exception.message(e)}")
      Meetings.fail_transcript(id)
      {:error, {:unexpected, e}}
  end

  # -- Private ---------------------------------------------------------------

  defp handle_empty_transcript(%{id: id}) do
    summary = "This meeting had no transcribed content."

    case Meetings.complete_transcript(id, summary) do
      {:ok, _} ->
        Logger.info("[Summarizer] Empty transcript #{id} marked complete (no summary posted)")
        :ok

      {:error, reason} ->
        Logger.error("[Summarizer] Failed to complete empty transcript #{id}: #{inspect(reason)}")
        Meetings.fail_transcript(id)
        {:error, reason}
    end
  end

  defp call_llm(%{provider: :none}, _messages, _opts) do
    {:error, :no_summary_provider_configured}
  end

  defp call_llm(%{provider: provider} = cfg, messages, opts) do
    credentials = llm_credentials(cfg)
    adapter = provider_adapter(provider)

    case adapter.chat(credentials, messages, opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{content: [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, %{"content" => [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, other} ->
        Logger.warning("[Summarizer] Unexpected LLM response shape: #{inspect(other)}")
        extract_text_from_response(other)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_adapter(:anthropic), do: Anthropic
  defp provider_adapter(:openai), do: OpenAI
  defp provider_adapter(:ollama), do: Ollama

  defp provider_adapter(other),
    do: raise(ArgumentError, "Unknown summary provider: #{inspect(other)}")

  defp extract_text_from_response(%{content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "text") || Map.get(&1, :text, "")))
      |> Enum.join("\n")

    if text == "", do: {:error, :empty_response}, else: {:ok, text}
  end

  defp extract_text_from_response(_), do: {:error, :unrecognized_response}

  defp llm_credentials(%{provider: :anthropic, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :openai, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "openai"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :ollama, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(_), do: %{}

  defp api_key_from_env(nil), do: nil
  defp api_key_from_env(name) when is_binary(name), do: System.get_env(name)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
