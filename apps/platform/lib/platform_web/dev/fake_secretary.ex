defmodule PlatformWeb.Dev.FakeSecretary do
  @moduledoc """
  Dev-only controls for the secretary's model path (task 01a1b721 stage 2),
  mounted at `/dev/fake-secretary` inside the router's dev-only block, and
  answering only when the dev stand-in agent host runs
  (`BURROW_FAKE_AGENT_HOST=1`; otherwise 404):

    * `POST /dev/fake-secretary/mode/<ok|slow|not_logged_in>` switches the
      fake host's `agent.oneshot` (`Platform.AgentHost.FakeHost`): `ok`
      answers at once from the prompt's INPUTS block, `slow` after 20 s,
      `not_logged_in` refuses;
    * `POST /dev/fake-secretary/agent-login/api_key` saves a correctly shaped
      FAKE Anthropic API key on the dev Burrow
      (`Platform.Agents.NativeLogin.put_api_key/3`, as the Burrow's owner),
      so the core gate and the fake host refuse with `api_key_login`, as the
      real host would; `POST /dev/fake-secretary/agent-login/subscription`
      removes it.

  Stage 3 adds, for the dev-login user unless `?email=` names another:

    * `POST /dev/fake-secretary/seed/<base|arrive|quiet|sponsor|plan_review|privacy|clear>`
      — fixtures through real context paths (`PlatformWeb.Dev.FakeSecretarySeeds`);
    * `POST /dev/fake-secretary/ceiling/<n|default>` — the person's
      `daily_token_ceiling` through `Platform.Secretary.Settings.put/2`;
    * `GET /dev/fake-secretary/inspect?email=E` — that person's input refs,
      their rendered prompt and their last batch's outcome. Dev only: it
      refuses (404) unless the fake agent host is enabled, like every route
      here.

  Answers JSON.
  """

  @behaviour Plug

  import Plug.Conn

  alias Platform.Accounts
  alias Platform.AgentHost.FakeHost
  alias Platform.Agents.{Burrow, NativeAgents, NativeLogin}
  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Secretary.{Context, Inputs, Policy, Prompt, Settings, Store}
  alias PlatformWeb.Dev.FakeSecretarySeeds

  # Shaped like an Anthropic key (NativeLogin.api_key_shape/1); never valid.
  @fake_key "sk-ant-api03-fake-dev-only-" <> String.duplicate("0", 40)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:platform, :fake_agent_host, false),
      do: route(conn),
      else: json(conn, 404, %{"error" => "fake_agent_host_not_enabled"})
  end

  defp route(%Plug.Conn{method: "POST", path_info: ["mode", mode]} = conn) do
    mode = Enum.find(FakeHost.oneshot_modes(), &(Atom.to_string(&1) == mode))

    case FakeHost.set_oneshot_mode(mode) do
      :ok -> json(conn, 200, %{"ok" => true, "mode" => Atom.to_string(mode)})
      {:error, :unknown_mode} -> json(conn, 404, %{"error" => "unknown_mode"})
      {:error, :not_running} -> json(conn, 503, %{"error" => "fake_agent_host_not_running"})
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: ["agent-login", login]} = conn)
       when login in ["api_key", "subscription"] do
    with agent when not is_nil(agent) <- Burrow.get(),
         %{owner_user_id: owner} when is_binary(owner) <- NativeAgents.get_managed_runtime(agent),
         :ok <- set_login(login, owner, agent) do
      json(conn, 200, %{"ok" => true, "login" => login})
    else
      nil -> json(conn, 404, %{"error" => "no_burrow"})
      {:error, reason} -> json(conn, 422, %{"error" => inspect(reason)})
      _ -> json(conn, 404, %{"error" => "no_burrow_owner"})
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: ["seed", seed]} = conn) do
    with {:ok, user} <- person(conn),
         {:ok, summary} <- FakeSecretarySeeds.run(seed, user) do
      json(conn, 200, %{"ok" => true, "seed" => seed, "result" => summary})
    else
      {:error, :unknown_seed} -> json(conn, 404, %{"error" => "unknown_seed"})
      {:error, reason} -> json(conn, 404, %{"error" => to_string(reason)})
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: ["ceiling", value]} = conn) do
    ceiling =
      case Integer.parse(value) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    with {:ok, user} <- person(conn),
         {:ok, settings} <- Settings.put(user.id, %{"daily_token_ceiling" => ceiling}) do
      json(conn, 200, %{"ok" => true, "daily_token_ceiling" => settings["daily_token_ceiling"]})
    else
      {:error, reason} -> json(conn, 422, %{"error" => inspect(reason)})
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["inspect"]} = conn) do
    case person(conn) do
      {:ok, user} -> json(conn, 200, inspect_person(user))
      {:error, reason} -> json(conn, 404, %{"error" => to_string(reason)})
    end
  end

  defp route(conn), do: json(conn, 404, %{"error" => "not_found"})

  defp person(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["email"] do
      nil ->
        {:ok, FakeSecretarySeeds.dev_user()}

      email ->
        case Enum.find(Accounts.list_users(), &(&1.email == email)) do
          nil -> {:error, :no_such_person}
          user -> {:ok, user}
        end
    end
  end

  defp inspect_person(user) do
    payload = Policy.for_user(user.id).payload
    inputs = Inputs.gather(user, DateTime.add(DateTime.utc_now(), -24 * 3600, :second))

    last =
      case Store.list_batches(user.id, limit: 1) do
        [batch] ->
          %{
            "status" => batch.status,
            "reserved_tokens" => batch.reserved_tokens,
            "actual_tokens" => batch.actual_tokens,
            "dispatched_at" => batch.dispatched_at
          }

        [] ->
          nil
      end

    %{
      "email" => user.email,
      "input_refs" =>
        Enum.map(inputs, &%{"ref_type" => &1.ref_type, "ref_id" => &1.ref_id, "kind" => &1.kind}),
      "prompt" =>
        Prompt.build(
          user,
          inputs,
          Context.for_user(user),
          Map.merge(SecretaryPolicy.control(), payload)
        ),
      "last_batch" => last
    }
  end

  defp set_login("api_key", owner, agent), do: NativeLogin.put_api_key(owner, agent, @fake_key)
  defp set_login("subscription", owner, agent), do: NativeLogin.remove_api_key(owner, agent)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
