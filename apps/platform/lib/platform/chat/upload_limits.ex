defmodule Platform.Chat.UploadLimits do
  @moduledoc """
  The single read site for the per-install large-file upload limits
  (task 01a120be).

    * `max_bytes/0` — the largest file one chunked upload may reserve
      (`CHAT_MAX_UPLOAD_BYTES`, default 1_000_000_000 bytes, read "1 GB").
      Lowering it on an install is the rollout/rollback lever; no deploy
      needed.
    * `chunk_bytes/0` — the largest body one `PATCH` chunk may carry
      (`UPLOAD_CHUNK_BYTES`, default 33_554_432 bytes = 32 MiB), kept well under the edge's
      request-body cap so no single request carries a whole large file.
    * `label/0` — `max_bytes/0` rendered for people ("1 GB").
    * `format_bytes/1`, `format_progress/2` — the one decimal size-label
      rule every server-rendered byte count uses.

  Not to be confused with `:upload_max_bytes` (the agents' single-POST cap,
  500 MB) or `PlatformWeb.ChatLive`'s 15 MB inline LiveView cap; neither is
  read here and neither changes.
  """

  @default_max_bytes 1_000_000_000
  @default_chunk_bytes 33_554_432

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:platform, :chat_max_upload_bytes, @default_max_bytes)

  @spec chunk_bytes() :: pos_integer()
  def chunk_bytes, do: Application.get_env(:platform, :upload_chunk_bytes, @default_chunk_bytes)

  @spec label() :: String.t()
  def label, do: format_bytes(max_bytes())

  @doc "`:ok` when `byte_size` fits the per-install limit, else `{:error, :too_large}`."
  @spec check_size(integer()) :: :ok | {:error, :too_large}
  def check_size(byte_size) when is_integer(byte_size) do
    if byte_size <= max_bytes(), do: :ok, else: {:error, :too_large}
  end

  @doc """
  Human label for a byte count. One decimal rule on every surface (server,
  web JS, Android, iOS; task 01a120be):

    * below 1000 bytes: `"<n> bytes"`;
    * otherwise the largest unit k in KB, MB, GB, TB (1000^k) with
      `bytes >= 1000^k`, the value rounded half-up to one decimal, bumped to
      the next unit when rounding reaches 1000 (`999_960_000 -> "1 GB"`), and
      rendered without a trailing `.0`.

  `1_000_000_000 -> "1 GB"`, `1_073_741_824 -> "1.1 GB"`,
  `33_554_432 -> "33.6 MB"`, `512 -> "512 bytes"`.
  """
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    case unit_for(bytes) do
      {1, unit} -> "#{bytes} #{unit}"
      {divisor, unit} -> "#{render_tenths(tenths(bytes, divisor))} #{unit}"
    end
  end

  @doc """
  `"412 of 900 MB"`: the unit is picked from `total` (as `format_bytes/1`
  would), and `sent`, clamped to `total`, is rendered in that same unit with
  the same rounding, so the two numbers compare and the line does not change
  unit mid-upload.
  """
  @spec format_progress(non_neg_integer(), non_neg_integer()) :: String.t()
  def format_progress(sent, total)
      when is_integer(sent) and is_integer(total) and total >= 0 do
    sent = sent |> max(0) |> min(total)

    case unit_for(total) do
      {1, unit} ->
        "#{sent} of #{total} #{unit}"

      {divisor, unit} ->
        "#{render_tenths(tenths(sent, divisor))} of #{render_tenths(tenths(total, divisor))} #{unit}"
    end
  end

  @units [{1, "KB"}, {2, "MB"}, {3, "GB"}, {4, "TB"}]

  # `{divisor, unit}`: the largest k with bytes >= 1000^k, then one step up
  # when the rounded value reaches 1000 (999.96 MB reads "1 GB").
  defp unit_for(bytes) when bytes < 1000, do: {1, "bytes"}

  defp unit_for(bytes) do
    k =
      @units
      |> Enum.filter(fn {k, _} -> bytes >= Integer.pow(1000, k) end)
      |> List.last()
      |> elem(0)

    k = if k < 4 and tenths(bytes, Integer.pow(1000, k)) >= 10_000, do: k + 1, else: k
    {Integer.pow(1000, k), elem(List.keyfind(@units, k, 0), 1)}
  end

  # bytes / divisor in tenths, rounded half-up, in integer arithmetic.
  defp tenths(bytes, divisor), do: div(bytes * 20 + divisor, 2 * divisor)

  defp render_tenths(t) when rem(t, 10) == 0, do: Integer.to_string(div(t, 10))
  defp render_tenths(t), do: "#{div(t, 10)}.#{rem(t, 10)}"
end
