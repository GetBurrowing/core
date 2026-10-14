defmodule Platform.Chat.UploadLimitsTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.UploadLimits

  setup do
    prev =
      for k <- [:chat_max_upload_bytes, :upload_chunk_bytes],
          do: {k, Application.fetch_env(:platform, k)}

    on_exit(fn ->
      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:platform, k, v)
        {k, :error} -> Application.delete_env(:platform, k)
      end)
    end)
  end

  test "defaults are 1_000_000_000 bytes (\"1 GB\") and 32 MiB chunks" do
    Application.delete_env(:platform, :chat_max_upload_bytes)
    Application.delete_env(:platform, :upload_chunk_bytes)
    assert UploadLimits.max_bytes() == 1_000_000_000
    assert UploadLimits.chunk_bytes() == 33_554_432
    assert UploadLimits.label() == "1 GB"
  end

  test "reads the per-install override" do
    Application.put_env(:platform, :chat_max_upload_bytes, 2_000_000_000)
    assert UploadLimits.max_bytes() == 2_000_000_000
    assert UploadLimits.label() == "2 GB"
    assert UploadLimits.check_size(2_000_000_000) == :ok
    assert UploadLimits.check_size(2_000_000_001) == {:error, :too_large}
  end

  # The shared table every surface (server, web JS, Android, iOS) tests
  # against (task 01a120be): one decimal rule, no binary units.
  @format_table [
    {1_000_000_000, "1 GB"},
    {1_073_741_824, "1.1 GB"},
    {899_109_076, "899.1 MB"},
    {900_000_000, "900 MB"},
    {1_153_433_600, "1.2 GB"},
    {8_000_000, "8 MB"},
    {33_554_432, "33.6 MB"},
    {999_960_000, "1 GB"},
    {512, "512 bytes"}
  ]

  for {bytes, label} <- @format_table do
    test "format_bytes(#{bytes}) is #{inspect(label)}" do
      assert UploadLimits.format_bytes(unquote(bytes)) == unquote(label)
    end
  end

  test "format_bytes edges: unit boundaries, half-up rounding, TB cap" do
    assert UploadLimits.format_bytes(0) == "0 bytes"
    assert UploadLimits.format_bytes(999) == "999 bytes"
    assert UploadLimits.format_bytes(1000) == "1 KB"
    # 1.25 KB: half-up, not banker's rounding.
    assert UploadLimits.format_bytes(1250) == "1.3 KB"
    assert UploadLimits.format_bytes(1249) == "1.2 KB"
    assert UploadLimits.format_bytes(999_949) == "999.9 KB"
    assert UploadLimits.format_bytes(999_950) == "1 MB"
    assert UploadLimits.format_bytes(2_000_000_000) == "2 GB"
    assert UploadLimits.format_bytes(1_500_000_000_000) == "1.5 TB"
    # TB is the top unit: no bump past it.
    assert UploadLimits.format_bytes(1_000_000_000_000_000) == "1000 TB"
  end

  test "progress(412_000_000, 900_000_000) is \"412 of 900 MB\"" do
    assert UploadLimits.format_progress(412_000_000, 900_000_000) == "412 of 900 MB"
  end

  test "progress(416_000_000, 899_109_076) is \"416 of 899.1 MB\"" do
    assert UploadLimits.format_progress(416_000_000, 899_109_076) == "416 of 899.1 MB"
  end

  test "format_progress takes the unit from total and clamps sent" do
    assert UploadLimits.format_progress(0, 1_153_433_600) == "0 of 1.2 GB"
    assert UploadLimits.format_progress(2_000_000_000, 1_000_000_000) == "1 of 1 GB"
    assert UploadLimits.format_progress(10, 5) == "5 of 5 bytes"
    # The total's bump (999.96 MB -> GB) carries to sent.
    assert UploadLimits.format_progress(500_000_000, 999_960_000) == "0.5 of 1 GB"
  end
end
