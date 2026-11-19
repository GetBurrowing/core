defmodule Platform.Mail.MimeThreadingTest do
  @moduledoc """
  A reply threads (task 01a1f426 stage 4): a delivery of a draft linked to
  an inbound email (`mail_drafts.in_reply_to_inbound_id`) renders, through
  `Platform.Mail.Deliverer.build_email/1` and `Platform.Mail.Mime.render/2`
  (the bytes the relay receives), with `In-Reply-To` = that email's
  Message-ID and `References` = its References plus its Message-ID. An
  unlinked draft, or an email of ANOTHER account, adds neither header.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures

  alias Platform.Mail.{Deliverer, Delivery, Draft, Mime}

  setup do
    org_id = acme_org_id()
    a = user!("a") |> member!(org_id, "admin")
    box = account!(a, org_id)
    other = account!(a, org_id)
    %{org_id: org_id, box: box, other: other}
  end

  defp draft!(ctx, inbound_id) do
    %Draft{}
    |> Draft.changeset(%{
      org_id: ctx.org_id,
      account_id: ctx.box.id,
      sender_key: "ops",
      to_addresses: ["them@outside.test"],
      subject: "Re: contract",
      body: "Confirmed.",
      created_by_type: "system",
      in_reply_to_inbound_id: inbound_id
    })
    |> Repo.insert!()
  end

  defp render(ctx, draft, account \\ nil) do
    %Delivery{
      id: Ecto.UUID.generate(),
      org_id: ctx.org_id,
      account_id: (account || ctx.box).id,
      sender_key: "ops",
      from_address: "ops@example.test",
      recipients: ["them@outside.test"],
      subject: draft.subject,
      body: draft.body,
      draft_id: draft.id,
      message_id_header: "<out-1@example.test>",
      status: "sending"
    }
    |> Deliverer.build_email()
    |> Mime.render()
  end

  defp header(bytes, name) do
    [head | _] = String.split(bytes, "\r\n\r\n", parts: 2)

    head
    |> String.replace(~r/\r\n[ \t]+/, " ")
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [^name, value] -> String.trim(value)
        _ -> nil
      end
    end)
  end

  test "In-Reply-To and References name the email the draft answers", ctx do
    inbound =
      inbound!(ctx.box, %{
        message_id_header: "<parent-1@otherco.test>",
        raw:
          "From: them@outside.test\r\nReferences: <root-0@otherco.test>\r\nMessage-ID: <parent-1@otherco.test>\r\n\r\nHi"
      })

    bytes = render(ctx, draft!(ctx, inbound.id))

    assert header(bytes, "In-Reply-To") == "<parent-1@otherco.test>"
    assert header(bytes, "References") == "<root-0@otherco.test> <parent-1@otherco.test>"
    assert header(bytes, "Message-ID") == "<out-1@example.test>"
  end

  test "a stored Message-ID without brackets is bracketed", ctx do
    inbound =
      inbound!(ctx.box, %{message_id_header: "bare-2@otherco.test", raw: "X: y\r\n\r\nHi"})

    bytes = render(ctx, draft!(ctx, inbound.id))
    assert header(bytes, "In-Reply-To") == "<bare-2@otherco.test>"
    assert header(bytes, "References") == "<bare-2@otherco.test>"
  end

  test "no link, or a delivery from another account: no threading headers", ctx do
    bytes = render(ctx, draft!(ctx, nil))
    assert header(bytes, "In-Reply-To") == nil
    assert header(bytes, "References") == nil

    inbound = inbound!(ctx.box)
    bytes = render(ctx, draft!(ctx, inbound.id), ctx.other)
    assert header(bytes, "In-Reply-To") == nil
  end
end
