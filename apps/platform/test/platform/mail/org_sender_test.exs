defmodule Platform.Mail.OrgSenderTest do
  @moduledoc """
  `Platform.Mail.OrgSender.resolve/2` (task 01a1a933 stage 1): the one place
  that decides which `(account, sender key)` an org's meeting mail uses.

  async: false because it flips `:mail_enabled` and
  `:calendar_booking_mail_senders` in application env.
  """
  use Platform.DataCase, async: false

  alias Platform.Mail.Account
  alias Platform.Mail.OrgSender
  alias Platform.Mail.Sender
  alias Platform.Tenancy

  setup do
    prior =
      for key <- [:mail_enabled, :calendar_booking_mail_senders],
          into: %{},
          do: {key, Application.fetch_env(:platform, key)}

    Application.put_env(:platform, :mail_enabled, true)
    Application.delete_env(:platform, :calendar_booking_mail_senders)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    %{
      org_id: Tenancy.get_org_by_slug!("initech").id,
      other_org_id: Tenancy.get_org_by_slug!("globex").id
    }
  end

  defp account!(org_id, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %Account{
          org_id: org_id,
          name: "org-sender-#{n}",
          smtp_host: "smtp.example.com",
          smtp_port: 2525,
          smtp_tls: "none"
        },
        attrs
      )
    )
  end

  defp sender!(account, key) do
    Repo.insert!(%Sender{account_id: account.id, key: key, address: "#{key}@example.com"})
  end

  test "the well-known key is \"meetings\"" do
    assert OrgSender.meetings_sender_key() == "meetings"
  end

  test "an explicit app-env entry wins over a discovered meetings sender", ctx do
    discovered = account!(ctx.org_id)
    sender!(discovered, "meetings")
    explicit = account!(ctx.org_id)
    sender!(explicit, "booking")

    Application.put_env(:platform, :calendar_booking_mail_senders, %{
      ctx.org_id => %{account_id: explicit.id, sender_key: "booking"}
    })

    assert OrgSender.resolve(ctx.org_id, :meetings) ==
             {:ok, %{account_id: explicit.id, sender_key: "booking"}}
  end

  test "another org's app-env entry does not apply", ctx do
    Application.put_env(:platform, :calendar_booking_mail_senders, %{
      ctx.other_org_id => %{account_id: Ecto.UUID.generate(), sender_key: "meetings"}
    })

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}
  end

  test "a single account with a meetings sender resolves to it", ctx do
    # Created FIRST, with a sender sorting before "meetings": a first-account
    # or first-sender fallback would pick this one.
    first = account!(ctx.org_id, %{name: "aaa-first"})
    sender!(first, "agents")
    chosen = account!(ctx.org_id, %{name: "zzz-chosen"})
    sender!(chosen, "agents")
    sender!(chosen, "meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) ==
             {:ok, %{account_id: chosen.id, sender_key: "meetings"}}
  end

  test "no account with a meetings sender is :no_sender, never the first account/sender",
       ctx do
    account = account!(ctx.org_id)
    sender!(account, "agents")
    sender!(account, "ops")

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}
  end

  test "an org with no mail accounts at all is :no_sender", ctx do
    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}
  end

  test "two accounts with a meetings sender is :ambiguous_sender", ctx do
    for _ <- 1..2, do: ctx.org_id |> account!() |> sender!("meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :ambiguous_sender}
  end

  test "an archived account is ignored", ctx do
    archived = account!(ctx.org_id, %{archived_at: DateTime.utc_now()})
    sender!(archived, "meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}

    live = account!(ctx.org_id)
    sender!(live, "meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) ==
             {:ok, %{account_id: live.id, sender_key: "meetings"}}
  end

  test "a send-disabled account is ignored", ctx do
    disabled = account!(ctx.org_id, %{send_enabled: false})
    sender!(disabled, "meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}

    live = account!(ctx.org_id)
    sender!(live, "meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) ==
             {:ok, %{account_id: live.id, sender_key: "meetings"}}
  end

  test "another org's meetings sender is not discovered", ctx do
    ctx.other_org_id |> account!() |> sender!("meetings")

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :no_sender}
  end

  test "mail disabled is :mail_disabled, even with an app-env entry or a meetings sender",
       ctx do
    account = account!(ctx.org_id)
    sender!(account, "meetings")

    Application.put_env(:platform, :calendar_booking_mail_senders, %{
      ctx.org_id => %{account_id: account.id, sender_key: "meetings"}
    })

    Application.put_env(:platform, :mail_enabled, false)

    assert OrgSender.resolve(ctx.org_id, :meetings) == {:skip, :mail_disabled}
  end

  test "no org id is :no_org" do
    assert OrgSender.resolve(nil, :meetings) == {:skip, :no_org}
  end
end
