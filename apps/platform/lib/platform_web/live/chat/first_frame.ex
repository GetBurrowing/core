defmodule PlatformWeb.ChatLive.FirstFrame do
  @moduledoc """
  Instrumentation and knobs for what chat puts in its first frame (task
  01a17bf4, "smaller first frame for chat").

  ## Spans

  Every segment of the synchronous space-entry path in
  `PlatformWeb.ChatLive.handle_params/3` runs inside `span/2` or `span/3`,
  which emits `:telemetry.span/3` events under

      [:platform_web, :chat, :enter_space, segment, :start | :stop | :exception]

  with `%{segment: segment}` as metadata. Durations are native time units, as
  `:telemetry.span/3` always reports them. Nothing about the space, the user
  or the content is in the metadata: the dev-only tab-switch probe
  (`e2e/scripts/tab_switch_probe.exs`) records only segment names, durations
  and the Repo query count inside each span.

  ## Knobs

      config :platform, PlatformWeb.ChatLive,
        initial_message_count: 50,
        deferred_side_state: []

  Both are read with `Application.get_env/3` at CALL time, not compile time,
  so the harness can flip them on a running dev node. The defaults keep
  today's behaviour: 50 is the default window `MessagesHooks.enter_space/3`
  has always loaded, and an empty deferred set defers nothing.
  """

  @event_prefix [:platform_web, :chat, :enter_space]

  @default_initial_message_count 50

  @doc "The telemetry event prefix for a segment (without the span suffix)."
  @spec event(atom()) :: [atom()]
  def event(segment) when is_atom(segment), do: @event_prefix ++ [segment]

  @doc """
  Run `fun` (arity 0) inside the span for `segment` and return its result.
  """
  @spec span(atom(), (-> result)) :: result when result: term()
  def span(segment, fun) when is_atom(segment) and is_function(fun, 0) do
    :telemetry.span(event(segment), %{segment: segment}, fn ->
      {fun.(), %{segment: segment}}
    end)
  end

  @doc """
  Pipeline form: run `fun.(socket)` (arity 1) inside the span for `segment`.
  """
  @spec span(Phoenix.LiveView.Socket.t(), atom(), (Phoenix.LiveView.Socket.t() -> result)) ::
          result
        when result: term()
  def span(socket, segment, fun) when is_atom(segment) and is_function(fun, 1) do
    span(segment, fn -> fun.(socket) end)
  end

  @doc """
  Number of newest top-level messages a default (non-anchored) space entry
  loads. A positive integer; anything else falls back to the default.
  """
  @spec initial_message_count() :: pos_integer()
  def initial_message_count do
    case Keyword.get(config(), :initial_message_count, @default_initial_message_count) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_initial_message_count
    end
  end

  @doc """
  Segments whose state is loaded after the join reply rather than in it.
  A list of segment atoms; anything else reads as `[]`.
  """
  @spec deferred_side_state() :: [atom()]
  def deferred_side_state do
    case Keyword.get(config(), :deferred_side_state, []) do
      list when is_list(list) -> Enum.filter(list, &is_atom/1)
      _ -> []
    end
  end

  defp config, do: Application.get_env(:platform, PlatformWeb.ChatLive, [])
end
