defmodule PlatformWeb.HealthController do
  use PlatformWeb, :controller

  alias Platform.SignInAdmin.Config, as: KeyConfig

  # Status stays 200 so status-only probes (the production quadlet's
  # `wget --spider`, `curl -fsS`, the router wiring test) are unaffected; the
  # body carries the build commit so an operator can read what is deployed
  # without dumping the container environment (task 01a089d5).
  #
  # Opt-in deep check (task 01a18f76): with `?deep=memory` AND
  # `Authorization: Bearer <the install's STATIC_API_KEY>`, the body also
  # carries `memory: "ok" | "unavailable"`, the outcome of one real search
  # through the configured memory provider (core -> memory-service ->
  # embeddings). The installer's runner polls it to tell a working memory path
  # from an embeddings crash loop. Anyone else gets exactly the plain body
  # and triggers no search, so this is not a free embed lever; a wrong key is
  # indistinguishable from no key (same status, same body).
  #
  # The key is core's copy of the install's pocket-id STATIC_API_KEY
  # (POCKET_ID_API_KEY, `Platform.SignInAdmin.Config.api_key/0`), compared in
  # constant time with `Plug.Crypto.secure_compare/2` as the agent-host socket
  # compares its token. No other STATIC_API_KEY comparison exists in core.
  def index(conn, params) do
    body = %{status: "ok", commit: Platform.BuildInfo.commit()}

    body =
      if params["deep"] == "memory" and key_matches?(conn),
        do: Map.put(body, :memory, memory_status()),
        else: body

    json(conn, body)
  end

  defp key_matches?(conn) do
    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         %KeyConfig.Key{value: expected} <- KeyConfig.api_key() do
      Plug.Crypto.secure_compare(presented, expected)
    else
      _ -> false
    end
  end

  # One word, so the embed itself is a fraction of a second even on the 4 GB
  # profile; the bound is for the wait behind work already queued on the
  # box's single embeddings slot (see deep_memory_timeout_ms/0).
  @probe_query "probe"

  defp memory_status do
    if Platform.Memory.enabled?() do
      timeout = deep_memory_timeout_ms()

      task =
        Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
          Platform.Memory.search(@probe_query, [limit: 1], timeout: timeout)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, _hits}} -> "ok"
        _ -> "unavailable"
      end
    else
      "unavailable"
    end
  end

  @doc """
  How long the deep memory check waits (`config :platform, :health_deep_memory_timeout_ms`).

  20 s, not 5 s (task 01a18f76, declared): on the 4 GB profile memory-service
  runs ONE embed at a time (`MEMORY_EMBEDDING_MAX_CONCURRENCY=1`) and a
  search queues behind any ingest chunk already in flight. Measured on an
  s-2vcpu-4gb droplet (2026-10-31): the slowest single chunk took 17.4 s
  (600 CJK chars), and a search issued during two concurrent page ingests
  answered in 12.6 s. A 5 s bound would report a working memory path as
  unavailable whenever an ingest is running; the runner's three-in-a-row
  rule then only passes on an idle box. Embedding the probe word itself
  takes well under 1 s.
  """
  def deep_memory_timeout_ms,
    do: Application.get_env(:platform, :health_deep_memory_timeout_ms, 20_000)
end
