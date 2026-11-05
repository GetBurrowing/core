defmodule Platform.Mail.DelivererTest do
  @moduledoc """
  What `Platform.Mail.Deliverer` hands to the mailer for a delivery carrying
  the rich parts (task 01a1a933 stage 1): an HTML alternative, Reply-To, and
  a calendar invite.

  The captured `Swoosh.Email` is rendered to wire MIME with
  `Platform.Mail.Mime.render/2`, the function the production adapter
  (`Platform.Mail.SmtpAdapter`) sends, then parsed back with the `mail`
  package, so
  the assertions are about the message a relay would receive, not about the
  struct that described it.

  async: false because it flips `:mail_enabled` in application env.
  """
  use Platform.DataCase, async: false

  alias Platform.Mail.Account
  alias Platform.Mail.Dispatch
  alias Platform.Mail.Draft
  alias Platform.Mail.Sender
  alias Platform.Tenancy

  @ics """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//example//meetings//EN\r
  METHOD:REQUEST\r
  BEGIN:VEVENT\r
  UID:invite-1@example.com\r
  DTSTAMP:20261105T090000Z\r
  DTSTART:20261106T150000Z\r
  DTEND:20261106T153000Z\r
  SUMMARY:Roadmap review\r
  ORGANIZER:mailto:meetings@example.com\r
  ATTENDEE;RSVP=TRUE:mailto:guest@example.com\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    org_id = Tenancy.get_org_by_slug!("initech").id

    account =
      Repo.insert!(%Account{
        org_id: org_id,
        name: "deliverer-#{System.unique_integer([:positive])}",
        smtp_host: "smtp.example.com",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com",
      display_name: "Meetings"
    })

    %{org_id: org_id, account: account}
  end

  defp send!(ctx, attrs) do
    draft =
      %Draft{}
      |> Draft.changeset(
        Map.merge(
          %{
            org_id: ctx.org_id,
            account_id: ctx.account.id,
            sender_key: "meetings",
            to_addresses: ["guest@example.com"],
            subject: "Invitation: Roadmap review",
            body: "You are invited.",
            created_by_type: "system"
          },
          attrs
        )
      )
      |> Repo.insert!()

    assert {:ok, delivery} = Dispatch.dispatch(draft.id, :system)
    assert delivery.status == "accepted"
    assert_received {:mail_test_adapter, email, _config}
    {delivery, email}
  end

  # The bytes `Platform.Mail.SmtpAdapter` hands to gen_smtp, parsed back.
  defp wire(email) do
    email
    |> Platform.Mail.Mime.render([])
    |> Mail.parse()
  end

  # Every leaf part, depth first: {content-type, params, disposition, body}.
  defp leaves(%Mail.Message{multipart: true, parts: parts}), do: Enum.flat_map(parts, &leaves/1)

  defp leaves(%Mail.Message{} = part) do
    [type | params] = List.wrap(Mail.Message.get_header(part, :content_type))
    disposition = part |> Mail.Message.get_header(:content_disposition) |> List.wrap()
    [{String.downcase(type), Map.new(params), List.first(disposition), part.body}]
  end

  defp tree(%Mail.Message{multipart: true, parts: parts} = message),
    do: {content_type(message), Enum.map(parts, &tree/1)}

  defp tree(%Mail.Message{} = part), do: content_type(part)

  defp content_type(message) do
    message |> Mail.Message.get_header(:content_type) |> List.wrap() |> hd() |> String.downcase()
  end

  describe "a delivery with html, Reply-To and a REQUEST calendar" do
    setup ctx do
      {delivery, email} =
        send!(ctx, %{
          html_body: "<p>You are <b>invited</b>.</p>",
          reply_to: "organizer@example.com",
          calendar_method: "REQUEST",
          calendar_ics: @ics
        })

      %{delivery: delivery, email: email, message: wire(email)}
    end

    test "carries an html part and the plain part", %{message: message} do
      parts = leaves(message)

      assert [{_, _, _, html}] = Enum.filter(parts, &(elem(&1, 0) == "text/html"))
      assert html =~ "<b>invited</b>"
      assert [{_, _, _, text}] = Enum.filter(parts, &(elem(&1, 0) == "text/plain"))
      assert text =~ "You are invited."
    end

    test "carries Reply-To", %{email: email, message: message} do
      assert email.reply_to == {"", "organizer@example.com"}
      assert Mail.Message.get_header(message, :reply_to) == "organizer@example.com"
    end

    test "carries a text/calendar part whose content type names method=REQUEST",
         %{message: message} do
      assert [{"text/calendar", params, disposition, body}] =
               Enum.filter(leaves(message), &(elem(&1, 0) == "text/calendar"))

      assert params["method"] == "REQUEST"
      assert String.downcase(params["charset"]) == "utf-8"
      assert disposition == "inline"
      assert body == @ics
    end

    test "carries an invite.ics attachment with the same bytes", %{message: message} do
      assert [{"application/ics", _params, "attachment", body}] =
               Enum.filter(leaves(message), &(elem(&1, 0) == "application/ics"))

      assert body == @ics
      assert {"invite.ics", @ics} in Mail.get_attachments(message, :attachment)
    end

    test "the MIME tree is mixed[alternative[plain, html, calendar], ics]", %{message: message} do
      assert tree(message) ==
               {"multipart/mixed",
                [
                  {"multipart/alternative", ["text/plain", "text/html", "text/calendar"]},
                  "application/ics"
                ]}
    end
  end

  test "with no html body the calendar still joins the plain part in an alternative", ctx do
    {_delivery, email} = send!(ctx, %{calendar_method: "REQUEST", calendar_ics: @ics})

    assert email |> wire() |> tree() ==
             {"multipart/mixed",
              [{"multipart/alternative", ["text/plain", "text/calendar"]}, "application/ics"]}
  end

  test "a CANCEL calendar names method=CANCEL", ctx do
    {_delivery, email} =
      send!(ctx, %{
        calendar_method: "CANCEL",
        calendar_ics: String.replace(@ics, "METHOD:REQUEST", "METHOD:CANCEL")
      })

    assert [{"text/calendar", %{"method" => "CANCEL"}, _, _}] =
             email |> wire() |> leaves() |> Enum.filter(&(elem(&1, 0) == "text/calendar"))
  end

  test "REGRESSION: a draft with no rich fields is exactly today's plain email", ctx do
    {delivery, email} = send!(ctx, %{})

    assert email.html_body == nil
    assert email.reply_to == nil
    assert email.attachments == []
    assert email.text_body == "You are invited."
    assert email.subject == "Invitation: Roadmap review"
    assert email.from == {"Meetings", "meetings@example.com"}
    assert email.to == [{"", "guest@example.com"}]
    assert email.headers == %{"Message-ID" => delivery.message_id_header}

    message = wire(email)
    refute message.multipart
    assert content_type(message) == "text/plain"
    assert Mail.Message.get_header(message, :reply_to) == nil
  end
end
