defmodule Platform.Mail.Imap.WireClient do
  @moduledoc """
  `Platform.Mail.Imap.Client` spoken directly over `:gen_tcp` / `:ssl` (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 7). It replaced a client over
  Mailroom 0.7.1, which failed against a real server (GreenMail) on the first
  command after LOGIN: Mailroom keeps one `temp` slot across commands, so the
  LOGIN reply text leaked into the LIST result, and its GenServer crashed on
  the `{:tcp_closed, _}` that follows LOGOUT on every poll.

  ## What it sends

  Exactly these commands, and nothing else: `STARTTLS` (only for
  `tls: "starttls"`), `LOGIN`, `LIST "" "*"`, `EXAMINE`, `STATUS` (only when
  EXAMINE did not report UIDVALIDITY / UIDNEXT), `UID SEARCH`,
  `UID FETCH <uid> (BODY.PEEK[])` and `LOGOUT`. EXAMINE is the read-only
  select and `BODY.PEEK[]` is the non-marking form of `BODY[]`, so no command
  here can change a mailbox or set `\\Seen`.

  ## Shape

  No process. The connection is a passive socket owned by the caller (the
  poller), so the server closing it after LOGOUT produces no message and no
  crash. Every command gets a fresh tag and the response is read up to that
  tag's completion line, literals (`{n}\\r\\n` followed by n raw bytes)
  included, so no state carries from one command to the next. A tagged `NO`
  or `BAD`, a closed socket and a timeout are all `{:error, reason}`; nothing
  here raises past the `Platform.Mail.Imap.Client` boundary.

  ## TLS

  `"tls"` (and an unset `imap_tls`) is implicit TLS, default port 993;
  `"starttls"` upgrades a plain connection and fails closed if the server
  refuses; `"none"` is plaintext, default port 143. Certificates are verified
  against the OS trust store with hostname checking, as for SMTP in
  `Platform.Mail.Deliverer`.

  `connect/1` refuses a password that is not a non-empty string rather than
  sending it: a credential that did not decrypt must never reach LOGIN.
  """
  @behaviour Platform.Mail.Imap.Client

  @connect_timeout 15_000
  @recv_timeout 60_000
  @recv_chunk 1_048_576

  defmodule Conn do
    @moduledoc false
    defstruct [:transport, :socket]
  end

  # ── Client callbacks ───────────────────────────────────────────────────────

  @impl true
  def connect(%{host: host, password: password} = params)
      when is_binary(host) and host != "" and is_binary(password) and password != "" do
    tls = Map.get(params, :tls) || "tls"
    port = Map.get(params, :port) || default_port(tls)
    username = Map.get(params, :username) || ""

    guard(fn ->
      with {:ok, conn} <- open(host, port, tls) do
        case login(conn, host, tls, username, password) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, _} = error ->
            close(conn)
            error
        end
      end
    end)
  end

  def connect(%{password: _}), do: {:error, :credential_unavailable}
  def connect(_), do: {:error, :invalid_connect_params}

  @impl true
  def list_folders(%Conn{} = conn) do
    guard(fn ->
      with {:ok, untagged} <- command(conn, [~s(LIST "" "*")]) do
        {:ok,
         for({:list, name, flags} <- Enum.map(untagged, &parse_untagged/1), do: {name, flags})}
      end
    end)
  end

  @impl true
  def examine(%Conn{} = conn, folder) when is_binary(folder) do
    guard(fn ->
      with {:ok, untagged} <- command(conn, ["EXAMINE ", astring(folder)]) do
        codes = Enum.reduce(untagged, %{}, &collect_codes/2)

        case codes do
          %{uidvalidity: v, uidnext: n} -> {:ok, v, max(n - 1, 0)}
          _ -> examine_status(conn, folder)
        end
      end
    end)
  end

  @impl true
  def uids_after(%Conn{} = conn, uid) when is_integer(uid) and uid >= 0 do
    guard(fn ->
      with {:ok, untagged} <- command(conn, ["UID SEARCH UID #{uid + 1}:*"]) do
        # `n:*` always includes the highest UID even when it is below n, hence
        # the filter.
        uids =
          untagged
          |> Enum.flat_map(fn line ->
            case parse_untagged(line) do
              {:search, numbers} -> numbers
              _ -> []
            end
          end)
          |> Enum.filter(&(&1 > uid))
          |> Enum.sort()
          |> Enum.uniq()

        {:ok, uids}
      end
    end)
  end

  @impl true
  def fetch_raw(%Conn{} = conn, uid) when is_integer(uid) and uid > 0 do
    guard(fn ->
      with {:ok, untagged} <- command(conn, ["UID FETCH #{uid} (BODY.PEEK[])"]) do
        fetches = for {:fetch, items} <- Enum.map(untagged, &parse_untagged/1), do: items

        body =
          Enum.find_value(fetches, fn items ->
            if Map.get(items, "UID") in [nil, uid], do: Map.get(items, "BODY[]")
          end)

        case body do
          raw when is_binary(raw) -> {:ok, raw}
          _ -> {:error, :no_body}
        end
      end
    end)
  end

  @impl true
  def logout(%Conn{} = conn) do
    _ = guard(fn -> command(conn, ["LOGOUT"]) end)
    close(conn)
    :ok
  end

  def logout(_), do: :ok

  # ── Connection ─────────────────────────────────────────────────────────────

  defp open(host, port, "tls") do
    opts = [:binary, active: false, packet: :line] ++ tls_options(host)

    case :ssl.connect(String.to_charlist(host), port, opts, @connect_timeout) do
      {:ok, socket} -> {:ok, %Conn{transport: :ssl, socket: socket}}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  defp open(host, port, _plain_or_starttls) do
    opts = [:binary, active: false, packet: :line]

    case :gen_tcp.connect(String.to_charlist(host), port, opts, @connect_timeout) do
      {:ok, socket} -> {:ok, %Conn{transport: :gen_tcp, socket: socket}}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  defp greeting(conn) do
    with {:ok, segments} <- read_response_line(conn) do
      case segments_text(segments) do
        "* OK" <> _ -> :ok
        "* PREAUTH" <> _ -> :ok
        other -> {:error, {:greeting, String.slice(other, 0, 200)}}
      end
    end
  end

  defp maybe_starttls(%Conn{transport: :gen_tcp} = conn, host, "starttls") do
    with {:ok, _} <- command(conn, ["STARTTLS"]) do
      case :ssl.connect(conn.socket, tls_options(host), @connect_timeout) do
        {:ok, socket} -> {:ok, %Conn{transport: :ssl, socket: socket}}
        {:error, reason} -> {:error, {:starttls, reason}}
      end
    end
  end

  defp maybe_starttls(conn, _host, _tls), do: {:ok, conn}

  defp close(%Conn{transport: transport, socket: socket}) do
    _ = transport.close(socket)
    :ok
  catch
    _, _ -> :ok
  end

  defp login(conn, host, tls, username, password) do
    with :ok <- greeting(conn),
         {:ok, conn} <- maybe_starttls(conn, host, tls) do
      case command(conn, ["LOGIN ", astring(username), " ", astring(password)]) do
        {:ok, _} ->
          {:ok, conn}

        {:error, _} = error ->
          # After STARTTLS this is the TLS socket, not the one open/3 returned.
          close(conn)
          error
      end
    end
  end

  defp default_port("tls"), do: 993
  defp default_port(_), do: 143

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # ── Commands ───────────────────────────────────────────────────────────────

  # Send one command under a fresh tag and read every response line up to that
  # tag's completion. `parts` is a list of iodata and `{:literal, binary}`
  # (synchronising literals: the server's `+` is awaited before the bytes).
  # Returns the untagged lines (each a list of segments) on OK.
  defp command(conn, parts) do
    tag = "W" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- send_parts(conn, tag, [tag, " " | parts]) do
      read_until_tagged(conn, tag, [])
    end
  end

  defp send_parts(conn, tag, parts) do
    {text, rest} = Enum.split_while(parts, &(not match?({:literal, _}, &1)))

    case rest do
      [] ->
        send_bytes(conn, [text, "\r\n"])

      [{:literal, bytes} | more] ->
        with :ok <- send_bytes(conn, [text, "{", Integer.to_string(byte_size(bytes)), "}\r\n"]),
             :ok <- await_continuation(conn, tag),
             :ok <- send_bytes(conn, bytes) do
          send_parts(conn, tag, more)
        end
    end
  end

  defp await_continuation(conn, tag) do
    case read_response_line(conn) do
      {:ok, segments} ->
        text = segments_text(segments)

        cond do
          String.starts_with?(text, "+") ->
            :ok

          String.starts_with?(text, tag <> " ") ->
            case tagged_result(text, []) do
              {:ok, _} -> {:error, :no_continuation}
              error -> error
            end

          true ->
            await_continuation(conn, tag)
        end

      error ->
        error
    end
  end

  defp read_until_tagged(conn, tag, acc) do
    with {:ok, segments} <- read_response_line(conn) do
      text = segments_text(segments)

      if String.starts_with?(text, tag <> " ") do
        tagged_result(text, Enum.reverse(acc))
      else
        read_until_tagged(conn, tag, [segments | acc])
      end
    end
  end

  defp tagged_result(text, untagged) do
    [_tag, rest] = String.split(text, " ", parts: 2)

    case String.split(rest, " ", parts: 2) do
      [status | tail] ->
        detail = tail |> List.first() |> Kernel.||("") |> String.slice(0, 200)

        case String.upcase(status) do
          "OK" -> {:ok, untagged}
          "NO" -> {:error, {:no, detail}}
          "BAD" -> {:error, {:bad, detail}}
          _ -> {:error, {:unexpected, String.slice(text, 0, 200)}}
        end
    end
  end

  # ── Socket I/O ─────────────────────────────────────────────────────────────

  # One logical response: a line, and when it ends in a literal marker
  # `{n}` / `{n+}`, the n raw bytes and the continuation line, repeatedly.
  # Returns segments: binaries (CRLF stripped from the last) and
  # `{:literal, bytes}`.
  defp read_response_line(conn, acc \\ []) do
    with {:ok, line} <- recv_line(conn, []) do
      case Regex.run(~r/\{(\d+)\+?\}\r?\n\z/, line, return: :index) do
        [{start, _} | [{digits_at, digits_len}]] ->
          size = line |> binary_part(digits_at, digits_len) |> String.to_integer()

          with {:ok, bytes} <- recv_exact(conn, size) do
            read_response_line(conn, [{:literal, bytes}, binary_part(line, 0, start) | acc])
          end

        _ ->
          {:ok,
           Enum.reverse([String.trim_trailing(line, "\r\n") |> String.trim_trailing("\n") | acc])}
      end
    end
  end

  defp recv_line(%Conn{transport: transport, socket: socket} = conn, acc) do
    case transport.recv(socket, 0, @recv_timeout) do
      {:ok, data} ->
        line = [acc | data]

        if String.ends_with?(data, "\n"),
          do: {:ok, IO.iodata_to_binary(line)},
          else: recv_line(conn, line)

      {:error, reason} ->
        {:error, recv_error(reason)}
    end
  end

  defp recv_exact(_conn, 0), do: {:ok, ""}

  defp recv_exact(%Conn{transport: transport, socket: socket} = conn, size) do
    :ok = setopts(conn, packet: :raw)

    try do
      recv_chunks(transport, socket, size, [])
    after
      setopts(conn, packet: :line)
    end
  end

  defp recv_chunks(_transport, _socket, 0, acc), do: {:ok, IO.iodata_to_binary(acc)}

  defp recv_chunks(transport, socket, remaining, acc) do
    case transport.recv(socket, min(remaining, @recv_chunk), @recv_timeout) do
      {:ok, data} -> recv_chunks(transport, socket, remaining - byte_size(data), [acc | data])
      {:error, reason} -> {:error, recv_error(reason)}
    end
  end

  defp setopts(%Conn{transport: :ssl, socket: socket}, opts), do: :ssl.setopts(socket, opts)
  defp setopts(%Conn{socket: socket}, opts), do: :inet.setopts(socket, opts)

  defp send_bytes(%Conn{transport: transport, socket: socket}, data) do
    case transport.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send, reason}}
    end
  end

  defp recv_error(:closed), do: :closed
  defp recv_error(:timeout), do: :timeout
  defp recv_error(reason), do: {:recv, reason}

  # ── Parsing ────────────────────────────────────────────────────────────────

  defp segments_text(segments) do
    segments
    |> Enum.map(fn
      {:literal, _} -> ""
      text -> text
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  # Public for tests: one untagged response (as segments) → a tagged tuple, or
  # `:other` for anything this client does not use.
  def parse_untagged([first | _] = segments) when is_binary(first) do
    case tokens(segments) do
      [{:atom, "*"} | rest] -> classify(rest)
      _ -> :other
    end
  rescue
    _ -> :other
  end

  def parse_untagged(_), do: :other

  defp classify([{:atom, word} | rest] = all) do
    case {String.upcase(word), rest} do
      {"LIST", [{:list, flags}, _delimiter, name]} ->
        case string_value(name) do
          name when is_binary(name) -> {:list, name, Enum.flat_map(flags, &flag/1)}
          _ -> :other
        end

      {"SEARCH", numbers} ->
        {:search, Enum.flat_map(numbers, &number/1)}

      {"STATUS", [_name, {:list, pairs}]} ->
        {:status, pairs |> pairs() |> Map.new(fn {k, v} -> {String.upcase(k), v} end)}

      _ ->
        classify_numbered(all)
    end
  end

  defp classify(_), do: :other

  defp classify_numbered([{:atom, n}, {:atom, word}, {:list, items}]) do
    if String.upcase(word) == "FETCH" and match?([_], number({:atom, n})) do
      {:fetch, items |> pairs() |> Map.new(fn {k, v} -> fetch_item(String.upcase(k), v) end)}
    else
      :other
    end
  end

  defp classify_numbered(_), do: :other

  defp fetch_item("UID", v), do: {"UID", v |> number() |> List.first()}
  defp fetch_item(key, v), do: {key, string_value(v)}

  defp pairs([{:atom, key}, value | rest]), do: [{key, value} | pairs(rest)]
  defp pairs(_), do: []

  defp flag({:atom, f}), do: [f]
  defp flag(_), do: []

  defp number({:atom, text}) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> [n]
      _ -> []
    end
  end

  defp number(_), do: []

  defp string_value({:string, s}), do: s
  defp string_value({:atom, a}), do: if(String.upcase(a) == "NIL", do: nil, else: a)
  defp string_value(_), do: nil

  # Untagged OK response codes carried by EXAMINE: [UIDVALIDITY n], [UIDNEXT n].
  defp collect_codes(segments, acc) do
    text = segments_text(segments)

    acc
    |> put_code(text, ~r/\A\*\s+OK\s+\[UIDVALIDITY\s+(\d+)\]/i, :uidvalidity)
    |> put_code(text, ~r/\A\*\s+OK\s+\[UIDNEXT\s+(\d+)\]/i, :uidnext)
  end

  defp put_code(acc, text, regex, key) do
    case Regex.run(regex, text) do
      [_, digits] -> Map.put(acc, key, String.to_integer(digits))
      _ -> acc
    end
  end

  defp examine_status(conn, folder) do
    with {:ok, untagged} <- command(conn, ["STATUS ", astring(folder), " (UIDVALIDITY UIDNEXT)"]) do
      status =
        Enum.find_value(untagged, %{}, fn line ->
          case parse_untagged(line) do
            {:status, map} -> map
            _ -> nil
          end
        end)

      with [v] <- number(Map.get(status, "UIDVALIDITY")),
           [n] <- number(Map.get(status, "UIDNEXT")) do
        {:ok, v, max(n - 1, 0)}
      else
        _ -> {:error, {:unexpected_status, status}}
      end
    end
  end

  # Tokens: {:atom, text}, {:string, binary} (quoted or literal), {:list, [token]}.
  defp tokens(segments) do
    segments
    |> Enum.flat_map(fn
      {:literal, bytes} -> [{:string, bytes}]
      text -> lex(text)
    end)
    |> nest()
    |> elem(0)
  end

  defp lex(<<>>), do: []
  defp lex(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: lex(rest)
  defp lex(<<"(", rest::binary>>), do: [:open | lex(rest)]
  defp lex(<<")", rest::binary>>), do: [:close | lex(rest)]

  defp lex(<<"\"", rest::binary>>) do
    {string, rest} = quoted(rest, [])
    [{:string, string} | lex(rest)]
  end

  defp lex(text) do
    [atom | _] = :binary.split(text, [" ", "(", ")", "\"", "\r", "\n", "\t"])
    <<_::binary-size(byte_size(atom)), rest::binary>> = text
    [{:atom, atom} | lex(rest)]
  end

  defp quoted(<<>>, acc), do: {IO.iodata_to_binary(acc), ""}
  defp quoted(<<"\\", c, rest::binary>>, acc), do: quoted(rest, [acc, c])
  defp quoted(<<"\"", rest::binary>>, acc), do: {IO.iodata_to_binary(acc), rest}
  defp quoted(<<c, rest::binary>>, acc), do: quoted(rest, [acc, c])

  defp nest(tokens), do: nest(tokens, [])
  defp nest([], acc), do: {Enum.reverse(acc), []}
  defp nest([:close | rest], acc), do: {Enum.reverse(acc), rest}

  defp nest([:open | rest], acc) do
    {inner, rest} = nest(rest, [])
    nest(rest, [{:list, inner} | acc])
  end

  defp nest([token | rest], acc), do: nest(rest, [token | acc])

  # An astring argument: quoted when it is printable ASCII, else a literal.
  @doc false
  def astring(value) when is_binary(value) do
    if value =~ ~r/\A[\x20-\x7e]*\z/ do
      ["\"", value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\""), "\""]
    else
      {:literal, value}
    end
  end

  defp guard(fun) do
    fun.()
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
