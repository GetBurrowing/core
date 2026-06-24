defmodule Platform.Responsibilities.WebhookRouter do
  @moduledoc """
  Thin webhook ingress surface for the M6 Responsibilities runtime
  (ADR-0041 stage 3).

  HTTP controllers that receive external webhook payloads call
  `notify/2` with the configured webhook path and an opaque payload
  map. This module casts the message into
  `Platform.Responsibilities.Router`, which looks up every enabled
  webhook responsibility whose `trigger_config["path"]` matches and
  fires it through the canonical `fire_trigger/3` pipeline.

  Keeping this as a separate module — instead of having controllers
  call `GenServer.cast/2` directly — lets us:

    * stub the cast destination in tests via a `:router` option,
    * evolve the wire protocol (e.g. add idempotency keys, batching)
      without touching every controller,
    * keep the controller layer ignorant of `Platform.Responsibilities`
      internals (the controller just calls a feature-named function).

  Casts are fire-and-forget. A webhook nudging a responsibility whose
  Router instance is down logs a warning and returns `:ok` — webhook
  retries are the caller's concern, not ours.
  """

  require Logger

  alias Platform.Responsibilities.Router

  @doc """
  Notify the Router that an external webhook has fired for `path`,
  carrying `payload`.

  The optional `opts` keyword accepts:

    * `:router` — the registered name (or pid) of the Router GenServer
      to cast into. Defaults to `Platform.Responsibilities.Router`.
      Tests pass an isolated instance name so they can run async.

  Always returns `:ok` (cast semantics). If the named Router is not
  running we log + swallow rather than raise — webhook delivery should
  not crash a request handler.
  """
  @spec notify(String.t(), map(), keyword()) :: :ok
  def notify(path, payload, opts \\ [])
      when is_binary(path) and is_map(payload) and is_list(opts) do
    router = Keyword.get(opts, :router, Router)

    try do
      GenServer.cast(router, {:webhook_fire, path, payload})
    catch
      :exit, reason ->
        # Defensive: GenServer.cast/2 to a missing locally-registered
        # name returns :ok silently, but a `{:via, …}` registration
        # whose registry refuses the lookup will exit. Swallow it so
        # webhook ingress never crashes the HTTP request handler.
        Logger.warning(
          "[ResponsibilityWebhookRouter] cast to #{inspect(router)} failed " <>
            "path=#{path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end
end
