defmodule Platform.Mail.SingleSenderGuardTest do
  @moduledoc """
  GUARD (task 01a0cf21 stage 2): exactly one module sends mail.

    * No file under `lib/` outside `lib/platform/mail/` may mention Swoosh or
      gen_smtp.
    * Exactly one file under `lib/` does `use Swoosh.Mailer`:
      `lib/platform/mail/mailer.ex`.
    * Exactly one file under `lib/` calls `Mailer.deliver`:
      `lib/platform/mail/deliverer.ex`, the post-commit step of
      `Platform.Mail.Dispatch`.

  The detector is also run on a planted fixture below, so a green result here
  is shown to be a detector that CAN fire, not one that cannot see.
  """
  use ExUnit.Case, async: true

  @mail_dir "lib/platform/mail/"
  @outside_pattern ~r/Swoosh\.|:gen_smtp|gen_smtp_client/
  @use_mailer ~r/use\s+Swoosh\.Mailer/
  @mailer_deliver ~r/\bMailer\.deliver!?\(/

  defp lib_files do
    "lib/**/*.{ex,exs,heex}"
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp outside_offenders(files_with_source) do
    for {path, source} <- files_with_source,
        not String.starts_with?(path, @mail_dir),
        Regex.match?(@outside_pattern, source),
        do: path
  end

  defp matching(files_with_source, regex) do
    for {path, source} <- files_with_source, Regex.match?(regex, source), do: path
  end

  defp sources, do: Enum.map(lib_files(), &{&1, File.read!(&1)})

  test "the scan sees the lib tree (a scan of nothing would pass vacuously)" do
    files = lib_files()
    assert length(files) > 100
    assert "lib/platform/mail/mailer.ex" in files
    assert "lib/platform/mail/deliverer.ex" in files
  end

  test "nothing outside lib/platform/mail/ references Swoosh or gen_smtp" do
    assert outside_offenders(sources()) == [],
           "Swoosh / gen_smtp referenced outside #{@mail_dir}. Mail goes out " <>
             "through Platform.Mail.Dispatch only."
  end

  test "exactly one module is a Swoosh.Mailer, and it is Platform.Mail.Mailer" do
    assert matching(sources(), @use_mailer) == ["lib/platform/mail/mailer.ex"]
  end

  test "exactly one file calls Mailer.deliver, and it is the Deliverer" do
    assert matching(sources(), @mailer_deliver) == ["lib/platform/mail/deliverer.ex"]
  end

  test "POSITIVE CONTROL: the detector fires on a planted violation" do
    planted = [
      {"lib/platform/chat/sneaky.ex", "Swoosh.Adapters.SMTP.deliver(email, relay: \"x\")"},
      {"lib/platform/tasks/sneaky.ex", ":gen_smtp_client.send_blocking(mail, opts)"},
      {"lib/platform/mail/fine.ex", "Swoosh.Email.new()"}
    ]

    assert outside_offenders(planted) == [
             "lib/platform/chat/sneaky.ex",
             "lib/platform/tasks/sneaky.ex"
           ]

    assert matching(
             [{"lib/platform/x.ex", "  use Swoosh.Mailer, otp_app: :platform"}],
             @use_mailer
           ) == ["lib/platform/x.ex"]

    assert matching([{"lib/platform/y.ex", "Mailer.deliver(email, config)"}], @mailer_deliver) ==
             ["lib/platform/y.ex"]
  end
end
