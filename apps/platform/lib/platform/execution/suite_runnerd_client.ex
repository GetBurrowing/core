defmodule Platform.Execution.SuiteRunnerdClient do
  @moduledoc """
  Thin HTTP client for the `suite-runnerd` control service.

  The BEAM-side execution plane remains the source of truth for lifecycle and
  context state. This client only handles the mechanical container operations
  delegated to the companion service:

    * spawn a runner container for a run
    * describe its current provider state (status, health, timing)
    * request a graceful stop
    * force an immediate kill

  Keeping this seam explicit lets `DockerRunner` reuse the same
  `Platform.Execution.Runner` contract as the local provider without baking
  transport concerns into `RunServer`.

  ## Spawn payload

  `spawn_run/3` forwards the full payload built by `DockerRunner`, which includes:

    - `:run_id`, `:task_id`, `:project_id`, `:epic_id`
    - `:workspace_root`, `:workspace_path`, `:command`, `:args`, `:env`
    - `:security` map — user, no_new_privileges, capability_drop/add, no_docker_socket
    - `:mount` map — bind mount instructions for the per-run worktree
    - `:meta` — arbitrary metadata forwarded to the container

  `suite-runnerd` is responsible for translating these fields into a concrete
  `docker run` invocation.

  ## Describe response

  `describe_run/3` returns a map with at least:

    - `:status`       — container state atom (`:starting`, `:running`, `:exited`, `:killed`, `:stopped`)
    - `:exit_code`    — integer exit code or `nil` if still running
    - `:container_id` — Docker container ID (short form)
    - `:image`        — image reference used at spawn
    - `:stop_mode`    — `:graceful` | `:kill` | `nil`
    - `:started_at`   — ISO8601 string or `nil`
    - `:finished_at`  — ISO8601 string or `nil`
    - `:exit_message` — stderr tail or `nil`
    - `:health`       — `:healthy` | `:degraded` | `:unknown` or `nil`

  ## Authentication

  Requests can carry a bearer token via:
    1. `:token` key in `client_opts`
    2. Application config: `config :platform, :execution, suite_runnerd: [token: "..."]`

  ## Configuration

      config :platform, :execution,
        suite_runnerd: [
          base_url: "http://127.0.0.1:4101",
          token: "..."
        ]
  """

  alias Platform.Execution.Run

  @type provider_ref :: map()
  @type request_opts :: keyword()

  @callback spawn_run(Run.t(), map(), request_opts()) :: {:ok, provider_ref()} | {:error, term()}
  @callback describe_run(Run.t(), provider_ref(), request_opts()) ::
              {:ok, map()} | {:error, term()}
  @callback request_stop(Run.t(), provider_ref(), request_opts()) :: :ok | {:error, term()}
  @callback force_stop(Run.t(), provider_ref(), request_opts()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  @default_base_url "http://127.0.0.1:4101"
  @default_receive_timeout 15_000

  @impl true
  def spawn_run(%Run{} = run, payload, opts \\ []) when is_map(payload) do
    request(:post, "/api/runs",
      json: Map.put(payload, :run_id, run.id),
      opts: opts,
      ok?: &match?({:ok, %{status: status}} when status in 200..299, &1)
    )
  end

  @impl true
  def describe_run(%Run{} = run, provider_ref, opts \\ []) when is_map(provider_ref) do
    request(:get, run_path(run, provider_ref),
      opts: opts,
      ok?: &match?({:ok, %{status: status}} when status in 200..299, &1)
    )
  end

  @impl true
  def request_stop(%Run{} = run, provider_ref, opts \\ []) when is_map(provider_ref) do
    case request(:post, run_path(run, provider_ref, "/stop"), opts: opts, ok?: ok_status?()) do
      {:ok, _body} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def force_stop(%Run{} = run, provider_ref, opts \\ []) when is_map(provider_ref) do
    case request(:post, run_path(run, provider_ref, "/kill"), opts: opts, ok?: ok_status?()) do
      {:ok, _body} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_path(%Run{id: run_id}, provider_ref, suffix \\ "") do
    container_id = Map.get(provider_ref, :container_id) || Map.get(provider_ref, "container_id")

    cond do
      is_binary(container_id) and container_id != "" -> "/api/runs/#{container_id}#{suffix}"
      true -> "/api/runs/#{run_id}#{suffix}"
    end
  end

  defp request(method, path, req_opts) do
    opts = Keyword.get(req_opts, :opts, [])
    ok? = Keyword.fetch!(req_opts, :ok?)

    request_opts =
      [
        method: method,
        url: base_url(opts) <> path,
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
        retry: false
      ]
      |> maybe_put_json(Keyword.get(req_opts, :json))
      |> maybe_put_auth(opts)

    case Req.request(request_opts) do
      {:ok, %{body: body} = response} ->
        if ok?.({:ok, response}) do
          {:ok, normalize_body(body)}
        else
          {:error, {:suite_runnerd_http_error, response.status, body}}
        end

      {:error, reason} ->
        {:error, {:suite_runnerd_request_failed, reason}}
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp maybe_put_auth(opts, req_opts) do
    case Keyword.get(req_opts, :token) || configured_token() do
      nil -> opts
      token -> Keyword.put(opts, :auth, {:bearer, token})
    end
  end

  defp base_url(opts) do
    Keyword.get(opts, :base_url) || configured_base_url()
  end

  defp configured_base_url do
    :platform
    |> Application.get_env(:execution, [])
    |> Keyword.get(:suite_runnerd, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp configured_token do
    :platform
    |> Application.get_env(:execution, [])
    |> Keyword.get(:suite_runnerd, [])
    |> Keyword.get(:token)
  end

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body) when is_list(body), do: Enum.into(body, %{})
  defp normalize_body(body), do: %{"raw" => body}

  defp ok_status?, do: &match?({:ok, %{status: status}} when status in 200..299, &1)
end
