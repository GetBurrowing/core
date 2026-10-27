defmodule PlatformWeb.ChatEnterSpaceTelemetryTest do
  @moduledoc """
  Every segment of chat's synchronous space-entry path emits one
  `[:platform_web, :chat, :enter_space, segment, :stop]` event (task 01a17bf4
  stage 1). The before-run ranks these spans to decide what leaves the first
  frame, so a segment that silently stops emitting would drop out of the
  ranking and never be considered.

  The segment list below is written out as literals ON PURPOSE, not derived
  from `PlatformWeb.ChatLive` or `PlatformWeb.ChatLive.FirstFrame`: a list read
  from the module under test agrees with whatever the module does, including
  losing a span.

  Telemetry handlers are VM-global, so other async tests' LiveViews emit into
  this handler too. Each event carries the emitting pid and only the view's own
  pid is counted.

  ## Anti-vacuity

  Measured 2026-10-27 on the task branch: deleting the span around the pins
  segment (`|> span(:pins, &PinHooks.load_for_space(&1, space.id))` back to
  `|> PinHooks.load_for_space(space.id)` in `chat_live.ex`) turns the first
  test red with `:pins` reported missing. See the stage-1 report.
  """

  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive.FirstFrame

  @segments [
    :participants,
    :rail_channels,
    :list_spaces,
    :rail_archived_channels,
    :restricted_channel_ids,
    :rail_dm_conversations,
    :presence,
    :message_window,
    :space_sheet,
    :pins,
    :canvases,
    :agents_sheet,
    :channel_sections,
    :sidebar_sections,
    :chat_list_data
  ]

  setup do
    test_pid = self()
    handler = "chat-enter-space-telemetry-#{System.unique_integer([:positive])}"
    events = for s <- @segments, do: [:platform_web, :chat, :enter_space, s, :stop]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn [_, _, _, segment, :stop], measurements, metadata, _ ->
          send(test_pid, {:enter_space_stop, self(), segment, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp authed(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "enter-space-telemetry-#{n}@example.com",
        name: "Enter Space #{n}",
        oidc_sub: "oidc-enter-space-telemetry-#{n}",
        avatar_url: nil
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_channel do
    slug = "enter-space-telemetry-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{
        name: "Enter space telemetry",
        slug: slug,
        kind: "channel",
        org_id: Tenancy.get_org_by_slug!("acme").id
      })

    space
  end

  # Every further stop event the given pid has emitted, as [{segment, m, meta}].
  defp drain(pid, acc \\ []) do
    receive do
      {:enter_space_stop, ^pid, segment, m, meta} -> drain(pid, [{segment, m, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "entering a space emits exactly one stop event per enter_space segment", %{conn: conn} do
    {conn, _user} = authed(conn)
    space = create_channel()

    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    pid = view.pid

    # Wait for each segment from the view process (missing ones collected
    # rather than failing on the first, so the message names all of them).
    {seen, missing} =
      Enum.reduce(@segments, {[], []}, fn segment, {seen, missing} ->
        receive do
          {:enter_space_stop, ^pid, ^segment, m, meta} -> {[{segment, m, meta} | seen], missing}
        after
          1_000 -> {seen, [segment | missing]}
        end
      end)

    assert Enum.reverse(missing) == [],
           "no stop event for #{inspect(Enum.reverse(missing))} from the chat view"

    # A render round-trip, then nothing more: exactly one stop per segment.
    _ = render(view)
    extra = drain(pid)

    assert extra == [],
           "segments stopped more than once: #{inspect(Enum.map(extra, &elem(&1, 0)))}"

    for {segment, m, meta} <- seen do
      assert is_integer(m.duration) and m.duration >= 0
      # Names only: nothing about the space, the user or the content.
      assert Map.delete(meta, :telemetry_span_context) == %{segment: segment}
    end
  end

  test "the first-frame knobs default to today's behaviour" do
    assert FirstFrame.initial_message_count() == 50
    assert FirstFrame.deferred_side_state() == []
  end
end
