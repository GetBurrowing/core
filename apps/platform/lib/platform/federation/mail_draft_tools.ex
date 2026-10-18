defmodule Platform.Federation.MailDraftTools do
  @moduledoc """
  Definitions of the Email module's two agent tools, `mail_draft_create` and
  `mail_draft_update` (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 5).
  `Platform.Federation.ToolSurface` lists them in the `mail` bundle (split
  out of `messaging` by task 01a0d4a0 stage 4) while
  `Platform.Mail.Config.enabled?/0` is true and executes them.

  They live in their own module because their `responsibility` argument —
  the delivery-row attribution `Platform.Mail.Draft` carries — is a
  different concept from the retired stage-level responsibility that
  `Platform.Tasks.StageResponsibilityRetiredTest` keeps off
  `tool_surface.ex`.

  Drafts only. There is no send tool, here or anywhere on the surface.
  """

  @arg_keys ~w(account_id sender_key to_addresses to_user_ids subject body
               on_behalf_of_user_id responsibility task_id)

  @doc "The draft fields an agent may set; everything else in `args` is ignored."
  @spec arg_keys() :: [String.t()]
  def arg_keys, do: @arg_keys

  @doc "The two tool definitions, in the ToolSurface rubric shape."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "mail_draft_create",
        description:
          "Write an email DRAFT in an org's Email module for a person to review, edit and send. You cannot send it: there is no agent send tool. The draft appears in the org's Drafts tab marked as drafted by you (and the task, if you pass one); a person opens it, sees the exact body, may edit it, and sends it from a dispatch address the org configured. The body is stored verbatim and always shown as plain escaped text — never as HTML or markdown. If you draft from an inbound email, keep its untrusted-content wrapper visible; do not paste it as your own words.",
        parameters: %{
          org_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the org whose Email module the draft goes into. Tenant-pinned agents may only use their own org."
          },
          account_id: %{
            type: "string",
            required: false,
            description:
              "UUID of one of the org's mail accounts to send from. Optional — the person can pick it. Must belong to org_id and not be archived."
          },
          sender_key: %{
            type: "string",
            required: false,
            description:
              "Sender key on that account (e.g. \"ops\"). Requires account_id. Never defaulted: omit it and the person picks."
          },
          to_addresses: %{
            type: "array",
            required: false,
            description: "Recipient email addresses."
          },
          to_user_ids: %{
            type: "array",
            required: false,
            description: "Recipient Burrow user ids; expanded to their addresses at send time."
          },
          subject: %{type: "string", required: true, description: "Subject line."},
          body: %{
            type: "string",
            required: true,
            description: "Plain-text body, stored exactly as given."
          },
          on_behalf_of_user_id: %{
            type: "string",
            required: false,
            description: "The org member this email is on behalf of, if any."
          },
          responsibility: %{
            type: "string",
            required: false,
            description: "The responsibility this draft serves, recorded on the delivery."
          },
          task_id: %{
            type: "string",
            required: false,
            description:
              "UUID of the task this draft belongs to. Its project must be in org_id. Shown on the draft as \"task <title>\"."
          }
        },
        returns:
          "%{draft_id, org_id, account_id, sender_key, to_addresses, to_user_ids, subject, body_length, status: \"draft\", review_path} — review_path is the Email module path a person opens it at.",
        limitations:
          "Drafts only; nothing is sent and no send tool exists. Refused with a recoverable error when the Email module is not enabled. A tenant-pinned agent drafting into a sibling org gets an `unauthorized: …` envelope. An unknown account, a sender key not on the account, an unknown recipient user id, a malformed address, an on-behalf-of user who is not an org member, or a task outside the org is refused and nothing is written.",
        when_to_use:
          "When a task calls for an email to go out and a person should review and send it."
      },
      %{
        name: "mail_draft_update",
        description:
          "Revise an email draft YOU created with mail_draft_create, while it is still a draft. Only the fields you pass change. You cannot edit a person's draft, and you cannot send.",
        parameters: %{
          draft_id: %{
            type: "string",
            required: true,
            description: "UUID of the draft (from mail_draft_create)."
          },
          account_id: %{type: "string", required: false, description: "See mail_draft_create."},
          sender_key: %{type: "string", required: false, description: "See mail_draft_create."},
          to_addresses: %{
            type: "array",
            required: false,
            description: "Replaces the address list."
          },
          to_user_ids: %{
            type: "array",
            required: false,
            description: "Replaces the user-recipient list."
          },
          subject: %{type: "string", required: false, description: "New subject."},
          body: %{type: "string", required: false, description: "New body, stored verbatim."},
          on_behalf_of_user_id: %{
            type: "string",
            required: false,
            description: "See mail_draft_create."
          },
          responsibility: %{
            type: "string",
            required: false,
            description: "See mail_draft_create."
          },
          task_id: %{type: "string", required: false, description: "See mail_draft_create."}
        },
        returns: "The same shape as mail_draft_create.",
        limitations:
          "Refused with a recoverable error when the Email module is not enabled. Only drafts you created, only while their status is draft (a sent or discarded draft is not editable). Tenant-pinned agents cannot reach a sibling org's draft (`unauthorized: …`). Same validation as mail_draft_create.",
        when_to_use:
          "When you need to correct or revise a draft you wrote before a person sends it."
      }
    ]
  end
end
