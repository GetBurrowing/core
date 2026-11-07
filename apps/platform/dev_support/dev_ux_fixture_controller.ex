defmodule PlatformWeb.DevUxFixtureController do
  @moduledoc """
  Dev-only HTTP face of `PlatformWeb.UxDevFixture` (task 01a1af00 stage 4).
  Compiled in dev and test only (`dev_support/`), routed only when
  `Mix.env() == :dev`. Every action acts for the dev-login session user, who
  is the recipient. Visit `/dev/login` first.

    * `POST /dev/ux_fixture/seed`: build the rig (see the fixture moduledoc);
    * `POST /dev/ux_fixture/fire` (`kind=cron` for the weekly cron path):
      fire `ux.friction_watch` through the Router;
    * `GET /dev/ux_fixture/status`: findings, Inbox rows, digest messages and
      the signals the model was sent.
  """
  use PlatformWeb, :controller

  alias PlatformWeb.UxDevFixture

  def seed(conn, _params), do: with_user(conn, &UxDevFixture.seed/1)

  def fire(conn, params), do: with_user(conn, &UxDevFixture.fire(&1, params["kind"]))

  def status(conn, _params), do: with_user(conn, &{:ok, UxDevFixture.status(&1)})

  defp with_user(conn, fun) do
    case get_session(conn, :current_user_id) do
      nil ->
        send_resp(conn, 401, "no current_user_id in session; visit /dev/login first")

      user_id ->
        case fun.(user_id) do
          {:ok, body} -> json(conn, body)
          {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end
end
