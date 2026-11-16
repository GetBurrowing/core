defmodule Platform.SignInAdmin.EmailLoginCodeBootTest do
  @moduledoc """
  Task 01a1e65e stage 2: the once-per-install boot step that turns on
  pocket-id's email login code. Every request goes to the `Req.Test` stub
  named `Platform.SignInAdmin.PocketId` (`config/test.exs`); the marker lives
  in `install_boot_markers` inside the DataCase sandbox.
  """
  # async: false: swaps :platform app env and the global Logger level.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Install.BootMarkers
  alias Platform.Role
  alias Platform.SignInAdmin.EmailLoginCodeBoot
  alias Platform.SignInAdmin.PocketId

  @key "pid-boot-test-key-0123456789-SECRET"
  @flag "emailOneTimeAccessAsUnauthenticatedEnabled"
  @summary ~r/^pocket_id\.email_login_code result=(skipped|present|enabled|failed reason=[a-z_0-9]+)$/

  setup do
    keys = [
      :sign_in_admin_enabled,
      :sign_in_admin_url,
      :sign_in_admin_api_key,
      :pocket_id_req_options
    ]

    saved = for key <- keys, do: {key, Application.fetch_env(:platform, key)}
    previous_level = Logger.level()

    on_exit(fn ->
      Logger.configure(level: previous_level)

      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Logger.configure(level: :info)
    Application.put_env(:platform, :sign_in_admin_enabled, true)
    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
    Application.put_env(:platform, :sign_in_admin_api_key, @key)
    :ok
  end

  # -- stub helpers ---------------------------------------------------------

  defp all_config(flag) do
    [
      %{"key" => "appName", "type" => "string", "value" => "Legacy Pie Auth"},
      %{"key" => "sessionDuration", "type" => "number", "value" => "120"},
      %{"key" => @flag, "type" => "bool", "value" => flag}
    ]
  end

  # Records every request, then answers with `responder`. Assertions stay in
  # the test: an assert raised inside the plug would read as a transport error.
  defp stub(responder) do
    pid = self()

    Req.Test.stub(PocketId, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(pid, {:pocket_id_req, %{method: conn.method, path: conn.request_path}})
      responder.(conn, body)
    end)
  end

  # A pocket-id whose /all serves `flag`, and whose PUT saves what it is sent.
  defp pocket_id(flag) do
    stub(fn conn, body ->
      case conn.method do
        "GET" ->
          json(conn, 200, all_config(flag))

        "PUT" ->
          json(conn, 200, Enum.map(body, fn {k, v} -> %{"key" => k, "value" => v} end))
      end
    end)
  end

  defp json(conn, status, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp requests(acc \\ []) do
    receive do
      {:pocket_id_req, req} -> requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count(reqs, method), do: Enum.count(reqs, &(&1.method == method))

  defp summary_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "pocket_id.email_login_code"))
  end

  # The summary line without the logger's time/level prefix.
  defp summary_message(line) do
    [_, message] = Regex.run(~r/(pocket_id\.email_login_code.*)$/, line)
    String.trim(message)
  end

  defp boot(opts \\ [delay_ms: 0]) do
    with_log(fn -> EmailLoginCodeBoot.run_at_boot(opts) end)
  end

  # -- run/1 ----------------------------------------------------------------

  describe "run/1" do
    test "(a) retries a transport error twice, then succeeds" do
      {:ok, gets} = Agent.start_link(fn -> 0 end)

      stub(fn conn, body ->
        case conn.method do
          "GET" ->
            case Agent.get_and_update(gets, &{&1, &1 + 1}) do
              n when n < 2 -> Req.Test.transport_error(conn, :econnrefused)
              _ -> json(conn, 200, all_config("false"))
            end

          "PUT" ->
            json(conn, 200, Enum.map(body, fn {k, v} -> %{"key" => k, "value" => v} end))
        end
      end)

      assert EmailLoginCodeBoot.run(delay_ms: 0) == {:ok, :enabled}

      reqs = requests()
      assert count(reqs, "GET") == 3
      assert count(reqs, "PUT") == 1
    end

    test "a 5xx is retried until attempts run out" do
      stub(fn conn, _ -> json(conn, 503, %{"error" => "starting"}) end)

      assert EmailLoginCodeBoot.run(attempts: 4, delay_ms: 0) == {:error, {:http, 503}}
      assert count(requests(), "GET") == 4
    end

    test "(b) a 401 is answered once, never retried" do
      stub(fn conn, _ -> json(conn, 401, %{"error" => "unauthorized"}) end)

      assert EmailLoginCodeBoot.run(delay_ms: 0) == {:error, {:http, 401}}
      assert count(requests(), "GET") == 1
    end

    test "a locked config is answered once, never retried" do
      stub(fn conn, _ ->
        json(conn, 200, [%{"key" => "smtpPassword", "value" => "XXXXXXXXXX"}])
      end)

      assert EmailLoginCodeBoot.run(delay_ms: 0) == {:error, :config_locked}
      reqs = requests()
      assert count(reqs, "GET") == 1
      assert count(reqs, "PUT") == 0
    end
  end

  # -- run_at_boot/1 ----------------------------------------------------------

  describe "run_at_boot/1" do
    test "(c) an always-failing pocket-id logs exactly one warning line, whatever the attempts" do
      stub(fn conn, _ -> json(conn, 503, %{"error" => "down"}) end)

      {result, log} = boot(attempts: 3, delay_ms: 0)

      assert result == :ok
      assert count(requests(), "GET") == 3

      assert [line] = summary_lines(log)
      assert line =~ "[warning]"
      assert summary_message(line) == "pocket_id.email_login_code result=failed reason=http_503"
      assert summary_message(line) =~ @summary
      refute log =~ @key
    end

    test "(d) flag already on: one info line result=present, zero PUTs" do
      pocket_id("true")

      {result, log} = boot()

      assert result == :ok
      reqs = requests()
      assert count(reqs, "GET") == 1
      assert count(reqs, "PUT") == 0

      assert [line] = summary_lines(log)
      assert line =~ "[info]"
      assert summary_message(line) == "pocket_id.email_login_code result=present"
    end

    test "(e) a raise anywhere in the step still returns :ok, with one failed line" do
      # A non-list request option makes `Keyword.merge/2` raise in
      # `PocketId.request/3` before its own try, so the raise reaches this
      # module rather than being turned into :transport.
      Application.put_env(:platform, :pocket_id_req_options, :not_a_keyword_list)

      {result, log} = boot()

      assert result == :ok
      assert [line] = summary_lines(log)
      assert summary_message(line) == "pocket_id.email_login_code result=failed reason=exception"
      refute BootMarkers.set?(:pocket_id_email_login_code)
    end

    test "(e2) a stub that raises is a transport failure, and returns :ok" do
      stub(fn _conn, _ -> raise "pocket-id stub exploded" end)

      {result, log} = boot(attempts: 1, delay_ms: 0)

      assert result == :ok

      assert [line] = summary_lines(log)
      assert summary_message(line) == "pocket_id.email_login_code result=failed reason=transport"
    end

    test "(f) sign-in admin off: zero requests, no marker, :ok" do
      Application.put_env(:platform, :sign_in_admin_enabled, false)
      pocket_id("false")

      {result, log} = boot()

      assert result == :ok
      assert requests() == []
      assert summary_lines(log) == []
      refute BootMarkers.set?(:pocket_id_email_login_code)
    end

    test "(h) marker set and the admin turned the flag off: zero requests, result=skipped" do
      assert BootMarkers.put(:pocket_id_email_login_code) == :ok
      # The admin turned email login codes off after the first boot enabled them.
      pocket_id("false")

      {result, log} = boot()

      assert result == :ok
      reqs = requests()
      assert count(reqs, "GET") == 0
      assert count(reqs, "PUT") == 0

      assert [line] = summary_lines(log)
      assert line =~ "[info]"
      assert summary_message(line) == "pocket_id.email_login_code result=skipped"

      # The flag stays off: nothing asked pocket-id to change it.
      assert PocketId.email_login_code_enabled?() == false
    end

    test "(i) an error writes no marker, so the next boot retries" do
      stub(fn conn, _ -> json(conn, 401, %{"error" => "unauthorized"}) end)

      {:ok, _log} = boot()
      refute BootMarkers.set?(:pocket_id_email_login_code)
      assert count(requests(), "GET") == 1

      pocket_id("false")
      {:ok, log} = boot()

      reqs = requests()
      assert count(reqs, "GET") == 1
      assert count(reqs, "PUT") == 1
      assert [line] = summary_lines(log)
      assert summary_message(line) == "pocket_id.email_login_code result=enabled"
      assert BootMarkers.set?(:pocket_id_email_login_code)
    end

    test "(j) a success writes the marker, and the next boot sends nothing" do
      refute BootMarkers.set?(:pocket_id_email_login_code)
      pocket_id("false")

      {:ok, log} = boot()

      assert [line] = summary_lines(log)
      assert summary_message(line) == "pocket_id.email_login_code result=enabled"
      assert BootMarkers.set?(:pocket_id_email_login_code)
      assert count(requests(), "PUT") == 1

      {:ok, log} = boot()
      assert requests() == []
      assert [line] = summary_lines(log)
      assert summary_message(line) == "pocket_id.email_login_code result=skipped"
    end

    test "result=present also writes the marker" do
      pocket_id("true")
      {:ok, _log} = boot()
      assert BootMarkers.set?(:pocket_id_email_login_code)
    end

    test "BootMarkers.put/1 is idempotent" do
      assert BootMarkers.put(:pocket_id_email_login_code) == :ok
      assert BootMarkers.put(:pocket_id_email_login_code) == :ok
      assert BootMarkers.set?(:pocket_id_email_login_code)
    end
  end

  # -- the application child ------------------------------------------------

  describe "(g) the application child" do
    defp ids(role, flag),
      do: Enum.map(Platform.Application.children(role, flag), &Role.child_id/1)

    test "starts under :full by default, never under :web, and not when flagged off" do
      defaults = fn _app, _key, default -> default end
      all_on = fn _app, _key, _default -> true end
      off = fn _app, key, default -> key != :start_pocket_id_email_login_code and default end

      assert :pocket_id_email_login_code in ids(:full, defaults)
      assert :pocket_id_email_login_code in ids(:full, all_on)
      refute :pocket_id_email_login_code in ids(:web, all_on)
      refute :pocket_id_email_login_code in ids(:full, off)
      assert :pocket_id_email_login_code in Role.background_ids()
    end
  end
end
