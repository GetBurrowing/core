defmodule Platform.Mail.SystemTest do
  @moduledoc """
  `Platform.Mail.System`, the install-wide sender: off until
  `SYSTEM_SMTP_HOST` is configured, and then a send through
  `Platform.Mail.Mailer` with the relay passed as `deliver/2` overrides.

  `Platform.Mail.TestAdapter` sends `{:mail_test_adapter, email, config}` to
  the calling process, so "sends nothing" is a `refute_received`.

  async: false because it flips `Platform.Mail.System` in application env.
  """
  use ExUnit.Case, async: false

  alias Platform.Mail.System, as: SystemMail

  setup do
    saved = Application.fetch_env(:platform, SystemMail)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, SystemMail, v)
        :error -> Application.delete_env(:platform, SystemMail)
      end
    end)

    Application.delete_env(:platform, SystemMail)
    :ok
  end

  defp configure(extra \\ []) do
    Application.put_env(
      :platform,
      SystemMail,
      Keyword.merge(
        [
          from: "Burrow <noreply@legacypie.getburrow.ing>",
          host: "smtp.example.test",
          port: 587,
          username: "mailer",
          password: "s3cret",
          tls: "starttls"
        ],
        extra
      )
    )
  end

  test "not configured: configured?/0 is false, nothing is sent" do
    refute SystemMail.configured?()
    assert {:error, :not_configured} = SystemMail.deliver("a@example.test", "Hi", "text", nil)
    refute_received {:mail_test_adapter, _, _}
  end

  test "a blank host is not configured" do
    configure(host: "")
    refute SystemMail.configured?()
    assert {:error, :not_configured} = SystemMail.deliver("a@example.test", "Hi", "text", nil)
    refute_received {:mail_test_adapter, _, _}
  end

  test "configured: builds from, to, subject and both bodies, and uses the relay settings" do
    configure()
    assert SystemMail.configured?()

    assert {:ok, _} = SystemMail.deliver("maria@example.test", "Hello", "plain", "<p>html</p>")

    assert_received {:mail_test_adapter, email, config}
    assert email.from == {"Burrow", "noreply@legacypie.getburrow.ing"}
    assert email.to == [{"", "maria@example.test"}]
    assert email.subject == "Hello"
    assert email.text_body == "plain"
    assert email.html_body == "<p>html</p>"

    assert config[:relay] == "smtp.example.test"
    assert config[:port] == 587
    assert config[:tls] == :always
    assert config[:auth] == :always
    assert config[:username] == "mailer"
    assert config[:password] == "s3cret"
  end

  test "tls mode and a missing port default like a mail account" do
    configure(tls: "tls", port: nil, username: nil, password: nil)
    assert {:ok, _} = SystemMail.deliver("a@example.test", "Hi", "text", nil)

    assert_received {:mail_test_adapter, email, config}
    assert email.html_body == nil
    assert config[:ssl] == true
    assert config[:port] == 465
    assert config[:auth] == :never
  end

  test "a bare From address is used as given" do
    configure(from: "noreply@example.test")
    assert {:ok, _} = SystemMail.deliver("a@example.test", "Hi", "text", nil)
    assert_received {:mail_test_adapter, email, _}
    assert email.from == {"", "noreply@example.test"}
  end

  test "configured without a From address: {:error, :no_from}, nothing is sent" do
    configure(from: nil)
    assert {:error, :no_from} = SystemMail.deliver("a@example.test", "Hi", "text", nil)
    refute_received {:mail_test_adapter, _, _}
  end

  test "never raises: an adapter that raises comes back as an error" do
    configure()
    Process.put(:mail_test_adapter_hook, fn _ -> raise "relay exploded" end)
    on_exit(fn -> Process.delete(:mail_test_adapter_hook) end)

    assert {:error, {:raised, "relay exploded"}} =
             SystemMail.deliver("a@example.test", "Hi", "text", nil)
  end
end
