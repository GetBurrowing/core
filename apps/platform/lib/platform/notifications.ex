defmodule Platform.Notifications do
  @moduledoc """
  Notification fan-out policy layer.

  Sits above `Platform.Push` (the wire layer that handles per-subscription
  encryption, VAPID, JWT, and 410 unsubscribe) and below feature-specific
  notifiers (e.g. `Platform.Meetings.MeetingNotifier`). Owns the
  recipient-set policy: filtering out the sender, short-circuiting in test
  env, spawning a single background `Task` to absorb VAPID roundtrip latency
  without multiplexing into hundreds of orphans.

  Callers are responsible for:
    * filtering `chat_participants` to `participant_type == "user"` before
      handing IDs in;
    * de-duplication (e.g. via a `notified_at` column).
  """

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Fan out a push notification payload to a set of human participants.

  `participant_ids` is a list of `chat_participants.id` values. The caller
  must pre-filter to human participants — this helper does not introspect
  participant type.

  `payload` is a map shaped like `%{title: _, body: _, url: _}` (matching
  the shape `Platform.Push.send_notification/2` expects on the wire).

  Options:
    * `:exclude_participant_id` — a single participant_id to filter out of
      the recipient set (e.g. the sender). Defaults to `nil` (no filter).

  Returns `:ok` synchronously. Push delivery runs in a single background
  `Task.start/1` so callers (LiveViews, controllers) never block on VAPID
  roundtrips.
  """
  @spec fan_out_to_humans([binary()], map(), keyword()) :: :ok
  def fan_out_to_humans(participant_ids, payload, opts \\ [])

  def fan_out_to_humans(participant_ids, %{title: _, body: _, url: _} = payload, opts)
      when is_list(participant_ids) do
    recipients = recipients(participant_ids, opts)

    # Skip in test env. The spawned Task races with Ecto sandbox teardown:
    # when a test finishes, its Repo connection owner exits, and an
    # in-flight `Repo.all(Subscription)` inside this Task raises a
    # `DBConnection.ConnectionError` — loud, and sometimes cascades into
    # failures on other tests sharing the pool. Tests don't exercise push
    # (no subscriptions, no VAPID keys), so short-circuiting here costs
    # nothing and eliminates the flake.
    if recipients != [] and Application.get_env(:platform, :env) != :test do
      # Single Task (not per-recipient) so a slow VAPID roundtrip can't
      # multiplex into hundreds of orphan Tasks.
      Task.start(fn ->
        Enum.each(recipients, fn participant_id ->
          try do
            Platform.Push.send_notification(participant_id, payload)
          rescue
            e ->
              Logger.warning(
                "[Notifications] send_notification failed for #{participant_id}: " <>
                  Exception.message(e)
              )
          end
        end)
      end)
    end

    :ok
  end

  # ── Internal (exposed for tests) ───────────────────────────────────────────

  @doc false
  @spec recipients([binary()], keyword()) :: [binary()]
  def recipients(participant_ids, opts) when is_list(participant_ids) do
    exclude = Keyword.get(opts, :exclude_participant_id)

    participant_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> then(fn ids ->
      if is_nil(exclude), do: ids, else: Enum.reject(ids, &(&1 == exclude))
    end)
  end
end
