defmodule Platform.Mail.ScriptedImapServer do
  @moduledoc """
  A real IMAP socket for the Email module's tests (task 01a0cf21 stage 7):
  listens on 127.0.0.1, accepts any number of connections, and answers the
  commands `Platform.Mail.Imap.WireClient` sends with the BYTES GreenMail
  2.1.14 sent for them — recorded against `greenmail/standalone:2.1.14` on
  2026-09-23 (greeting, `LOGIN completed.`, `LIST () "." "Name"`, the EXAMINE
  untagged set, `* SEARCH` with and without hits, a `BODY[] {n}` literal,
  `* BYE` + close on LOGOUT, `BAD Invalid command.`).

  It exists because the in-memory `Platform.Mail.Imap.FakeClient` cannot
  catch a protocol-level defect: stage 6's review found the Mailroom-based
  client failing on GreenMail's very first LIST, which every FakeClient test
  had passed.

  Mailbox state is an Agent: folders in creation order, each with a
  UIDVALIDITY and messages `{uid, raw, flags}`. A non-PEEK `BODY[]` fetch
  sets `\\Seen`, as a real server does, so a test can tell. Every command
  line received is recorded (`commands/1`); literals sent by the client
  (`{n}` + bytes) are answered `+ OK` and recorded inline.

      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      uid = ScriptedImapServer.deliver(server, "Support", raw)
      ScriptedImapServer.port(server)
  """

  @greeting "* OK IMAP4rev1 Server GreenMail v2.1.14 ready\r\n"
  @flags "* FLAGS (\\Answered \\Deleted \\Draft \\Flagged \\Seen)\r\n"
  @permanent "* OK [PERMANENTFLAGS (\\Answered \\Deleted \\Draft \\Flagged \\Seen \\*)]\r\n"

  defstruct [:agent, :listen, :port]

  @doc "Start a server; stopped by `on_exit`."
  def start!(opts \\ []) do
    {:ok, agent} =
      Agent.start(fn ->
        %{
          folders: [],
          commands: [],
          next_validity: Keyword.get(opts, :first_uidvalidity, 1_790_207_343),
          omit_uidnext: Keyword.get(opts, :omit_uidnext, false)
        }
      end)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    server = %__MODULE__{agent: agent, listen: listen, port: port}
    acceptor = spawn(fn -> accept_loop(server) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    put_folder(server, "INBOX")
    server
  end

  def port(%__MODULE__{port: port}), do: port

  def put_folder(%__MODULE__{agent: agent}, name) do
    Agent.update(agent, fn state ->
      if List.keymember?(state.folders, name, 0) do
        state
      else
        folder = %{uidvalidity: state.next_validity, next_uid: 1, messages: []}

        %{
          state
          | folders: state.folders ++ [{name, folder}],
            next_validity: state.next_validity + 1
        }
      end
    end)
  end

  @doc "Append `raw` to `folder`; returns its UID."
  def deliver(%__MODULE__{agent: agent}, name, raw) do
    Agent.get_and_update(agent, fn state ->
      {^name, folder} = List.keyfind(state.folders, name, 0)
      uid = folder.next_uid

      folder = %{
        folder
        | next_uid: uid + 1,
          messages: folder.messages ++ [{uid, raw, ["\\Recent"]}]
      }

      {uid, %{state | folders: List.keyreplace(state.folders, name, 0, {name, folder})}}
    end)
  end

  @doc "Flags currently set on `uid` in `folder`."
  def flags(%__MODULE__{agent: agent}, name, uid) do
    Agent.get(agent, fn state ->
      {^name, folder} = List.keyfind(state.folders, name, 0)
      {^uid, _raw, flags} = List.keyfind(folder.messages, uid, 0)
      flags
    end)
  end

  @doc "Every command line received, oldest first, tag stripped."
  def commands(%__MODULE__{agent: agent}),
    do: Agent.get(agent, &Enum.reverse(&1.commands))

  # ── Server ───────────────────────────────────────────────────────────────

  defp accept_loop(%__MODULE__{listen: listen} = server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> receive(do: (:go -> session(server, socket))) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(server)

      {:error, _} ->
        :ok
    end
  end

  defp session(server, socket) do
    :ok = :gen_tcp.send(socket, @greeting)
    loop(server, socket, nil)
  end

  defp loop(server, socket, selected) do
    case read_command(socket) do
      {:ok, line} ->
        [tag | rest] = String.split(line, " ", parts: 2)
        command = List.first(rest) || ""
        Agent.update(server.agent, &%{&1 | commands: [command | &1.commands]})

        case respond(server, tag, command, selected) do
          {:reply, bytes, selected} ->
            :ok = :gen_tcp.send(socket, bytes)
            loop(server, socket, selected)

          {:close, bytes} ->
            :gen_tcp.send(socket, bytes)
            :gen_tcp.close(socket)
        end

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  # One command line, with any client literals (`{n}` / `{n+}`) inlined.
  defp read_command(socket, acc \\ "") do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 30_000) do
      case Regex.run(~r/\{(\d+)(\+?)\}\r\n\z/, line) do
        [marker, digits, plus] ->
          if plus == "", do: :gen_tcp.send(socket, "+ OK\r\n")
          :ok = :inet.setopts(socket, packet: :raw)
          size = String.to_integer(digits)
          {:ok, bytes} = if size == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, size, 30_000)
          :ok = :inet.setopts(socket, packet: :line)
          prefix = binary_part(line, 0, byte_size(line) - byte_size(marker))
          read_command(socket, acc <> prefix <> "{literal:" <> bytes <> "}")

        _ ->
          {:ok, String.trim_trailing(acc <> line, "\r\n")}
      end
    end
  end

  defp respond(server, tag, command, selected) do
    [verb | _] = String.split(command, " ", parts: 2)

    case {String.upcase(verb), command} do
      {"LOGIN", _} ->
        {:reply, "#{tag} OK LOGIN completed.\r\n", selected}

      {"CAPABILITY", _} ->
        {:reply,
         "* CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS SORT IDLE MOVE SASL-IR AUTH=XOAUTH2 QUOTA\r\n" <>
           "#{tag} OK CAPABILITY completed.\r\n", selected}

      {"LIST", _} ->
        lines =
          for {name, _} <- folders(server),
              do: "* LIST () \".\" \"#{escape(name)}\"\r\n"

        {:reply, [lines, "#{tag} OK LIST completed.\r\n"], selected}

      {"EXAMINE", "EXAMINE " <> arg} ->
        examine(server, tag, unquote_arg(arg), selected)

      {"STATUS", "STATUS " <> arg} ->
        [name_part, _items] = Regex.run(~r/\A(".*"|\S+) (.*)\z/, arg, capture: :all_but_first)
        name = unquote_arg(name_part)

        case folder(server, name) do
          nil ->
            {:reply, "#{tag} NO STATUS failed. No such mailbox.\r\n", selected}

          f ->
            {:reply,
             "* STATUS \"#{escape(name)}\" (UIDNEXT #{f.next_uid} UIDVALIDITY #{f.uidvalidity})\r\n" <>
               "#{tag} OK STATUS completed.\r\n", selected}
        end

      {"UID", "UID " <> sub} ->
        uid_command(server, tag, sub, selected)

      {"LOGOUT", _} ->
        {:close, "* BYE IMAP4rev1 Server logging out\r\n#{tag} OK LOGOUT completed.\r\n"}

      _ ->
        {:reply, "#{tag} BAD Invalid command.\r\n", selected}
    end
  end

  defp examine(server, tag, name, selected) do
    case folder(server, name) do
      nil ->
        {:reply, "#{tag} NO EXAMINE failed. No such mailbox.\r\n", selected}

      f ->
        count = length(f.messages)
        unseen = Enum.find_index(f.messages, fn {_, _, flags} -> "\\Seen" not in flags end)

        unseen_line =
          if unseen,
            do: "* OK [UNSEEN #{unseen + 1}] Message #{unseen + 1} is the first unseen\r\n",
            else: "* OK No messages unseen\r\n"

        uidnext =
          if Agent.get(server.agent, & &1.omit_uidnext),
            do: "",
            else: "* OK [UIDNEXT #{f.next_uid}]\r\n"

        {:reply,
         [
           @flags,
           "* #{count} EXISTS\r\n",
           "* #{count} RECENT\r\n",
           "* OK [UIDVALIDITY #{f.uidvalidity}]\r\n",
           uidnext,
           unseen_line,
           @permanent,
           "#{tag} OK [READ-ONLY] EXAMINE completed.\r\n"
         ], name}
    end
  end

  defp uid_command(server, tag, sub, selected) do
    f = selected && folder(server, selected)

    cond do
      is_nil(f) ->
        {:reply, "#{tag} BAD Invalid command.\r\n", selected}

      match = Regex.run(~r/\ASEARCH UID (\d+):\*\z/i, sub) ->
        [_, from] = match
        from = String.to_integer(from)
        # GreenMail 2.1.14 answers `UID n:*` with the UIDs >= n only (recorded:
        # `UID SEARCH UID 5:*` on a folder whose highest UID is 1 gave `* SEARCH`).
        uids = for {uid, _, _} <- f.messages, uid >= from, do: uid
        line = if uids == [], do: "* SEARCH\r\n", else: "* SEARCH #{Enum.join(uids, " ")}\r\n"
        {:reply, [line, "#{tag} OK SEARCH completed.\r\n"], selected}

      match = Regex.run(~r/\AFETCH (\d+) \((BODY\.PEEK\[\]|BODY\[\]|FLAGS)\)\z/i, sub) ->
        [_, uid, item] = match
        fetch(server, tag, selected, f, String.to_integer(uid), String.upcase(item))

      true ->
        {:reply, "#{tag} BAD Invalid command.\r\n", selected}
    end
  end

  defp fetch(server, tag, selected, f, uid, item) do
    case Enum.find_index(f.messages, fn {u, _, _} -> u == uid end) do
      nil ->
        {:reply, "#{tag} OK FETCH completed.\r\n", selected}

      index ->
        {^uid, raw, flags} = Enum.at(f.messages, index)
        seq = index + 1

        line =
          case item do
            "FLAGS" ->
              "* #{seq} FETCH (FLAGS (#{Enum.join(flags, " ")}) UID #{uid})\r\n"

            body_item ->
              if body_item == "BODY[]", do: mark_seen(server, selected, uid)
              ["* #{seq} FETCH (UID #{uid} BODY[] {#{byte_size(raw)}}\r\n", raw, ")\r\n"]
          end

        {:reply, [line, "#{tag} OK FETCH completed.\r\n"], selected}
    end
  end

  defp mark_seen(server, name, uid) do
    Agent.update(server.agent, fn state ->
      {^name, folder} = List.keyfind(state.folders, name, 0)

      messages =
        Enum.map(folder.messages, fn
          {^uid, raw, flags} -> {uid, raw, Enum.uniq(flags ++ ["\\Seen"])}
          other -> other
        end)

      %{
        state
        | folders: List.keyreplace(state.folders, name, 0, {name, %{folder | messages: messages}})
      }
    end)
  end

  defp folders(server), do: Agent.get(server.agent, & &1.folders)

  defp folder(server, name) do
    case List.keyfind(folders(server), name, 0) do
      {_, f} -> f
      nil -> nil
    end
  end

  defp escape(name), do: name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp unquote_arg("{literal:" <> rest), do: String.trim_trailing(rest, "}")

  defp unquote_arg("\"" <> rest) do
    rest
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp unquote_arg(bare), do: bare
end
