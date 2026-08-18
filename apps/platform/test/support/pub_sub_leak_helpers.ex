defmodule Platform.PubSubLeakHelpers do
  @moduledoc """
  Shared machinery for the PubSub scoped-leak regression tests (task 019ffca8
  stage 5).

  Used by `Platform.Regression.GlobalTopicScopeLeakTest` and
  `Platform.Regression.MeetingsTopicScopeLeakTest`. Both files test the same
  property against different topic families: a subscriber outside a scope either
  does not receive the event, or cannot derive protected content from it.

  ## The watcher

  `watcher/2` runs the SCOPED subscription in its own process and relays
  everything it receives to the test process, tagged. The test process keeps the
  BARE subscription for itself.

  A second process rather than two subscriptions in one mailbox, because the
  dual-publish helpers in `Platform.Meetings.PubSub`
  (`broadcast_transcript_chunk/2`, `broadcast_meeting_finished/2`) emit the SAME
  event term on both topics from one call. A single mailbox holding both
  subscriptions cannot tell which topic delivered a given copy. Distinguishing
  them by arrival order works but makes a security test depend on
  message-ordering reasoning. Tagging by process does not.

  ## Phoenix.PubSub semantics these helpers are built around

  The registry is `keys: :duplicate` and `subscribe/3` is a bare
  `Registry.register`, so a repeat subscribe from one pid creates a SECOND
  registration and the pid receives every broadcast twice; `unsubscribe/2`
  removes ALL of that pid's entries for the topic. `chat_live.ex:725-732` states
  this correctly and works around it; `canvas_hooks.ex:81-83` states the
  opposite and is wrong. Every subscription taken through these helpers is taken
  exactly once per process, which is why no test using them counts deliveries.
  """

  import ExUnit.Assertions

  @lib_root Path.expand("../../lib", __DIR__)

  @doc "Path to `apps/platform/lib`, for the source-scanning assertions."
  def lib_root, do: @lib_root

  @doc """
  Spawns a process holding the subscription `subscribe_fun` takes, relaying
  every message it receives to the caller as `{tag, message}`.

  Blocks until the subscription is registered, so a broadcast issued after this
  returns cannot race the subscribe. `flunk`s rather than returning if the
  handshake never lands: a watcher that never subscribed would make every refute
  against it vacuous, which is the exact failure this whole suite exists to
  prevent.
  """
  def watcher(tag, subscribe_fun) do
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = subscribe_fun.()
        send(parent, {:subscribed, tag})
        relay(parent, tag)
      end)

    receive do
      {:subscribed, ^tag} -> :ok
    after
      2_000 ->
        flunk("the #{inspect(tag)} watcher never subscribed, so its refute would be vacuous")
    end

    # `relay/2` never returns, and a test process exiting `:normal` does not
    # take a non-trapping linked child with it. Without this the watcher
    # survives the test, keeps its registration, and loops sending into a dead
    # pid for the rest of the run.
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)

    pid
  end

  defp relay(parent, tag) do
    receive do
      msg -> send(parent, {tag, msg})
    end

    relay(parent, tag)
  end

  @doc """
  Waits `window` ms, then takes EVERY message currently queued on the calling
  process, without pattern matching.

  `refute_receive` can only refute a shape it can write as a pattern, and a
  guard cannot call `inspect/2`, so a "no message contains this string anywhere"
  claim has to look at the messages themselves.
  """
  def collect(window) do
    Process.sleep(window)
    do_collect([])
  end

  defp do_collect(acc) do
    receive do
      msg -> do_collect([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  `inspect/2` with unbounded limits.

  A truncated inspect would silently make a content refute pass on a payload
  that DOES carry the secret, just deeper than the default 50-element cutoff.
  """
  def deep_inspect(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  @doc """
  Asserts that no message in `messages` mentions `needle` at any depth.

  `=~` with a binary right operand is substring matching, so a needle containing
  regex metacharacters is safe.
  """
  def refute_any_mentions(messages, needle, context) do
    offenders = Enum.filter(messages, &(deep_inspect(&1) =~ needle))

    assert offenders == [], """
    #{context}

    #{Enum.map_join(offenders, "\n\n", &deep_inspect/1)}
    """
  end

  @doc """
  Every `.ex` under `lib/platform_web`, with a floor so a moved path fails
  loudly instead of turning every scan over it into a vacuous pass.
  """
  def web_sources do
    sources = Path.wildcard(Path.join(@lib_root, "platform_web/**/*.ex"))

    assert length(sources) > 50,
           "the platform_web source glob found #{length(sources)} files, so any scan over it is " <>
             "passing vacuously — the path moved"

    sources
  end

  @doc "Every `.ex` under `lib`, with the same floor."
  def lib_sources do
    sources = Path.wildcard(Path.join(@lib_root, "**/*.ex"))

    assert length(sources) > 200,
           "the lib source glob found #{length(sources)} files, so any scan over it is passing " <>
             "vacuously — the path moved"

    sources
  end

  @doc "The subset of `sources` matching `regex`, as paths relative to `lib`."
  def matching_sources(sources, regex) do
    sources
    |> Enum.filter(&(File.read!(&1) =~ regex))
    |> Enum.map(&Path.relative_to(&1, @lib_root))
    |> Enum.sort()
  end
end
