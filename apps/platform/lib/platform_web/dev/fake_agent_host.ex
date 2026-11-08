defmodule PlatformWeb.Dev.FakeAgentHost do
  @moduledoc """
  Dev-only controls for `Platform.AgentHost.FakeHost` (`BURROW_FAKE_AGENT_HOST=1`,
  task 01a10315 stage 4), mounted at `/dev/fake-agent-host` inside the router's
  dev-only block:

    * `POST /dev/fake-agent-host/<agent_id>/complete` finishes that codex
      agent's fake device login, as if its owner approved the code on OpenAI's
      page; the fake host then reports it `running`;
    * `POST /dev/fake-agent-host/claude-login/<mode>` switches the fake Claude
      subscription login (task 01a1b365): `ok` (the default; the one good
      code signs in as `owner@example.com` on `max`), `no_subscription` or
      `timeout` (the fake host answers nothing);
    * `GET /dev/fake-agent-host/<agent_id>/login-commands` lists the NAMES of
      the Claude login commands the fake host received for that agent, oldest
      first (task 01a1b84b), as a JSON array; never their payloads.

  Answers JSON. 404 for an agent the fake host never started, 409 for a
  non-codex agent, 503 when the fake host is not running.
  """

  @behaviour Plug

  import Plug.Conn

  alias Platform.AgentHost.FakeHost

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["claude-login", mode]} = conn, _opts) do
    mode = Enum.find(FakeHost.claude_login_modes(), &(Atom.to_string(&1) == mode))

    case FakeHost.set_claude_login(mode) do
      :ok -> json(conn, 200, %{"ok" => true, "mode" => Atom.to_string(mode)})
      {:error, :unknown_mode} -> json(conn, 404, %{"error" => "unknown_mode"})
      {:error, :not_running} -> json(conn, 503, %{"error" => "fake_agent_host_not_running"})
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: [agent_id, "login-commands"]} = conn, _opts) do
    case FakeHost.login_commands(agent_id) do
      names when is_list(names) -> json(conn, 200, names)
      {:error, :not_running} -> json(conn, 503, %{"error" => "fake_agent_host_not_running"})
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: [agent_id, "complete"]} = conn, _opts) do
    case FakeHost.complete(agent_id) do
      :ok -> json(conn, 200, %{"ok" => true})
      {:error, :unknown_agent} -> json(conn, 404, %{"error" => "unknown_agent"})
      {:error, :not_device_login} -> json(conn, 409, %{"error" => "not_device_login"})
      {:error, :not_running} -> json(conn, 503, %{"error" => "fake_agent_host_not_running"})
    end
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
