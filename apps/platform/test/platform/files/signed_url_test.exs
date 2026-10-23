defmodule Platform.Files.SignedUrlTest do
  @moduledoc """
  `Platform.Files.SignedUrl` (task 01a165ec stage 1): sign/verify round trip,
  expiry, tamper, and salt isolation from the attachment upload tokens.
  """

  use Platform.DataCase, async: true

  alias Platform.Chat.AttachmentPresigner
  alias Platform.Files.SignedUrl

  @path "/files/signed/"

  defp token_of(url) do
    [_, token] = String.split(url, @path, parts: 2)
    token
  end

  defp file_id, do: Ecto.UUID.generate()

  defp mint!(id, opts \\ []) do
    {:ok, url} = SignedUrl.url(%Platform.Files.File{id: id}, opts)
    url
  end

  test "url/2 is absolute on the endpoint and verify/1 returns the file id" do
    id = file_id()
    url = mint!(id)

    assert String.starts_with?(url, PlatformWeb.Endpoint.url() <> @path)
    assert SignedUrl.verify(token_of(url)) == {:ok, id}
  end

  test "an :expires_at further out than the default still verifies" do
    id = file_id()
    later = DateTime.add(DateTime.utc_now(), 3 * 24 * 3600, :second)

    assert SignedUrl.verify(token_of(mint!(id, expires_at: later))) == {:ok, id}
  end

  test "an expiry in the past is refused at mint time" do
    past = DateTime.add(DateTime.utc_now(), -10, :second)

    assert SignedUrl.url(%Platform.Files.File{id: file_id()}, expires_at: past) ==
             {:error, :invalid_expiry}
  end

  test "an expired token verifies as :expired" do
    token =
      SignedUrl.sign_payload(%{
        file_id: file_id(),
        expires_at: System.os_time(:second) - 5
      })

    assert SignedUrl.verify(token) == {:error, :expired}
  end

  test "flipping one byte of the token makes it :invalid" do
    token = token_of(mint!(file_id()))
    mid = div(byte_size(token), 2)
    <<head::binary-size(mid), c, rest::binary>> = token
    flipped = if c == ?A, do: ?B, else: ?A
    tampered = head <> <<flipped>> <> rest

    refute tampered == token
    assert SignedUrl.verify(tampered) == {:error, :invalid}
  end

  test "an AttachmentPresigner token (other salt, same key) is refused" do
    upload_token =
      AttachmentPresigner.sign(%{
        key: "files/x/y",
        max_bytes: 1_000,
        expires_at: System.os_time(:second) + 3600
      })

    assert SignedUrl.verify(upload_token) == {:error, :invalid}
  end

  test "garbage and non-binary tokens are :invalid" do
    assert SignedUrl.verify("not-a-token") == {:error, :invalid}
    assert SignedUrl.verify(nil) == {:error, :invalid}
  end

  test "url/2 with an unknown id is :not_found" do
    assert SignedUrl.url(file_id()) == {:error, :not_found}
  end
end
