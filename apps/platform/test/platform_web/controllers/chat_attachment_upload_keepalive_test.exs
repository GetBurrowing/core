defmodule PlatformWeb.ChatAttachmentUploadKeepaliveTest do
  @moduledoc """
  Keep-alive regression for the presigned upload controller (task 01a0fdf9).

  The controller used to send its post-read response on the conn it was
  CALLED with, not the conn `Plug.Conn.read_body/2` returned. Bandit drains
  any unread request body from the adapter state of the conn the plug
  RETURNS (`Bandit.Pipeline` -> `ensure_completed`), so the stale conn still
  reported the whole Content-Length as unread and Bandit read that many more
  bytes off the wire. Those bytes belong to the NEXT request on the
  keep-alive connection, which then failed (400 / timeout / closed).

  `Plug.Test` / `ConnTest` cannot show this: there is no socket and no
  Bandit pipeline. So this test boots a real Bandit listener around the
  real `PlatformWeb.Endpoint` and drives it with ONE Mint connection per
  test. Mint never reconnects on its own, so a second response on the same
  Mint conn is structural proof of keep-alive reuse.

  Headers are sent SEPARATELY from the body (`:stream`, a sleep, then the
  chunks). That is load-bearing: Bandit's header read is `recv(socket, 0)`,
  and on loopback a single write can land the whole body in that first
  buffer, so the stale drain reads nothing off the wire and the bug hides.
  Production only showed it above ~9.2 KB for the same reason.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Platform.Chat
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk

  @bandit_errors ["Bandit.HTTPError", "Request line HTTP error", "Body read timeout"]

  setup do
    root =
      Path.join(System.tmp_dir!(), "platform-upload-keepalive-test-#{Ecto.UUID.generate()}")

    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:platform, :chat_attachments_root, prev)
    end)

    port = free_port()

    start_supervised!(
      {Bandit,
       plug: PlatformWeb.Endpoint,
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false,
       thousand_island_options: [read_timeout: 2_000]}
    )

    {:ok, mint} = Mint.HTTP1.connect(:http, "127.0.0.1", port, mode: :passive)

    on_exit(fn -> Mint.HTTP.close(mint) end)

    %{mint: mint}
  end

  # Each case runs its requests inside `with_log/1` and asserts OUTSIDE it, so
  # a failure message carries every request's outcome AND the captured log.
  # The log refute runs first: that is how a red run shows the refute can
  # fire (its positive control), instead of the first status assert hiding it.
  describe "keep-alive reuse after an upload" do
    test "(a) two single-read uploads (20 KB, :ok branch) both store intact", %{mint: mint} do
      {steps, log} =
        with_log(fn ->
          {mint, s1} = step(mint, "#1 valid 20 KB", 20_000, 20_000)
          {_mint, s2} = step(mint, "#2 valid 20 KB", 20_000, 20_000)
          [s1, s2]
        end)

      refute_bandit_errors(log, steps)
      [s1, s2] = steps
      assert_stored(s1, log)
      assert_stored(s2, log)
    end

    test "(b) two multi-read uploads (300 KB, :more then :ok) both store intact", %{mint: mint} do
      {steps, log} =
        with_log(fn ->
          {mint, s1} = step(mint, "#1 valid 300 KB", 300_000, 300_000)
          {_mint, s2} = step(mint, "#2 valid 300 KB", 300_000, 300_000)
          [s1, s2]
        end)

      refute_bandit_errors(log, steps)
      [s1, s2] = steps
      assert_stored(s1, log)
      assert_stored(s2, log)
    end

    test "(c) a 413 after a PARTIAL read, then a valid upload on the same connection",
         %{mint: mint} do
      {steps, log} =
        with_log(fn ->
          # max 70_000, body 300_000: `:more` 64 KB (under cap), then `:more`
          # 128 KB total (over cap) -> 413 with body still unread on the wire.
          {mint, s1} = step(mint, "#1 300 KB over a 70_000 cap", 300_000, 70_000)
          {_mint, s2} = step(mint, "#2 valid 20 KB", 20_000, 20_000)
          [s1, s2]
        end)

      refute_bandit_errors(log, steps)
      [s1, s2] = steps
      assert_too_large(s1, log)
      assert_stored(s2, log)
    end

    test "(d) a 413 on the single-read :ok branch, then a valid upload on the same connection",
         %{mint: mint} do
      {steps, log} =
        with_log(fn ->
          # max 10_000, body 30_000: one `:ok` read of 30_000 -> over cap.
          {mint, s1} = step(mint, "#1 30 KB over a 10_000 cap", 30_000, 10_000)
          {_mint, s2} = step(mint, "#2 valid 20 KB", 20_000, 20_000)
          [s1, s2]
        end)

      refute_bandit_errors(log, steps)
      [s1, s2] = steps
      assert_too_large(s1, log)
      assert_stored(s2, log)
    end
  end

  defp refute_bandit_errors(log, steps) do
    for needle <- @bandit_errors do
      refute log =~ needle,
             "captured log contains #{inspect(needle)}\n#{summary(steps)}\ncaptured log:\n#{log}"
    end
  end

  # Reserves a pending attachment with `max_bytes` and uploads `size` random
  # bytes to it over `mint`. No assertions here; see `assert_stored/2`.
  defp step(mint, label, size, max_bytes) do
    body = random_bytes(size)
    %{token: token, key: key} = reserve_pending(max_bytes)
    {mint, status, resp} = upload(mint, token, body)
    {mint, %{label: label, status: status, resp: resp, key: key, body: body}}
  end

  defp assert_stored(step, log) do
    size = byte_size(step.body)
    assert step.status == 200, failure(step, log)
    assert %{"byte_size" => ^size} = Jason.decode!(step.resp)
    assert File.read!(LocalDisk.path_for(step.key)) == step.body
  end

  defp assert_too_large(step, log) do
    assert step.status == 413, failure(step, log)
    assert step.resp =~ "body exceeds max_bytes"
  end

  defp failure(step, log),
    do: "#{summary([step])}\ncaptured log:\n#{log}"

  defp summary(steps) do
    Enum.map_join(steps, "\n", fn s -> "#{s.label}: #{inspect(s.status)} #{inspect(s.resp)}" end)
  end

  # Headers first, a pause so they arrive in their own TCP read, then the
  # body in chunks. Returns `{mint, status, body}`; a transport failure
  # (closed / timeout) is returned as the status so the assertion message
  # names it instead of crashing on a match.
  defp upload(mint, token, body) do
    headers = [
      {"content-type", "application/octet-stream"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    with {:ok, mint, ref} <-
           Mint.HTTP1.request(mint, "POST", "/chat/attachments/upload/#{token}", headers, :stream),
         :ok <- Process.sleep(50),
         {:ok, mint} <- stream_chunks(mint, ref, body),
         {:ok, mint} <- Mint.HTTP1.stream_request_body(mint, ref, :eof) do
      collect(mint, ref, %{status: nil, data: []})
    else
      {:error, mint, reason} -> {mint, {:transport_error, reason}, ""}
    end
  end

  defp stream_chunks(mint, _ref, <<>>), do: {:ok, mint}

  defp stream_chunks(mint, ref, body) do
    {chunk, rest} =
      case body do
        <<chunk::binary-size(16_384), rest::binary>> -> {chunk, rest}
        chunk -> {chunk, <<>>}
      end

    case Mint.HTTP1.stream_request_body(mint, ref, chunk) do
      {:ok, mint} -> stream_chunks(mint, ref, rest)
      {:error, mint, reason} -> {:error, mint, reason}
    end
  end

  defp collect(mint, ref, acc) do
    case Mint.HTTP.recv(mint, 0, 10_000) do
      {:ok, mint, responses} ->
        case Enum.reduce(responses, {:cont, acc}, &fold_response(&1, &2, ref)) do
          {:done, acc} -> {mint, acc.status, IO.iodata_to_binary(acc.data)}
          {:cont, acc} -> collect(mint, ref, acc)
        end

      {:error, mint, reason, _responses} ->
        {mint, {:transport_error, reason}, IO.iodata_to_binary(acc.data)}
    end
  end

  defp fold_response(_resp, {:done, _} = done, _ref), do: done

  defp fold_response({:status, ref, status}, {:cont, acc}, ref),
    do: {:cont, %{acc | status: status}}

  defp fold_response({:data, ref, data}, {:cont, acc}, ref),
    do: {:cont, %{acc | data: [acc.data, data]}}

  defp fold_response({:done, ref}, {:cont, acc}, ref), do: {:done, acc}
  defp fold_response(_other, acc, _ref), do: acc

  defp random_bytes(n), do: :crypto.strong_rand_bytes(n)

  # Same shape as `reserve_pending/2` in chat_attachment_upload_controller_test.exs.
  defp reserve_pending(max_bytes) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Upload Keepalive Test",
        slug: "ulka-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    key = "chat/upload/#{Ecto.UUID.generate()}.bin"

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        filename: "upload.bin",
        content_type: "application/octet-stream",
        byte_size: max_bytes,
        storage_key: key,
        state: "pending",
        upload_expires_at: DateTime.utc_now() |> DateTime.add(900, :second)
      })

    %{attachment: attachment, token: sign_key(key, max_bytes), key: key}
  end

  defp sign_key(key, max_bytes) do
    expires = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_unix()
    AttachmentPresigner.sign(%{key: key, max_bytes: max_bytes, expires_at: expires})
  end

  # Same as `free_port/0` in test/platform/agents/providers/ollama_test.exs.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
