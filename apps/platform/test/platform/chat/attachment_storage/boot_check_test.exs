defmodule Platform.Chat.AttachmentStorage.BootCheckTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.AttachmentStorage.BootCheck

  setup do
    root = Path.join(System.tmp_dir!(), "platform-bootcheck-test-#{Ecto.UUID.generate()}")
    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end
    end)

    {:ok, root: root}
  end

  describe "init/1" do
    test "returns :ignore when storage is writable" do
      assert BootCheck.init(:ok) == :ignore
    end

    test "propagates the ensure_writable! raise when storage is broken" do
      # /dev/null is a char device; mkdir_p of a child path fails with
      # :enotdir for all users including root (vs. chmod which root bypasses).
      bad_root = "/dev/null/platform-bootcheck-boot-#{Ecto.UUID.generate()}"
      Application.put_env(:platform, :chat_attachments_root, bad_root)

      assert_raise RuntimeError, ~r/attachment storage is not writable/i, fn ->
        BootCheck.init(:ok)
      end
    end
  end
end
