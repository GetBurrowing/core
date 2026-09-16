defmodule Platform.Meetings.PressWindow do
  @moduledoc """
  Per-meeting push-to-talk press windows, keyed on speaker identity
  (task 01a03f4e, plan v2 stage 1).

  ## What this is NOT

  It is not a recorder, and nothing here touches audio. The user's
  microphone never reaches Suite: `meeting_client.js`'s `_toggleMic`
  publishes to the LiveKit SFU via
  `room.localParticipant.setMicrophoneEnabled/1`, and there is no
  `getUserMedia`, `MediaRecorder` or `AudioContext` anywhere in
  `assets/` or `lib/` (measured 2026-08-29 on `ce6d49ce`; the positive
  control `setMicrophoneEnabled|localParticipant` hits seven source
  hooks, so the empty result is an absence rather than a broken
  pattern).

  Push-to-talk is therefore a **marker laid over the transcript stream
  that is already flowing**. The transcriber posts segments to
  `PlatformWeb.MeetingAgentController`, each carrying a
  `participant_identity` of the form `"user:<uuid>"`. This module
  records "identity X was holding the talk key from T1 to T2" so that a
  later stage can ask, of a segment that just arrived, *was this said
  into the direct channel?*

  This stage builds the store and the matching logic and nothing else.
  Tagging segments, writing candidate rows, agent attachment and UI all
  belong to later stages.

  ## The clock problem

  A segment has no absolute timestamp. `normalize_segment/1` in the
  controller carries `start_time` / `end_time`, and those are offsets in
  milliseconds relative to the transcription session — `append_segment/2`
  writes the segment map into JSONB verbatim and stamps no wall clock of
  its own. So the only wall-clock instant available for a segment is the
  moment it *arrives*, and arrival lags the speech that produced it by
  however long the transcriber took to finalise.

  Two consequences, both deliberate:

    * Press and release are stamped **server-side** on arrival, not by
      the browser. A client clock is not trustworthy and would not be
      comparable with the arrival stamps we match against anyway. Callers
      may pass an explicit `at` — tests do — but the default is
      `DateTime.utc_now/0`.

    * A released window keeps claiming for `release_grace_ms/0` after
      the release. Without it, the final words of every press — the ones
      still in the transcriber's buffer when the key came up — would fall
      outside the window and be lost. **The grace value is a chosen
      constant, not a measured one.** Nobody has instrumented the real
      finalisation lag of the transcriber on this deployment. If stage 2
      finds tails being dropped or neighbouring speech being swallowed,
      this number is the dial, and it deserves a measurement before it is
      defended.

  ## The grace also ends an EMPTY press (task 01a06638, folds in 01a06668)

  A press opens a card before anything is said (`PressCard.open/3`),
  and a press with no speech would otherwise leave that card armed and
  unclassified for the life of the row — nothing classifies it, so the
  sweeper passes over it forever. The same grace therefore governs two
  things: how long a released window still claims, AND when a press that
  claimed nothing is closed. `release/3` arms one timer for
  `release_grace_ms/0`; when it fires, and the window still exists with
  the same `released_at`, has claimed zero segments (`claims/2`) and has
  a card attached, this server hands the card to
  `PressCard.close_silent/1` in a supervised `Task`. It is NOT closed at
  the release instant, because the grace exists precisely so a trailing
  segment can still be claimed. The close runs in a Task rather than in
  `handle_info/2` because this process OWNS the ETS table: a Repo
  exception here would take every live window on the node with it.

  The timer lives in this process and dies with it, so a press released
  just before a restart is never closed by this path;
  `Platform.Meetings.CandidateSweeper`'s reaper (`reap_unclassified/2`)
  is the backstop that closes it after the sweeper's own grace.

  ## Stuck keys

  A window that is never released would otherwise claim the rest of the
  meeting: a closed tab, a dropped socket or a swallowed `keyup` all
  produce a press with no matching release. A held window therefore stops
  matching `max_hold_ms/0` after it opened. That bound applies only to
  windows still held; once released, the grace period governs.

  ## Storage

  ETS, one row per `{meeting_id, identity}`, owned by this GenServer
  purely for the table's lifecycle — reads are direct lookups from the
  caller's process and are never serialised through the server. This
  mirrors `Platform.Meetings.State`. The table dies with the owner, which
  is the correct behaviour: a press window has no meaning across a
  restart, and resurrecting stale windows would mark speech nobody
  marked.

  ## Identity

  Both sides of a match must be a known, non-blank identity, and they
  must be equal. `nil` never equals `nil` here — an unattributed segment
  arriving during an unattributed press is two strangers, not one person
  continuing. This is the same rule `Platform.Meetings.ThreadResolver`
  applies in `same_speaker?/2`, and it is why `press/3` refuses a blank
  identity outright rather than storing one that could never match.
  """

  use GenServer

  @table :meeting_press_windows

  # See the "clock problem" note above: chosen, not measured.
  @release_grace_ms 3_000

  # A press with no release stops claiming after this long.
  @max_hold_ms 120_000

  # Both press/release rewrite the window tuple from the caller's process
  # while `claim/3` runs in the classifier's; the claim count is a
  # separate `{meeting_id, identity, :claims}` key so it can be bumped
  # atomically with `:ets.update_counter/4` and never lost to a tuple
  # rewrite racing it.
  @claims :claims

  @type identity :: String.t()

  @type window :: %{
          meeting_id: binary(),
          identity: identity(),
          pressed_at: DateTime.t(),
          released_at: DateTime.t() | nil,
          card_intent_id: binary() | nil,
          target_agent_id: binary() | nil,
          target_agent_slug: String.t() | nil
        }

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Start the window-store owner. Creates the named public ETS table on
  init so reads from any process are lock-free. Booted from
  `Platform.Application`'s child list.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # Defensive: a test harness that pre-created the table, or a
        # supervisor restart that raced the old owner's exit.
        :ok
    end

    {:ok, %{}}
  end

  # ── Tunables ───────────────────────────────────────────────────────────────

  @doc """
  Milliseconds after a release during which the window still claims
  segments. Covers the transcriber's finalisation lag. Chosen, not
  measured — see the moduledoc.
  """
  @spec release_grace_ms() :: pos_integer()
  def release_grace_ms, do: @release_grace_ms

  @doc """
  Milliseconds after which a still-held window stops claiming, so a
  press whose release was lost cannot swallow the rest of the meeting.
  """
  @spec max_hold_ms() :: pos_integer()
  def max_hold_ms, do: @max_hold_ms

  # ── Write ──────────────────────────────────────────────────────────────────

  @doc """
  Open a press window for `identity` in `meeting_id`.

  Idempotent while the window is live: a repeated press (the browser
  firing `pointerdown` and `keydown` for one physical press, or a key
  repeating) returns the existing window with its original `pressed_at`
  intact. Restarting the clock on a repeat would silently discard the
  beginning of the utterance.

  A press arriving over a window that is already released or already
  past `max_hold_ms/0` opens a fresh one.

  Returns `{:error, :invalid_identity}` for a blank or non-binary
  identity rather than storing a row that could never match anything.
  """
  @spec press(binary(), identity(), DateTime.t() | nil) ::
          {:ok, window()} | {:error, :invalid_identity}
  def press(meeting_id, identity, at \\ nil)

  def press(meeting_id, identity, at) when is_binary(meeting_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        at = at || DateTime.utc_now()

        window =
          case lookup(meeting_id, known) do
            %{released_at: nil} = live ->
              if held_expired?(live, at), do: fresh_window(meeting_id, known, at), else: live

            _ ->
              fresh_window(meeting_id, known, at)
          end

        :ets.insert(@table, {{meeting_id, known}, window})
        {:ok, window}
    end
  end

  def press(_meeting_id, _identity, _at), do: {:error, :invalid_identity}

  @doc """
  Close `identity`'s press window in `meeting_id`.

  Returns `{:error, :no_window}` when there is nothing held — a release
  never fabricates a window, because "the key came up" is not evidence
  that it ever went down. A release that arrives after the window has
  already been released is likewise `{:error, :no_window}`: the second
  release must not extend the grace period the first one started.

  `released_at` is clamped to be no earlier than `pressed_at`, so a
  clock that steps backwards cannot produce a window that ends before it
  begins.
  """
  @spec release(binary(), identity(), DateTime.t() | nil) ::
          {:ok, window()} | {:error, :no_window | :invalid_identity}
  def release(meeting_id, identity, at \\ nil)

  def release(meeting_id, identity, at) when is_binary(meeting_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        at = at || DateTime.utc_now()

        case lookup(meeting_id, known) do
          %{released_at: nil} = live ->
            released_at = later_of(live.pressed_at, at)
            window = %{live | released_at: released_at}
            :ets.insert(@table, {{meeting_id, known}, window})
            # The empty-press close (see the moduledoc): fires once the
            # grace has elapsed, and is a no-op unless the window is
            # still THIS release with nothing claimed.
            Process.send_after(
              __MODULE__,
              {:grace_elapsed, meeting_id, known, released_at},
              @release_grace_ms
            )

            {:ok, window}

          _ ->
            {:error, :no_window}
        end
    end
  end

  def release(_meeting_id, _identity, _at), do: {:error, :invalid_identity}

  @doc """
  Record the queue intent whose card this press opened (task 01a03f4e
  stage 3).

  The window is the ONLY join between a press and the card it put on the
  board. `ThreadResolver` cannot make that join: it is a content matcher
  — same speaker, inside the window, then scored on topic overlap — and
  a press card is deliberately contentless, so it scores nothing and
  every arriving chunk opens a second card instead of filling the first.
  Measured, not assumed: without this link the press plus its own
  utterance produced two `meeting_candidates` rows.

  Returns `{:ok, window}`, or `{:error, :no_window}` when there is
  nothing to attach to — a press card for a window that has already gone
  is a card nothing will ever fill.
  """
  @spec attach_card(binary(), identity(), binary()) ::
          {:ok, window()} | {:error, :no_window | :invalid_identity}
  def attach_card(meeting_id, identity, intent_id)
      when is_binary(meeting_id) and is_binary(intent_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        case lookup(meeting_id, known) do
          nil ->
            {:error, :no_window}

          window ->
            window = %{window | card_intent_id: intent_id}
            :ets.insert(@table, {{meeting_id, known}, window})
            {:ok, window}
        end
    end
  end

  def attach_card(_meeting_id, _identity, _intent_id), do: {:error, :no_window}

  @doc """
  Record the agent this press is DIRECTED AT (per-agent hold-to-talk).

  With per-agent push-to-talk the human presses a specific agent's row,
  so the target is known at press time rather than inferred from the
  transcript after the fact. Storing it ON THE WINDOW — the one join
  between a press and the speech that arrives under it — is what lets the
  classifier honour that choice when the utterance is finally classified,
  instead of re-resolving a target from the words via
  `Platform.Meetings.SpokenTarget`. Without this the card would be bylined
  to the pressed agent at press time and then silently RE-bylined to the
  configured default the moment the model answered (see `reconcile/2` in
  `Platform.Meetings.Candidates`).

  `agent_id` / `agent_slug` may be nil — an untargeted press (no explicit
  agent) leaves the window's target blank and the after-the-fact
  resolution stands, which is the pre-per-agent behaviour.

  Returns `{:ok, window}`, or `{:error, :no_window}` when there is
  nothing to target.
  """
  @spec set_target(binary(), identity(), binary() | nil, String.t() | nil) ::
          {:ok, window()} | {:error, :no_window | :invalid_identity}
  def set_target(meeting_id, identity, agent_id, agent_slug)
      when is_binary(meeting_id) do
    case normalize_identity(identity) do
      nil ->
        {:error, :invalid_identity}

      known ->
        case lookup(meeting_id, known) do
          nil ->
            {:error, :no_window}

          window ->
            window = %{window | target_agent_id: agent_id, target_agent_slug: agent_slug}
            :ets.insert(@table, {{meeting_id, known}, window})
            {:ok, window}
        end
    end
  end

  def set_target(_meeting_id, _identity, _agent_id, _agent_slug), do: {:error, :no_window}

  @doc """
  Drop every window for `meeting_id`. Called when a meeting ends.
  Returns the number of rows removed.
  """
  @spec clear_meeting(binary()) :: non_neg_integer()
  def clear_meeting(meeting_id) when is_binary(meeting_id) do
    if table?() do
      :ets.select_delete(@table, [{{{meeting_id, :_, @claims}, :_}, [], [true]}])
      :ets.select_delete(@table, [{{{meeting_id, :_}, :_}, [], [true]}])
    else
      0
    end
  end

  def clear_meeting(_), do: 0

  @doc """
  How many segments `claim/3` has matched to `identity`'s CURRENT window
  in `meeting_id`. Zero when nothing has been claimed or there is no
  window; reset when `press/3` opens a fresh window (not on a repeat
  press, which is the same window).

  This is what `release/3`'s grace timer reads to decide whether the
  press was empty (task 01a06638).
  """
  @spec claims(binary(), identity()) :: non_neg_integer()
  def claims(meeting_id, identity) when is_binary(meeting_id) do
    case normalize_identity(identity) do
      nil -> 0
      known -> claims_of(meeting_id, known)
    end
  end

  def claims(_, _), do: 0

  # ── Read ───────────────────────────────────────────────────────────────────

  @doc """
  The stored window for `identity` in `meeting_id`, or `nil`.

  Raw storage read — it says nothing about whether the window would
  claim anything at a given instant. Use `claim/3` for that.
  """
  @spec get(binary(), identity()) :: window() | nil
  def get(meeting_id, identity) when is_binary(meeting_id) do
    case normalize_identity(identity) do
      nil -> nil
      known -> lookup(meeting_id, known)
    end
  end

  def get(_, _), do: nil

  @doc """
  Every stored window for `meeting_id`, in no guaranteed order.
  """
  @spec list(binary()) :: [window()]
  def list(meeting_id) when is_binary(meeting_id) do
    if table?() do
      @table
      |> :ets.select([{{{meeting_id, :_}, :"$1"}, [], [:"$1"]}])
    else
      []
    end
  end

  def list(_), do: []

  @doc """
  The windows in `meeting_id` that are claiming at instant `at` —
  whoever is holding the talk key right now, plus anyone still inside
  their release grace.

  Identity-agnostic on purpose: this answers "who is directing speech at
  the agent", which a later stage's presence indicator wants. It is NOT
  the segment-matching entry point; that is `claim/3`, which additionally
  requires the identity to match.
  """
  @spec open_windows_at(binary(), DateTime.t() | nil) :: [window()]
  def open_windows_at(meeting_id, at \\ nil) do
    at = at || DateTime.utc_now()

    meeting_id
    |> list()
    |> Enum.filter(&covers?(&1, at))
    |> Enum.sort_by(& &1.pressed_at, DateTime)
  end

  # ── Match ──────────────────────────────────────────────────────────────────

  @doc """
  Does the speech attributed to `identity`, arriving at `at`, fall inside
  a press window that `identity` themselves opened?

  Returns `{:ok, window}` when it does, `:none` when it does not. This is
  the question stage 2 asks of every incoming transcript segment.

  Two independent gates, both hard — nothing downstream can rescue a
  window that fails either:

    * **identity** — the window's holder and the segment's speaker must
      both be known and equal. A window opened by speaker A never claims
      speaker B's speech, even when B spoke squarely inside A's window.
      Two people talk at once in a meeting constantly; the whole point of
      keying on identity is that A holding the key does not route B's
      side conversation to the agent.

    * **time** — `at` must not precede `pressed_at`, and must not exceed
      the window's upper bound (release + grace when released,
      press + max hold while still held).

  Shaped as an explicit filter over the meeting's windows rather than a
  bare key lookup, matching `Platform.Meetings.ThreadResolver`'s
  `gate/3`, so both gates are visible and separately testable.
  """
  @spec claim(binary(), identity(), DateTime.t() | nil) :: {:ok, window()} | :none
  def claim(meeting_id, identity, at \\ nil)

  def claim(meeting_id, identity, at) when is_binary(meeting_id) do
    at = at || DateTime.utc_now()

    case normalize_identity(identity) do
      nil ->
        :none

      speaker ->
        meeting_id
        |> list()
        |> Enum.filter(fn window ->
          identity_match?(window, speaker) and covers?(window, at)
        end)
        |> Enum.max_by(& &1.pressed_at, DateTime, fn -> nil end)
        |> case do
          nil ->
            :none

          window ->
            # Atomic against the tuple rewrites in press/3 and release/3;
            # this is the mark the grace timer reads (task 01a06638).
            :ets.update_counter(
              @table,
              {meeting_id, speaker, @claims},
              1,
              {{meeting_id, speaker, @claims}, 0}
            )

            {:ok, window}
        end
    end
  end

  def claim(_meeting_id, _identity, _at), do: :none

  # ── The empty-press close ──────────────────────────────────────────────────

  @impl true
  def handle_info({:grace_elapsed, meeting_id, identity, released_at}, state) do
    # Proceed only if the window is still THE release that armed this
    # timer (a fresh press or a later release carries a different
    # `released_at`), nothing was claimed in the grace, and there is a
    # card to close. Everything else is a stale or irrelevant timer.
    case lookup(meeting_id, identity) do
      %{released_at: ^released_at, card_intent_id: intent_id} when is_binary(intent_id) ->
        if claims_of(meeting_id, identity) == 0 do
          # In a Task, not here: this process owns the table, and a Repo
          # exception in the close would take every live window with it.
          # The Task also inherits `$callers`, so the sandbox reaches it.
          Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
            # `close_silent/1` already degrades every failure to a log
            # line; this clause is the literal the supervised-Task audit
            # (`SupervisedTaskRepoAuditTest`) requires of every spawn site
            # for the async-test sandbox shape.
            try do
              Platform.Meetings.PressCard.close_silent(intent_id)
            rescue
              DBConnection.OwnershipError -> :ok
            end
          end)
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Gates ──────────────────────────────────────────────────────────────────

  # Both sides must be KNOWN and equal. A blank holder never matches, so
  # `nil == nil` cannot sneak an unattributed segment into an
  # unattributed window. `press/3` already refuses to store a blank
  # identity; this is the second lock on the same door.
  defp identity_match?(%{identity: holder}, speaker) do
    case normalize_identity(holder) do
      nil -> false
      known -> known == speaker
    end
  end

  defp identity_match?(_, _), do: false

  # Is `at` inside the window's live span?
  defp covers?(%{pressed_at: %DateTime{} = pressed} = window, %DateTime{} = at) do
    DateTime.compare(at, pressed) != :lt and DateTime.compare(at, upper_bound(window)) != :gt
  end

  defp covers?(_, _), do: false

  defp upper_bound(%{released_at: %DateTime{} = released}),
    do: DateTime.add(released, @release_grace_ms, :millisecond)

  defp upper_bound(%{pressed_at: pressed}),
    do: DateTime.add(pressed, @max_hold_ms, :millisecond)

  defp held_expired?(%{pressed_at: pressed}, %DateTime{} = at),
    do: DateTime.diff(at, pressed, :millisecond) > @max_hold_ms

  # ── Internals ──────────────────────────────────────────────────────────────

  # A NEW window starts with nothing claimed. A repeat press over a live
  # window never comes through here, so its count survives.
  defp fresh_window(meeting_id, identity, at) do
    :ets.delete(@table, {meeting_id, identity, @claims})
    new_window(meeting_id, identity, at)
  end

  defp claims_of(meeting_id, identity) do
    if table?() do
      case :ets.lookup(@table, {meeting_id, identity, @claims}) do
        [{_key, count}] when is_integer(count) -> count
        _ -> 0
      end
    else
      0
    end
  end

  defp new_window(meeting_id, identity, at) do
    %{
      meeting_id: meeting_id,
      identity: identity,
      pressed_at: at,
      released_at: nil,
      card_intent_id: nil,
      target_agent_id: nil,
      target_agent_slug: nil
    }
  end

  defp normalize_identity(identity) when is_binary(identity) do
    case String.trim(identity) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_identity(_), do: nil

  defp later_of(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(b, a) == :lt, do: a, else: b
  end

  defp lookup(meeting_id, identity) do
    if table?() do
      case :ets.lookup(@table, {meeting_id, identity}) do
        [{_key, window}] -> window
        _ -> nil
      end
    else
      nil
    end
  end

  # Wrapped so calls during early boot (before `init/1` installed the
  # table) return benign defaults instead of crashing the caller — the
  # same guard `Platform.Meetings.State` uses.
  defp table?, do: :ets.info(@table) != :undefined
end
