defmodule PlatformWeb.FeedbackBrokerUsageTest do
  @moduledoc """
  Task 01a1b678 stage 2: the broker host's receiver for anonymous usage
  counts, `POST /api/feedback-broker/v1/usage`, behind `FeedbackBrokerGate`.

  async: false: flips broker mode (via `broker_node!/1`, restored on exit).
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.FeedbackBrokerFixtures

  alias Platform.Repo
  alias Platform.Sharing.UsageCount

  @path "/api/feedback-broker/v1/usage"

  setup do
    broker_node!(self())
    :ok
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        "sharing_install_id" => "7d4f0a52-2b8e-4c6e-9a51-3f0f6f1c2d11",
        "window" => %{"start" => 1_762_531_200, "seconds" => 3600},
        "counts" => %{"message.posted" => 41, "meeting.started" => 2}
      },
      overrides
    )
  end

  defp stored do
    UsageCount
    |> Repo.all()
    |> Map.new(&{&1.event, &1.count})
  end

  test "404s when broker mode is off, and stores nothing", %{conn: conn} do
    Application.put_env(:platform, :feedback_broker_server, enabled: false)
    assert json_response(post_json(conn, body()), 404) == %{"error" => "not_found"}
    assert stored() == %{}
  end

  test "stores one row per pinned event, keyed by the sharing install id", %{conn: conn} do
    assert json_response(post_json(conn, body()), 202) == %{"accepted" => 2}
    assert stored() == %{"message.posted" => 41, "meeting.started" => 2}

    [row | _] = Repo.all(UsageCount)
    assert row.sharing_install_id == "7d4f0a52-2b8e-4c6e-9a51-3f0f6f1c2d11"
    assert DateTime.to_unix(row.window_start) == 1_762_531_200
    assert row.window_seconds == 3600
  end

  test "a resend of the same window replaces its own counts, never doubles them", %{conn: conn} do
    assert json_response(post_json(conn, body()), 202)

    assert json_response(
             post_json(build_conn(), body(%{"counts" => %{"message.posted" => 45}})),
             202
           )

    assert stored() == %{"message.posted" => 45, "meeting.started" => 2}
    assert Repo.aggregate(UsageCount, :count) == 2
  end

  test "an unpinned name refuses the whole batch", %{conn: conn} do
    bad = body(%{"counts" => %{"message.posted" => 1, "Sentinel Personname" => 1}})
    assert json_response(post_json(conn, bad), 422) == %{"error" => "invalid_usage"}
    assert stored() == %{}
  end

  test "a non-integer or negative value refuses the whole batch", %{conn: conn} do
    for counts <- [
          %{"message.posted" => "sentinel@example.test"},
          %{"message.posted" => -1},
          %{"message.posted" => 1.5}
        ] do
      assert json_response(post_json(build_conn(), body(%{"counts" => counts})), 422) ==
               %{"error" => "invalid_usage"}
    end

    _ = conn
    assert stored() == %{}
  end

  test "an extra top-level key or a malformed install id is refused", %{conn: conn} do
    assert json_response(post_json(conn, body(%{"who" => "Sentinel Personname"})), 422)

    assert json_response(
             post_json(build_conn(), body(%{"sharing_install_id" => "Sentinel Personname"})),
             422
           )

    assert json_response(
             post_json(build_conn(), body(%{"window" => %{"start" => "yesterday"}})),
             422
           )

    assert stored() == %{}
  end
end
