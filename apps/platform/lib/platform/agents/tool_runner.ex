defmodule Platform.Agents.ToolRunner do
  @moduledoc """
  Agentic tool execution loop for the chat agent.

  Defines available tools as OpenAI Responses API function definitions, executes
  tool calls returned by the model, and manages the call → execute → call loop
  until the model produces a final text response or the iteration limit is reached.
  """

  require Logger

  alias Platform.Agents.Providers.Codex
  alias Platform.Agents.CodexAuth
  alias Platform.Chat
  alias Platform.Chat.CanvasDocument

  @max_iterations 5
  @shell_timeout_ms 30_000
  @file_read_max_bytes 50 * 1024
  @web_fetch_max_bytes 10 * 1024

  @doc """
  Returns the list of tool definitions in OpenAI Responses API format.
  """
  @spec tool_definitions() :: [map()]
  def tool_definitions do
    [
      %{
        "type" => "function",
        "name" => "shell_exec",
        "description" =>
          "Execute a shell command and return stdout, stderr, and exit code. Use for running scripts, checking system state, or performing file operations.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "The shell command to execute"
            },
            "workdir" => %{
              "type" => "string",
              "description" => "Optional working directory for the command"
            }
          },
          "required" => ["command"]
        }
      },
      %{
        "type" => "function",
        "name" => "file_read",
        "description" => "Read the contents of a file. Limited to 50KB.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute or relative path to the file"
            }
          },
          "required" => ["path"]
        }
      },
      %{
        "type" => "function",
        "name" => "file_write",
        "description" => "Write content to a file, creating parent directories as needed.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute or relative path to the file"
            },
            "content" => %{
              "type" => "string",
              "description" => "Content to write to the file"
            }
          },
          "required" => ["path", "content"]
        }
      },
      %{
        "type" => "function",
        "name" => "web_fetch",
        "description" => "Fetch a URL and return the response body text (up to 10KB).",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "description" => "The URL to fetch"
            }
          },
          "required" => ["url"]
        }
      },
      %{
        "type" => "function",
        "name" => "canvas_create",
        "description" =>
          "Create a live canvas in the current chat space. Always include initial_state with the full content to render. Use 'table' for data grids, 'code' for code snippets, 'diagram' for architecture diagrams, 'dashboard' for metrics, 'custom' for other types.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "Title of the canvas"
            },
            "canvas_type" => %{
              "type" => "string",
              "enum" => ["table", "code", "diagram", "dashboard", "custom"],
              "description" => "Type of canvas to create"
            },
            "initial_state" => %{
              "type" => "object",
              "description" =>
                "Required initial state for the canvas. For dashboard include metrics; for table include columns and rows; for code include source; for diagram include source."
            }
          },
          "required" => ["title", "canvas_type", "initial_state"]
        }
      },
      %{
        "type" => "function",
        "name" => "canvas_update",
        "description" => "Update an existing canvas's state.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "canvas_id" => %{
              "type" => "string",
              "description" => "The ID of the canvas to update"
            },
            "state" => %{
              "type" => "object",
              "description" => "The new state to apply to the canvas"
            }
          },
          "required" => ["canvas_id", "state"]
        }
      }
    ]
  end

  @doc """
  Run the agentic tool loop.

  Calls the Codex provider with tool definitions, executes any tool calls in the
  response, feeds results back, and repeats until the model produces a text
  response or the iteration limit is reached.

  Returns `{:ok, response}` where `response` matches the QuickAgent response map,
  or `{:error, reason}`.
  """
  @spec run(binary(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(system_prompt, messages, opts) do
    with {:ok, credentials} <- get_credentials(opts) do
      do_run(system_prompt, messages, opts, credentials, 0)
    end
  end

  defp get_credentials(opts) do
    path =
      Keyword.get(opts, :codex_auth_path) ||
        Application.get_env(:platform, :codex_auth_file)

    auth_opts = if path, do: [path: path], else: []

    CodexAuth.credentials(auth_opts)
  end

  defp do_run(_system_prompt, _messages, _opts, _credentials, iteration)
       when iteration >= @max_iterations do
    Logger.warning("[ToolRunner] max iterations (#{@max_iterations}) reached, stopping loop")
    {:error, :max_iterations_reached}
  end

  defp do_run(system_prompt, messages, opts, credentials, iteration) do
    Logger.info("[ToolRunner] iteration=#{iteration}")

    provider_opts = build_provider_opts(system_prompt, opts)

    case provider_module().chat(credentials, messages, provider_opts) do
      {:ok, response} ->
        tool_calls = Map.get(response, :tool_calls, [])

        if tool_calls == [] or is_nil(tool_calls) do
          # Final text response
          {:ok, response}
        else
          Logger.info("[ToolRunner] executing #{length(tool_calls)} tool call(s)")

          tool_context = Keyword.get(opts, :tool_context, %{})
          tool_results = Enum.map(tool_calls, &execute_tool_call(&1, tool_context))

          # Append tool call items and results to messages for the next round
          tool_call_items =
            Enum.map(tool_calls, fn call ->
              %{
                "type" => "function_call",
                "call_id" => call["call_id"],
                "name" => call["name"],
                "arguments" => call["arguments"]
              }
            end)

          result_items =
            Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
              %{
                "type" => "function_call_output",
                "call_id" => call_id,
                "output" => output
              }
            end)

          updated_messages = messages ++ tool_call_items ++ result_items

          # After a successful canvas_create call, remove tools from subsequent
          # iterations to prevent duplicate canvas creation. Failed validation
          # errors should keep tools enabled so the model can retry with the
          # required initial_state.
          canvas_was_created =
            Enum.any?(tool_results, fn %{output: output} ->
              is_binary(output) and String.starts_with?(output, "Canvas created")
            end)

          next_opts =
            if canvas_was_created do
              Keyword.put(opts, :tools, [])
            else
              opts
            end

          do_run(system_prompt, updated_messages, next_opts, credentials, iteration + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_provider_opts(system_prompt, opts) do
    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:platform, :chat_agent_model) ||
        "gpt-5.4"

    [
      system: system_prompt,
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, 2048),
      tools: Keyword.get(opts, :tools, tool_definitions()),
      session_id: Keyword.get(opts, :session_id)
    ]
  end

  defp execute_tool_call(
         %{"name" => name, "call_id" => call_id, "arguments" => args_json},
         context
       ) do
    Logger.info("[ToolRunner] executing tool=#{name} call_id=#{call_id}")

    args =
      case Jason.decode(args_json) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end

    Logger.info("[ToolRunner] tool=#{name} args=#{inspect(args) |> String.slice(0, 500)}")

    output = run_tool(name, args, context)

    %{call_id: call_id, output: output}
  end

  defp execute_tool_call(call, _context) do
    Logger.warning("[ToolRunner] malformed tool call: #{inspect(call)}")
    %{call_id: Map.get(call, "call_id", "unknown"), output: "error: malformed tool call"}
  end

  # --- Tool implementations ---

  defp run_tool("shell_exec", %{"command" => command} = args, _context) do
    workdir = Map.get(args, "workdir")
    opts = [stderr_to_stdout: false]

    opts =
      if workdir do
        Keyword.put(opts, :cd, workdir)
      else
        opts
      end

    task =
      Task.async(fn ->
        case System.cmd("sh", ["-c", command], opts) do
          {stdout, 0} ->
            Jason.encode!(%{stdout: stdout, stderr: "", exit_code: 0})

          {stdout, exit_code} ->
            Jason.encode!(%{stdout: stdout, stderr: "", exit_code: exit_code})
        end
      end)

    case Task.yield(task, @shell_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        Jason.encode!(%{
          stdout: "",
          stderr: "error: command timed out after 30 seconds",
          exit_code: -1
        })
    end
  rescue
    error ->
      Jason.encode!(%{stdout: "", stderr: "error: #{Exception.message(error)}", exit_code: -1})
  end

  defp run_tool("file_read", %{"path" => path}, _context) do
    case File.read(path) do
      {:ok, content} ->
        truncated = String.slice(content, 0, @file_read_max_bytes)

        if byte_size(content) > @file_read_max_bytes do
          truncated <> "\n[...truncated at 50KB...]"
        else
          truncated
        end

      {:error, reason} ->
        "error: could not read file '#{path}': #{:file.format_error(reason)}"
    end
  end

  defp run_tool("file_write", %{"path" => path, "content" => content}, _context) do
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent),
         :ok <- File.write(path, content) do
      "ok: wrote #{byte_size(content)} bytes to #{path}"
    else
      {:error, reason} ->
        "error: could not write file '#{path}': #{:file.format_error(reason)}"
    end
  end

  defp run_tool("web_fetch", %{"url" => url}, _context) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        text =
          cond do
            is_binary(body) -> body
            is_map(body) -> Jason.encode!(body)
            true -> inspect(body)
          end

        String.slice(text, 0, @web_fetch_max_bytes)

      {:ok, %{status: status}} ->
        "error: HTTP #{status}"

      {:error, reason} ->
        "error: request failed: #{inspect(reason)}"
    end
  rescue
    error -> "error: #{Exception.message(error)}"
  end

  defp run_tool(
         "canvas_create",
         args,
         %{space_id: space_id, participant_id: participant_id} = context
       )
       when is_binary(space_id) and is_binary(participant_id) do
    canvas_type = Map.get(args, "canvas_type", "custom")
    initial_state = Map.get(args, "initial_state") || %{}

    with {:ok, resolved_initial_state} <-
           resolve_canvas_initial_state(canvas_type, initial_state, context) do
      # Seed a canonical document from the initial state so the renderer
      # can immediately display real content inline.
      seeded_document = CanvasDocument.seed(canvas_type, resolved_initial_state)

      attrs = %{
        "title" => Map.get(args, "title"),
        "canvas_type" => canvas_type,
        "state" => seeded_document
      }

      case Chat.create_canvas_with_message(space_id, participant_id, attrs) do
        {:ok, canvas, _message} ->
          "Canvas created (id=#{canvas.id}, title=#{canvas.title}). " <>
            "Respond with a brief text message describing what you created."

        {:error, reason} ->
          "error: could not create canvas: #{inspect(reason)}"
      end
    else
      {:error, reason} ->
        "error: #{reason}"
    end
  end

  defp run_tool("canvas_create", _args, _context) do
    "error: canvas_create requires space_id and participant_id context"
  end

  defp run_tool("canvas_update", %{"canvas_id" => canvas_id, "state" => state}, _context) do
    alias Platform.Chat.Canvas

    case Platform.Repo.get(Canvas, canvas_id) do
      nil ->
        "error: canvas #{canvas_id} not found"

      canvas ->
        case Chat.update_canvas_state(canvas, state) do
          {:ok, _updated} ->
            "ok: updated canvas #{canvas_id}"

          {:error, reason} ->
            "error: could not update canvas: #{inspect(reason)}"
        end
    end
  end

  defp run_tool(name, args, _context) do
    Logger.warning("[ToolRunner] unknown tool=#{name} args=#{inspect(args)}")
    "error: unknown tool '#{name}'"
  end

  defp resolve_canvas_initial_state(canvas_type, initial_state, context) do
    case validate_canvas_initial_state(canvas_type, initial_state) do
      :ok ->
        {:ok, initial_state}

      {:error, reason} ->
        case infer_canvas_initial_state(canvas_type, context) do
          {:ok, inferred_state} ->
            Logger.info(
              "[ToolRunner] inferred missing initial_state for canvas_type=#{canvas_type}"
            )

            {:ok, inferred_state}

          :error ->
            {:error, reason}
        end
    end
  end

  defp infer_canvas_initial_state("dashboard", %{user_message: user_message})
       when is_binary(user_message) do
    with {:error, :no_json_metrics} <- infer_dashboard_metrics_from_json(user_message),
         {:error, :no_inline_metrics} <- infer_dashboard_metrics_from_inline_text(user_message) do
      :error
    else
      {:ok, metrics} -> {:ok, %{"metrics" => metrics}}
    end
  end

  defp infer_canvas_initial_state(_canvas_type, _context), do: :error

  defp validate_canvas_initial_state("dashboard", %{"metrics" => metrics})
       when is_list(metrics) do
    if Enum.any?(metrics, &dashboard_metric?/1) do
      :ok
    else
      {:error,
       "canvas_create for dashboard requires initial_state.metrics with at least one metric map containing label and value. Retry canvas_create with full initial_state."}
    end
  end

  defp validate_canvas_initial_state("dashboard", _state) do
    {:error,
     "canvas_create for dashboard requires initial_state.metrics with at least one metric map containing label and value. Retry canvas_create with full initial_state."}
  end

  defp validate_canvas_initial_state("table", %{"columns" => columns, "rows" => rows})
       when is_list(columns) and is_list(rows) and columns != [] and rows != [] do
    :ok
  end

  defp validate_canvas_initial_state("table", _state) do
    {:error,
     "canvas_create for table requires initial_state.columns and initial_state.rows with populated data. Retry canvas_create with full initial_state."}
  end

  defp validate_canvas_initial_state("code", state) when is_map(state) do
    source = Map.get(state, "source") || Map.get(state, "content")

    if is_binary(source) and String.trim(source) != "" do
      :ok
    else
      {:error,
       "canvas_create for code requires initial_state.source (or content) with the full code snippet. Retry canvas_create with full initial_state."}
    end
  end

  defp validate_canvas_initial_state("diagram", %{"source" => source}) when is_binary(source) do
    if String.trim(source) != "" do
      :ok
    else
      {:error,
       "canvas_create for diagram requires initial_state.source with the diagram definition. Retry canvas_create with full initial_state."}
    end
  end

  defp validate_canvas_initial_state("diagram", _state) do
    {:error,
     "canvas_create for diagram requires initial_state.source with the diagram definition. Retry canvas_create with full initial_state."}
  end

  defp validate_canvas_initial_state(_canvas_type, state) when is_map(state), do: :ok

  defp validate_canvas_initial_state(_canvas_type, _state),
    do: {:error, "canvas_create requires initial_state to be an object."}

  defp infer_dashboard_metrics_from_json(user_message) do
    case Regex.run(~r/metrics\s*:?\s*(\[[\s\S]*?\])/u, user_message, capture: :all_but_first) do
      [json] ->
        with {:ok, metrics} <- Jason.decode(json),
             true <- is_list(metrics),
             filtered when filtered != [] <- Enum.filter(metrics, &dashboard_metric?/1) do
          {:ok, filtered}
        else
          _ -> {:error, :no_json_metrics}
        end

      _ ->
        {:error, :no_json_metrics}
    end
  end

  defp infer_dashboard_metrics_from_inline_text(user_message) do
    tail =
      case Regex.run(~r/metrics\s+(.+)/ui, user_message, capture: :all_but_first) do
        [rest] -> rest
        _ -> user_message
      end

    metrics =
      Regex.scan(
        ~r/(?:^|,\s*)([A-Za-z][A-Za-z0-9 _-]*)\s*=\s*([^,]+(?:,\d{3})*(?:\.\d+)?%?|\$?\d[\d,]*(?:\.\d+)?[kKmMbB]?|[^,]+?)\s*([↑↓→])/u,
        tail,
        capture: :all_but_first
      )
      |> Enum.map(fn [label, value, trend] ->
        %{
          "label" => String.trim(label),
          "value" => String.trim(value),
          "trend" => String.trim(trend)
        }
      end)
      |> Enum.filter(&dashboard_metric?/1)

    if metrics == [] do
      {:error, :no_inline_metrics}
    else
      {:ok, metrics}
    end
  end

  defp dashboard_metric?(%{"label" => label, "value" => value}) do
    present_string?(label) and present_value?(value)
  end

  defp dashboard_metric?(_metric), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(value) when is_number(value), do: true
  defp present_value?(value) when is_boolean(value), do: true
  defp present_value?(_value), do: false

  defp provider_module do
    Application.get_env(:platform, :quick_agent_provider_module, Codex)
  end
end
