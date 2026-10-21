defmodule PlatformWeb.EmailLive do
  @moduledoc """
  The Email module (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4).

  Its own module in the rail's Working cluster, gated by `MAIL_ENABLED`
  (`Platform.Mail.Config.enabled?/0`); it is NOT an admin screen and nothing
  lives under `/admin`.

  ## Who reaches it

  `mount/3` raises `PlatformWeb.EmailLive.NotFoundError` (a 404) when the
  module flag is off, or when the viewer has no non-external org membership
  (`Platform.Mail.can_use?/2`). Routes are compile-time; this is the gate.

  ## Layout

  Header (org picker when the viewer has more than one non-external
  membership, account filter, Accounts, New email), tabs — Inbox, Drafts,
  Sent, Refused — a list, and one right-hand detail pane that shows either a
  message or the accounts pane. Below `lg` the pane opens full-width over
  the list with a Back control. The pane is ONE node at every width, so each
  data-role resolves to exactly one element.

  ## Authorization

  Presentation hides the account controls from members; it is not the
  check. Every mutating `handle_event` calls an actor-taking `Platform.Mail`
  function (`create_account/4`, `update_account/3`, `replace_secret/4`,
  `put_sender/3`, `delete_sender/3`, `archive_account/2`, `send_test/3`,
  `refresh_inbound/2`, `start_backfill/4`) or
  `Platform.Mail.Mailbox.add_to_files/3`, and those re-check. A crafted
  event from a member writes nothing.

  ## Refresh

  The inbox header's Refresh (org admins, when an account reads mail) runs
  one immediate IMAP poll of every reading account through
  `Platform.Mail.refresh_inbound/2`, in `start_async/3` so the LiveView is
  never blocked on IMAP. Each poll goes through the account's poller
  (`Platform.Mail.Inbound.poll_now/2`), so it cannot race the timer. The
  flash names each account's outcome; error text is built from atoms only.

  ## Import older mail (task 01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 3)

  The account editor carries one "Import older mail" row for org admins
  when the account reads mail (`Platform.Mail.Inbound.eligible?/1`); it is
  absent, not disabled, otherwise. Import calls
  `Platform.Mail.start_backfill/4` with a window from the fixed set 7 / 14 /
  30 days. The row's state (idle, running, done, failed) is always the
  latest `Platform.Mail.BackfillRun` row read through
  `Platform.Mail.latest_backfill/2`, never LiveView-only state, so a reload
  or a second device shows the same run. Progress arrives as
  `{:mail_backfill_progress, %{run_id, account_id}}` (IDs only) on
  `Platform.Mail.subscribe_backfill/1`; each one re-reads the row, and a run
  that has finished reloads the inbox lists. The import is quiet: nothing is
  posted to chat and nothing is broadcast on `"mail:inbound"`, and the row
  says so before the admin clicks.

  ## Inbound mail is outside text

  A message body renders as escaped plain text only — no HTML, no markdown,
  no mention parsing — under the label "External email — not from a Burrow
  member". "Add to files" stores the body inside the untrusted-content
  wrapper (`Platform.Mail.Mailbox.render_markdown/2`).

  ## Drafts, the editor and the confirm pane (stage 5)

  "New email" and a Drafts row open the EDITOR in the main area
  (`/email/drafts/new`, `/email/drafts/:id`): From (every sender of every
  send-enabled account, shown by its dispatch address), To (org people and
  free addresses), Subject, Body. "Review & send…" saves the draft and opens
  the CONFIRM pane on the right; it is not the send.

  On an internal-only account each outside recipient is flagged in place
  ("Outside the org") and Review & send is absent until the person removes
  it. Nothing is dropped silently. The flag comes from
  `Platform.Mail.Drafts.recipients/3`, i.e. `Platform.Mail.Internal` — the
  function the send path's check calls — never a re-derivation here.

  "Send now" calls `Platform.Mail.Dispatch.dispatch/3` with the viewer as
  actor and on-behalf-of, pinned to the draft version the confirm pane
  showed (`:expected_updated_at`). The server re-applies send-enabled,
  internal-only and the rate limit; the UI's gating is presentation. Draft
  bodies — including agent-written ones — render as escaped plain text in
  both the editor and the confirm pane, exactly as they will be sent.

  ## Status words

  Sent rows read Queued / Sending / Accepted by <host> / Failed: <error>.
  Never "Delivered" and never a success colour: SMTP acceptance is not
  delivery. `--color-error` marks refusals and failures only.
  """

  use PlatformWeb, :live_view

  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Dispatch
  alias Platform.Mail.Drafts
  alias Platform.Mail.Inbound
  alias Platform.Mail.Mailbox
  alias Platform.Tenancy

  defmodule NotFoundError do
    @moduledoc "Raised by `PlatformWeb.EmailLive.mount/3` to answer 404."
    defexception message: "not found", plug_status: 404
  end

  @tabs ~w(inbox drafts sent refused)
  @secret_kinds ~w(smtp imap)
  @account_flags ~w(send_enabled internal_only read_enabled)

  # ── Mount / params ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]
    orgs = usable_orgs(user)

    if not Mail.Config.enabled?() or orgs == [] do
      raise NotFoundError
    end

    {:ok,
     socket
     |> assign(:page_title, "Email")
     |> assign(:current_path, "/email")
     |> assign(:user, user)
     |> assign(:orgs, orgs)
     |> assign(:org_id, nil)
     |> assign(:tab, "inbox")
     |> assign(:account_filter, nil)
     |> assign(:pane, nil)
     |> assign(:selected_message, nil)
     |> assign(:selected_file, nil)
     |> assign(:add_error, nil)
     |> assign(:form_error, nil)
     |> assign(:replacing, MapSet.new())
     |> assign(:test_results, %{})
     |> assign(:refreshing, false)
     |> assign(:backfill, nil)
     |> assign(:backfill_topics, MapSet.new())
     |> assign(:form, nil)
     |> assign(:form_account, nil)
     |> assign(:editor, nil)
     |> assign(:confirm, nil)
     |> assign(:send_result, nil)
     |> assign(:senders, [])
     |> assign(:people, [])
     |> assign(:provenance, %{})
     |> assign(:editor_account, nil)
     |> assign(:editor_recipients, [])
     |> assign(:editor_reviewable?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:tab, tab_param(params["tab"]))
      |> assign_org(params)
      |> assign(:account_filter, account_param(params["account"]))
      |> assign(:add_error, nil)
      |> assign(:form_error, nil)
      |> reset_compose(socket.assigns.live_action)
      |> apply_action(socket.assigns.live_action, params)
      |> load_lists()

    {:noreply, socket}
  end

  defp usable_orgs(%{id: _} = user) do
    user
    |> Tenancy.list_user_memberships()
    |> Enum.reject(& &1.external)
    |> Enum.map(& &1.org)
    |> Enum.reject(&(is_nil(&1) or Map.get(&1, :archived_at)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  defp usable_orgs(_), do: []

  defp tab_param(tab) when tab in @tabs, do: tab
  defp tab_param(_), do: "inbox"

  defp account_param(id) when is_binary(id) and id != "" do
    if Platform.UUID.valid?(id), do: id
  end

  defp account_param(_), do: nil

  # The org is the `?org=` param when the viewer may use it, else their
  # first usable org. A deep link to a message picks the message's org.
  defp assign_org(socket, params) do
    requested = params["org"]
    orgs = socket.assigns.orgs

    org_id =
      case Enum.find(orgs, &(&1.id == requested)) do
        %{id: id} -> id
        nil -> socket.assigns.org_id || hd(orgs).id
      end

    socket
    |> assign(:org_id, org_id)
    |> assign(:is_admin, Mail.can_manage_accounts?(socket.assigns.user, org_id))
    |> assign(:accounts, Mail.list_accounts(org_id))
  end

  # Leaving the editor for any other screen drops its in-memory state. A
  # patch between the new-draft and saved-draft routes keeps it.
  defp reset_compose(socket, action) when action in [:new_draft, :draft], do: socket

  defp reset_compose(socket, _action) do
    socket |> assign(:editor, nil) |> assign(:confirm, nil) |> assign(:send_result, nil)
  end

  defp apply_action(socket, :new_draft, _params) do
    socket
    |> assign(:tab, "drafts")
    |> assign(:selected_message, nil)
    |> assign(:form, nil)
    |> assign(:send_result, nil)
    |> assign(:confirm, nil)
    |> assign(:pane, nil)
    |> load_compose_choices()
    |> assign(:editor, new_editor(socket.assigns))
    |> refresh_editor()
  end

  defp apply_action(socket, :draft, %{"id" => id}) do
    case socket.assigns.editor do
      %{draft_id: ^id} ->
        assign(socket, :tab, "drafts")

      _ ->
        open_draft(socket, id)
    end
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:pane, nil) |> assign(:selected_message, nil) |> assign(:form, nil)
  end

  defp apply_action(socket, :message, %{"id" => id}) do
    org_id = Mailbox.inbound_org_id(id)

    socket =
      if org_id && org_id != socket.assigns.org_id &&
           Enum.any?(socket.assigns.orgs, &(&1.id == org_id)) do
        assign_org(socket, %{"org" => org_id})
      else
        socket
      end

    case Mailbox.get_inbound(socket.assigns.org_id, id) do
      nil ->
        socket
        |> put_flash(:error, "That email is not in this org's inbox.")
        |> assign(:pane, nil)
        |> assign(:selected_message, nil)

      message ->
        socket
        |> assign(:pane, :message)
        |> assign(:tab, "inbox")
        |> assign(:selected_message, message)
        |> assign(:selected_file, Mailbox.inbound_file(message))
        |> assign(:projects, Mailbox.org_projects(message.org_id))
        |> assign(:form, nil)
    end
  end

  defp apply_action(socket, :accounts, _params) do
    socket
    |> assign(:pane, :accounts)
    |> assign(:selected_message, nil)
    |> assign(:form, nil)
    |> assign(:form_account, nil)
  end

  defp apply_action(socket, :new_account, _params) do
    if socket.assigns.is_admin do
      socket
      |> assign(:pane, :new_account)
      |> assign(:selected_message, nil)
      |> assign(:form_account, nil)
      |> assign(:replacing, MapSet.new())
      |> assign(:form, account_form(%Account{}, %{}))
      |> assign(:channels, Mailbox.org_channels(socket.assigns.org_id))
    else
      socket
      |> put_flash(:error, "Only org admins can add mail accounts.")
      |> apply_action(:accounts, %{})
    end
  end

  defp apply_action(%{assigns: %{is_admin: false}} = socket, :account, _params) do
    socket
    |> put_flash(:error, "Only org admins can edit mail accounts.")
    |> apply_action(:accounts, %{})
  end

  defp apply_action(socket, :account, %{"id" => id}) do
    case Mail.get_account(socket.assigns.org_id, id) do
      %Account{archived_at: nil} = account ->
        socket
        |> assign(:pane, :account)
        |> assign(:selected_message, nil)
        |> assign(:form_account, account)
        |> assign(:replacing, MapSet.new())
        |> assign(:form, account_form(account, %{}))
        |> assign(:channels, Mailbox.org_channels(socket.assigns.org_id))
        |> load_backfill()

      _ ->
        socket
        |> put_flash(:error, "That mail account is not in this org.")
        |> apply_action(:accounts, %{})
    end
  end

  defp open_draft(socket, id) do
    socket =
      case Drafts.fetch(id) do
        {:ok, %{org_id: org_id}} when org_id != socket.assigns.org_id ->
          if Enum.any?(socket.assigns.orgs, &(&1.id == org_id)),
            do: assign_org(socket, %{"org" => org_id}),
            else: socket

        _ ->
          socket
      end

    case Drafts.get(socket.assigns.org_id, id) do
      %{status: "draft"} = draft ->
        socket
        |> assign(:tab, "drafts")
        |> assign(:pane, nil)
        |> assign(:selected_message, nil)
        |> assign(:form, nil)
        |> assign(:confirm, nil)
        |> assign(:send_result, nil)
        |> load_compose_choices()
        |> assign(:editor, editor_from_draft(draft))
        |> refresh_editor()

      %{} ->
        socket
        |> put_flash(:error, "That draft was already sent or discarded.")
        |> assign(:tab, "drafts")
        |> assign(:pane, nil)

      nil ->
        socket
        |> put_flash(:error, "That draft is not in this org.")
        |> assign(:tab, "drafts")
        |> assign(:pane, nil)
    end
  end

  defp load_compose_choices(socket) do
    org_id = socket.assigns.org_id

    socket
    |> assign(:senders, Drafts.sendable_senders(org_id))
    |> assign(:people, Drafts.org_people(org_id))
  end

  defp load_lists(socket) do
    %{org_id: org_id, account_filter: account_id, tab: tab} = socket.assigns
    opts = [account_id: account_id]

    counts = %{
      "inbox" => Mailbox.count_inbound(org_id, opts),
      "drafts" => Mailbox.count_drafts(org_id, opts)
    }

    rows =
      case tab do
        "inbox" -> Mailbox.list_inbound(org_id, opts)
        "drafts" -> Mailbox.list_drafts(org_id, opts)
        "sent" -> Mailbox.list_deliveries(org_id, :sent, opts)
        "refused" -> Mailbox.list_deliveries(org_id, :refused, opts)
      end

    provenance = if tab == "drafts", do: Drafts.provenance(rows), else: %{}

    socket
    |> assign(:counts, counts)
    |> assign(:rows, rows)
    |> assign(:provenance, provenance)
  end

  # ── Events: navigation ──────────────────────────────────────────────────

  @impl true
  def handle_event("filter", params, socket) do
    org_id =
      case Enum.find(socket.assigns.orgs, &(&1.id == params["org"])) do
        %{id: id} -> id
        nil -> socket.assigns.org_id
      end

    account =
      if org_id == socket.assigns.org_id, do: account_param(params["account"]), else: nil

    {:noreply,
     push_patch(socket,
       to: email_path(%{socket.assigns | org_id: org_id, account_filter: account}, "/email")
     )}
  end

  # ── Events: drafting ────────────────────────────────────────────────────

  def handle_event("editor_change", %{"draft" => params}, socket) do
    case socket.assigns.editor do
      nil ->
        {:noreply, socket}

      editor ->
        editor =
          editor
          |> put_if_present(params, "from", :from)
          |> put_if_present(params, "subject", :subject)
          |> put_if_present(params, "body", :body)
          |> put_if_present(params, "new_address", :new_address)
          |> add_user(params["add_user_id"])

        {:noreply, socket |> assign(:editor, editor) |> close_confirm() |> refresh_editor()}
    end
  end

  def handle_event("add_address", _params, socket) do
    case socket.assigns.editor do
      nil ->
        {:noreply, socket}

      editor ->
        {:noreply, socket |> assign(:editor, absorb_new_address(editor)) |> refresh_editor()}
    end
  end

  # The recipient travels as `phx-value-recipient`, never `phx-value-value`:
  # a clicked button's own (empty) `value` attribute overwrites a `value`
  # key in the browser, so the event would name no recipient at all.
  def handle_event("remove_recipient", %{"kind" => kind, "recipient" => value}, socket) do
    case socket.assigns.editor do
      nil ->
        {:noreply, socket}

      editor ->
        was_outside? =
          Enum.any?(
            socket.assigns.editor_recipients,
            &(Atom.to_string(&1.kind) == kind and &1.value == value and &1.outside?)
          )

        editor =
          case kind do
            "user" -> %{editor | to_user_ids: List.delete(editor.to_user_ids, value)}
            _ -> %{editor | to_addresses: List.delete(editor.to_addresses, value)}
          end

        editor = %{
          editor
          | edited?: true,
            removed_external: editor.removed_external + if(was_outside?, do: 1, else: 0)
        }

        {:noreply, socket |> assign(:editor, editor) |> close_confirm() |> refresh_editor()}
    end
  end

  def handle_event("save_draft", params, socket) do
    socket = apply_editor_params(socket, params)

    case persist_editor(socket) do
      {:ok, socket} -> {:noreply, put_flash(socket, :info, "Draft saved.")}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("discard_draft", _params, socket) do
    case socket.assigns.editor do
      %{draft_id: id} when is_binary(id) ->
        case Drafts.discard(socket.assigns.user, id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Draft discarded.")
             |> push_patch(to: tab_path(socket.assigns, "drafts"))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, draft_error_text(reason))}
        end

      _ ->
        {:noreply, push_patch(socket, to: tab_path(socket.assigns, "drafts"))}
    end
  end

  def handle_event("review", params, socket) do
    socket =
      case apply_editor_params(socket, params) do
        %{assigns: %{editor: nil}} = socket ->
          socket

        socket ->
          socket
          |> assign(:editor, absorb_new_address(socket.assigns.editor))
          |> refresh_editor()
      end

    cond do
      is_nil(socket.assigns.editor) ->
        {:noreply, socket}

      socket.assigns.editor.address_error ->
        {:noreply, socket}

      not socket.assigns.editor_reviewable? ->
        {:noreply,
         assign(socket, :editor, %{
           socket.assigns.editor
           | error: review_blocked_text(socket.assigns)
         })}

      true ->
        case persist_editor(socket) do
          {:ok, socket} -> {:noreply, open_confirm(socket)}
          {:error, socket} -> {:noreply, socket}
        end
    end
  end

  def handle_event("back_to_edit", _params, socket) do
    {:noreply, close_confirm(socket)}
  end

  # The server is the enforcement: this always goes to Dispatch, which
  # re-applies send-enabled, internal-only and the rate limit, and records a
  # refusal. It is not gated on what the UI chose to show.
  def handle_event("send", _params, socket) do
    with %{draft_id: id} when is_binary(id) <- socket.assigns.editor,
         %{status: "draft"} = draft <- Drafts.get(socket.assigns.org_id, id) do
      user = socket.assigns.user

      opts =
        [on_behalf_of_user_id: user.id] ++
          case socket.assigns.confirm do
            %{draft: %{id: ^id, updated_at: at}} -> [expected_updated_at: at]
            _ -> []
          end

      result = Dispatch.dispatch(draft.id, user, opts)
      {:noreply, show_send_result(socket, result)}
    else
      %{draft_id: nil} ->
        {:noreply,
         socket
         |> assign(:pane, :confirm)
         |> assign(:confirm, nil)
         |> assign(:send_result, {:error, "Not sent: save the draft first.", nil})}

      _ ->
        {:noreply,
         socket
         |> assign(:pane, :confirm)
         |> assign(:confirm, nil)
         |> assign(
           :send_result,
           {:error, "Not sent: that draft was already sent or discarded.", nil}
         )}
    end
  end

  # ── Events: Add to files ────────────────────────────────────────────────

  def handle_event("add_to_files", %{"project_id" => project_id}, socket) do
    case socket.assigns.selected_message do
      nil ->
        {:noreply, socket}

      message ->
        case Mailbox.add_to_files(socket.assigns.user, message.id, project_id) do
          {:ok, _created_or_existing, file} ->
            {:noreply,
             socket
             |> assign(:selected_message, %{message | file_id: file.id})
             |> assign(:selected_file, file)
             |> assign(:add_error, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :add_error, add_error_text(reason))}
        end
    end
  end

  # ── Events: accounts ────────────────────────────────────────────────────

  def handle_event("validate_account", %{"account" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :account))}
  end

  def handle_event("replace_secret", %{"kind" => kind}, socket) when kind in @secret_kinds do
    {:noreply, assign(socket, :replacing, MapSet.put(socket.assigns.replacing, kind))}
  end

  def handle_event("save_account", %{"account" => params}, socket) do
    user = socket.assigns.user
    org_id = socket.assigns.org_id

    with {:ok, attrs} <- account_attrs(params, org_id) do
      secrets = secrets_param(params)

      result =
        case socket.assigns.form_account do
          nil -> Mail.create_account(user, org_id, attrs, secrets)
          %Account{} = account -> update_with_secrets(user, account, attrs, secrets)
        end

      case result do
        {:ok, account} ->
          {:noreply,
           socket
           |> put_flash(:info, "Mail account saved.")
           |> push_patch(to: email_path(socket.assigns, "/email/accounts/#{account.id}"))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:form, to_form(params, as: :account))
           |> assign(:form_error, changeset_text(changeset))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:form, to_form(params, as: :account))
           |> assign(:form_error, account_error_text(reason))}
      end
    else
      {:error, text} ->
        {:noreply,
         socket |> assign(:form, to_form(params, as: :account)) |> assign(:form_error, text)}
    end
  end

  def handle_event("toggle_account_flag", %{"id" => id, "flag" => flag}, socket)
      when flag in @account_flags do
    with %Account{} = account <- Mail.get_account(socket.assigns.org_id, id),
         {:ok, _} <-
           Mail.update_account(socket.assigns.user, account, %{
             flag => !Map.fetch!(account, String.to_existing_atom(flag))
           }) do
      {:noreply, reload_accounts(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, account_error_text(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("add_sender", %{"sender" => params}, socket) do
    with %Account{} = account <- socket.assigns.form_account,
         {:ok, _sender} <-
           Mail.put_sender(
             socket.assigns.user,
             account,
             Map.take(params, ~w(key address display_name))
           ) do
      {:noreply, reload_form_account(socket)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form_error, changeset_text(changeset))}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, account_error_text(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_sender", %{"key" => key}, socket) do
    with %Account{} = account <- socket.assigns.form_account,
         {:ok, _} <- Mail.delete_sender(socket.assigns.user, account, key) do
      {:noreply, reload_form_account(socket)}
    else
      {:error, reason} -> {:noreply, assign(socket, :form_error, account_error_text(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("archive_account", %{"id" => id}, socket) do
    with %Account{} = account <- Mail.get_account(socket.assigns.org_id, id),
         {:ok, _} <- Mail.archive_account(socket.assigns.user, account) do
      {:noreply,
       socket
       |> put_flash(:info, "Mail account removed.")
       |> push_patch(to: email_path(socket.assigns, "/email/accounts"))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, account_error_text(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("send_test", %{"account_id" => id} = params, socket) do
    case Mail.get_account(socket.assigns.org_id, id) do
      %Account{} = account ->
        key = params["sender_key"] || single_sender_key(account)
        result = Mail.send_test(socket.assigns.user, account, key)

        {:noreply,
         socket
         |> assign(:test_results, Map.put(socket.assigns.test_results, id, test_result(result)))
         |> reload_accounts()
         |> load_lists()}

      nil ->
        {:noreply, socket}
    end
  end

  # Refresh: one immediate IMAP poll of every reading account, off the
  # LiveView process. `Mail.refresh_inbound/2` re-checks the actor.
  def handle_event("refresh_inbox", _params, %{assigns: %{refreshing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("refresh_inbox", _params, socket) do
    %{user: user, org_id: org_id} = socket.assigns

    {:noreply,
     socket
     |> assign(:refreshing, true)
     |> start_async(:refresh_inbox, fn -> Mail.refresh_inbound(user, org_id) end)}
  end

  # Import older mail: one quiet backfill of the open account. The window is
  # taken from the fixed set only; `Mail.start_backfill/4` re-checks the
  # actor, eligibility and the window, and refuses a second running import.
  def handle_event("start_backfill", %{"account_id" => id} = params, socket) do
    with {:ok, days} <- backfill_window(params["window_days"]),
         %Account{} = account <- Mail.get_account(socket.assigns.org_id, id),
         {:ok, run} <- Mail.start_backfill(socket.assigns.user, account, days) do
      {:noreply,
       socket
       |> assign(:backfill, run)
       |> subscribe_backfill(account.id)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That mail account is not in this org.")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, backfill_error_text(reason)) |> load_backfill()}
    end
  end

  # Progress is IDs only: re-read the row. Only the run's final write
  # carries `done`, so the inbox lists reload once per finished run, on
  # whichever pane is open.
  @impl true
  def handle_info({:mail_backfill_progress, %{account_id: account_id}}, socket) do
    case Mail.get_account(socket.assigns.org_id, account_id) do
      %Account{} = account ->
        run = Mail.latest_backfill(socket.assigns.user, account)

        socket =
          case socket.assigns.form_account do
            %Account{id: ^account_id} -> assign(socket, :backfill, run)
            _ -> socket
          end

        {:noreply, if(match?(%{status: "done"}, run), do: load_lists(socket), else: socket)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:refresh_inbox, {:ok, {:ok, results}}, socket) do
    socket = socket |> assign(:refreshing, false) |> load_lists()

    kind = if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: :error, else: :info
    {:noreply, put_flash(socket, kind, refresh_text(results))}
  end

  def handle_async(:refresh_inbox, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket |> assign(:refreshing, false) |> put_flash(:error, account_error_text(reason))}
  end

  def handle_async(:refresh_inbox, {:exit, _reason}, socket) do
    {:noreply,
     socket |> assign(:refreshing, false) |> put_flash(:error, "Refresh failed. Try again.")}
  end

  # ── Import older mail helpers ──────────────────────────────────────────

  @backfill_windows %{"7" => 7, "14" => 14, "30" => 30}

  @doc false
  def backfill_windows, do: [7, 14, 30]

  defp backfill_window(value) when is_binary(value) do
    case Map.fetch(@backfill_windows, value) do
      {:ok, days} -> {:ok, days}
      :error -> {:error, :invalid_window}
    end
  end

  defp backfill_window(_), do: {:error, :invalid_window}

  # The row reads the DB, never LiveView-only state. `latest_backfill/2`
  # returns nil to anyone who may not manage the account.
  defp load_backfill(%{assigns: %{form_account: %Account{} = account}} = socket) do
    socket
    |> assign(:backfill, Mail.latest_backfill(socket.assigns.user, account))
    |> subscribe_backfill(account.id)
  end

  defp load_backfill(socket), do: assign(socket, :backfill, nil)

  # Once per account per LiveView: a second subscribe would deliver every
  # progress message twice.
  defp subscribe_backfill(socket, account_id) do
    topics = socket.assigns.backfill_topics

    cond do
      not connected?(socket) ->
        socket

      MapSet.member?(topics, account_id) ->
        socket

      true ->
        :ok = Mail.subscribe_backfill(account_id)
        assign(socket, :backfill_topics, MapSet.put(topics, account_id))
    end
  end

  defp backfill_error_text(:unauthorized), do: "Only org admins can import mail."
  defp backfill_error_text(:already_running), do: "An import is already running for this account."
  defp backfill_error_text(:invalid_window), do: "Choose 7, 14 or 30 days."
  defp backfill_error_text(:not_eligible), do: "This account is not reading mail."
  defp backfill_error_text(_reason), do: "Could not start the import. Try again."

  @doc false
  def backfill_state(nil), do: "idle"
  def backfill_state(%{status: status}) when status in ~w(running done failed), do: status
  def backfill_state(_), do: "idle"

  @doc false
  # The folders an import reads: the configured list, or the live scope's
  # description. A special-use All folder (Gmail's All Mail) is never read by an
  # import, configured or not.
  def backfill_folders_text(%Account{read_folders: folders}) when folders in [nil, []],
    do: "All folders except Sent, Drafts, Trash, Junk/Spam, Archive, Starred and All Mail"

  def backfill_folders_text(%Account{read_folders: folders}), do: Enum.join(folders, ", ")

  @doc false
  def backfill_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def backfill_count(_), do: "0"

  @doc false
  def backfill_day(%Date{} = date), do: Calendar.strftime(date, "%-d %b")
  def backfill_day(_), do: ""

  @doc false
  def backfill_at(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b, %H:%M")
  def backfill_at(_), do: ""

  @doc false
  def backfill_noun(1), do: "message"
  def backfill_noun(_), do: "messages"

  @doc false
  def backfill_already_tail(1), do: "was already here."
  def backfill_already_tail(_), do: "were already here."

  @doc false
  # Messages the run has looked at so far: imported plus already stored, so
  # a re-run that imports nothing still visibly advances.
  def backfill_processed(%{imported: imported, already_present: present}),
    do: (imported || 0) + (present || 0)

  @doc false
  def backfill_default_window(%{window_days: days}) when days in [7, 14, 30], do: days
  def backfill_default_window(_), do: 30

  @doc false
  def backfill_button_label(%{status: "done"}), do: "Import again"
  def backfill_button_label(%{status: "failed"}), do: "Try again"
  def backfill_button_label(_), do: "Import"

  defp backfill_inbox_path(assigns, account_id),
    do: email_path(%{assigns | account_filter: account_id}, "/email")

  defp single_sender_key(%Account{senders: [%{key: key}]}), do: key
  defp single_sender_key(_), do: nil

  defp update_with_secrets(user, account, attrs, secrets) do
    with {:ok, updated} <- Mail.update_account(user, account, attrs) do
      Enum.reduce_while(secrets, {:ok, updated}, fn {kind, value}, {:ok, acc} ->
        case Mail.replace_secret(user, acc, kind, value) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reload_accounts(socket) do
    socket = assign(socket, :accounts, Mail.list_accounts(socket.assigns.org_id))

    case socket.assigns.form_account do
      %Account{id: id} ->
        assign(socket, :form_account, Mail.get_account(socket.assigns.org_id, id))

      nil ->
        socket
    end
  end

  defp reload_form_account(socket) do
    socket |> reload_accounts() |> assign(:form_error, nil)
  end

  # ── Drafting helpers ────────────────────────────────────────────────────

  defp close_confirm(socket) do
    socket |> assign(:confirm, nil) |> assign(:send_result, nil) |> assign(:pane, nil)
  end

  defp new_editor(assigns) do
    from =
      case Drafts.sendable_senders(assigns.org_id) do
        [{account, sender}] -> from_value(account.id, sender.key)
        _ -> ""
      end

    %{
      draft_id: nil,
      updated_at: nil,
      created_by_type: "user",
      created_by_id: assigns.user.id,
      task_id: nil,
      from: from,
      to_addresses: [],
      to_user_ids: [],
      subject: "",
      body: "",
      new_address: "",
      address_error: nil,
      error: nil,
      removed_external: 0,
      edited?: false
    }
  end

  defp editor_from_draft(draft) do
    %{
      draft_id: draft.id,
      updated_at: draft.updated_at,
      created_by_type: draft.created_by_type,
      created_by_id: draft.created_by_id,
      task_id: draft.task_id,
      from:
        if(draft.account_id && draft.sender_key,
          do: from_value(draft.account_id, draft.sender_key),
          else: ""
        ),
      to_addresses: draft.to_addresses || [],
      to_user_ids: draft.to_user_ids || [],
      subject: draft.subject || "",
      body: draft.body || "",
      new_address: "",
      address_error: nil,
      error: nil,
      removed_external: 0,
      edited?: false,
      provenance: Map.get(Drafts.provenance([draft]), draft.id)
    }
  end

  defp from_value(account_id, key), do: "#{account_id}:#{key}"

  defp parse_from(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [account_id, key] when account_id != "" and key != "" -> {account_id, key}
      _ -> {nil, nil}
    end
  end

  defp parse_from(_), do: {nil, nil}

  defp put_if_present(editor, params, key, field) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) ->
        if Map.fetch!(editor, field) == value do
          editor
        else
          editor
          |> Map.put(field, value)
          |> Map.put(:edited?, editor.edited? or field != :new_address)
        end

      _ ->
        editor
    end
  end

  defp add_user(editor, id) when is_binary(id) and id != "" do
    if id in editor.to_user_ids,
      do: editor,
      else: %{editor | to_user_ids: editor.to_user_ids ++ [id], edited?: true}
  end

  defp add_user(editor, _), do: editor

  # Split what was typed on commas, semicolons and whitespace. Valid
  # addresses join the list; anything else stays in the input, named.
  defp absorb_new_address(editor) do
    parts =
      (editor.new_address || "")
      |> String.split(~r/[\s,;]+/u, trim: true)

    {good, bad} = Enum.split_with(parts, &Drafts.valid_address?/1)

    existing = MapSet.new(editor.to_addresses, &String.downcase/1)

    added =
      good
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.reject(&MapSet.member?(existing, String.downcase(&1)))

    %{
      editor
      | to_addresses: editor.to_addresses ++ added,
        new_address: Enum.join(bad, ", "),
        address_error:
          if(bad == [], do: nil, else: "Not an email address: #{Enum.join(bad, ", ")}"),
        edited?: editor.edited? or added != []
    }
  end

  defp apply_editor_params(socket, %{"draft" => params}) do
    case socket.assigns.editor do
      nil ->
        socket

      editor ->
        editor =
          editor
          |> put_if_present(params, "from", :from)
          |> put_if_present(params, "subject", :subject)
          |> put_if_present(params, "body", :body)
          |> put_if_present(params, "new_address", :new_address)

        socket |> assign(:editor, editor) |> refresh_editor()
    end
  end

  defp apply_editor_params(socket, _params), do: socket

  # Recompute everything the editor shows from its state: the chosen
  # account, every recipient with its Internal flag, and whether Review &
  # send may be offered.
  defp refresh_editor(%{assigns: %{editor: nil}} = socket) do
    socket
    |> assign(:editor_account, nil)
    |> assign(:editor_recipients, [])
    |> assign(:editor_reviewable?, false)
  end

  defp refresh_editor(socket) do
    editor = socket.assigns.editor
    {account_id, key} = parse_from(editor.from)

    account =
      Enum.find_value(socket.assigns.senders, fn {account, sender} ->
        if account.id == account_id and sender.key == key, do: account
      end)

    recipients =
      Drafts.recipients(socket.assigns.org_id, editor.to_addresses, editor.to_user_ids)

    blocked? = internal_only?(account) and Enum.any?(recipients, & &1.outside?)

    socket
    |> assign(:editor_account, account)
    |> assign(:editor_recipients, recipients)
    |> assign(:editor_reviewable?, not is_nil(account) and recipients != [] and not blocked?)
  end

  defp internal_only?(%Account{internal_only: true}), do: true
  defp internal_only?(_), do: false

  defp outside_blocking(assigns) do
    if internal_only?(assigns.editor_account),
      do: Enum.filter(assigns.editor_recipients, & &1.outside?),
      else: []
  end

  defp review_blocked_text(assigns) do
    cond do
      is_nil(assigns.editor_account) -> "Choose who this email is from."
      assigns.editor_recipients == [] -> "Add at least one recipient."
      true -> "Remove the recipients outside the org first."
    end
  end

  # Save the editor's state as the draft (create on first save). Returns
  # `{:ok, socket}` with the editor pointed at the saved row, or
  # `{:error, socket}` with the refusal shown in place.
  defp persist_editor(socket) do
    editor = absorb_new_address(socket.assigns.editor)
    socket = socket |> assign(:editor, editor) |> refresh_editor()

    if editor.address_error do
      {:error, socket}
    else
      {account_id, key} = parse_from(editor.from)

      attrs = %{
        account_id: account_id,
        sender_key: key,
        to_addresses: editor.to_addresses,
        to_user_ids: editor.to_user_ids,
        subject: editor.subject,
        body: editor.body
      }

      result =
        case editor.draft_id do
          nil -> Drafts.create(socket.assigns.user, socket.assigns.org_id, attrs)
          id -> Drafts.update(socket.assigns.user, id, attrs)
        end

      case result do
        {:ok, draft} ->
          new? = is_nil(editor.draft_id)

          editor = %{
            editor
            | draft_id: draft.id,
              updated_at: draft.updated_at,
              error: nil
          }

          socket = socket |> assign(:editor, editor) |> refresh_editor()

          socket =
            if new?,
              do: push_patch(socket, to: email_path(socket.assigns, "/email/drafts/#{draft.id}")),
              else: socket

          {:ok, socket}

        {:error, reason} ->
          {:error, assign(socket, :editor, %{editor | error: draft_error_text(reason)})}
      end
    end
  end

  defp open_confirm(socket) do
    editor = socket.assigns.editor

    case Drafts.get(socket.assigns.org_id, editor.draft_id) do
      %{status: "draft"} = draft ->
        {account_id, key} = parse_from(editor.from)

        pair =
          Enum.find(socket.assigns.senders, fn {account, sender} ->
            account.id == account_id and sender.key == key
          end)

        case pair do
          {account, sender} ->
            recipients =
              Drafts.recipients(draft.org_id, draft.to_addresses, draft.to_user_ids)

            confirm = %{
              draft: draft,
              account: account,
              sender: sender,
              recipients: recipients,
              rate: Dispatch.rate_usage(account),
              provenance: Map.get(Drafts.provenance([draft]), draft.id),
              removed_external: editor.removed_external,
              edited?: editor.edited?
            }

            socket
            |> assign(:confirm, confirm)
            |> assign(:send_result, nil)
            |> assign(:pane, :confirm)

          nil ->
            assign(socket, :editor, %{editor | error: "Choose who this email is from."})
        end

      _ ->
        assign(socket, :editor, %{editor | error: "That draft was already sent or discarded."})
    end
  end

  defp show_send_result(socket, result) do
    {tone, text, tab} = send_result_text(result, socket.assigns.accounts)

    socket =
      socket
      |> assign(:send_result, {tone, text, tab})
      |> assign(:pane, :confirm)
      |> assign(:confirm, nil)

    case result do
      {:ok, _delivery} ->
        socket |> assign(:editor, nil) |> assign(:tab, "sent") |> load_lists()

      {:error, :draft_changed} ->
        # Show the person what the draft holds now before they try again.
        case Drafts.get(socket.assigns.org_id, socket.assigns.editor.draft_id) do
          %{status: "draft"} = draft ->
            socket
            |> assign(:editor, %{
              editor_from_draft(draft)
              | removed_external: socket.assigns.editor.removed_external
            })
            |> refresh_editor()

          _ ->
            socket
        end

      _ ->
        socket |> assign(:tab, "drafts") |> load_lists()
    end
  end

  @doc false
  # `{tone, text, tab}` for a send outcome: tone `:error` for failed and
  # refused, `:neutral` otherwise — never a success colour, never "Sent"
  # or "Delivered" as a status.
  def send_result_text({:ok, delivery}, accounts),
    do: {:neutral, status_text(delivery, accounts), "sent"}

  def send_result_text({:error, {:failed, error, _delivery}}, _accounts),
    do: {:error, "Failed: #{error}", "sent"}

  def send_result_text({:error, {:refused, reason, _delivery}}, _accounts),
    do: {:error, "Refused: #{refusal_text(reason)}", "refused"}

  def send_result_text({:error, :draft_changed}, _accounts),
    do: {:error, "Not sent: this draft changed since you reviewed it. Review it again.", nil}

  def send_result_text({:error, reason}, _accounts),
    do: {:error, "Not sent: #{draft_error_text(reason)}", nil}

  defp draft_error_text(:unauthorized), do: "you cannot write email for this org"
  defp draft_error_text(:draft_not_found), do: "that draft no longer exists"
  defp draft_error_text(:draft_not_editable), do: "that draft was already sent or discarded"
  defp draft_error_text(:draft_not_sendable), do: "that draft was already sent or discarded"
  defp draft_error_text(:draft_in_flight), do: "this draft is already being sent"
  defp draft_error_text(:account_not_found), do: "that account is not in this org"
  defp draft_error_text(:account_archived), do: "that account was removed"
  defp draft_error_text(:account_wrong_org), do: "that account is not in this org"
  defp draft_error_text(:sender_key_not_found), do: "that sender is not on the account"
  defp draft_error_text(:sender_key_without_account), do: "choose who this email is from"
  defp draft_error_text(:no_recipients), do: "add at least one recipient"
  defp draft_error_text(:mail_disabled), do: "the email module is off"

  defp draft_error_text({:invalid_addresses, bad}),
    do: "not email addresses: #{Enum.join(bad, ", ")}"

  defp draft_error_text({:unknown_recipient_user_ids, _}),
    do: "a recipient is no longer a Burrow user"

  defp draft_error_text({:invalid, message}), do: message
  defp draft_error_text(%Ecto.Changeset{} = changeset), do: changeset_text(changeset)
  defp draft_error_text(reason), do: inspect(reason)

  defp drafted_by_text(nil), do: nil

  defp drafted_by_text(%{drafted_by: by, task_title: title}) do
    "Drafted by #{by}" <> if(title, do: " · task #{title}", else: "")
  end

  defp editor_drafted_by(%{provenance: %{} = provenance}), do: drafted_by_text(provenance)
  defp editor_drafted_by(_editor), do: "Drafted by you"

  defp recorded_text(%{provenance: provenance, edited?: edited?, draft: draft}, user) do
    drafter =
      cond do
        draft.created_by_type == "user" and draft.created_by_id == user.id -> "you"
        provenance -> provenance.drafted_by
        true -> "unknown"
      end

    [
      "drafted by #{drafter}",
      provenance && provenance.task_title && "task #{provenance.task_title}",
      if(edited?, do: "edited and sent by you", else: "sent by you")
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp confirm_blocker(%{account: account, recipients: recipients, rate: {used, limit}}) do
    cond do
      not account.send_enabled ->
        "Sending is off for this account."

      account.internal_only and Enum.any?(recipients, & &1.outside?) ->
        "This account only sends to internal recipients. Go back and remove the ones outside the org."

      used >= limit ->
        "This account has used all #{limit} sends this hour. Try again later."

      true ->
        nil
    end
  end

  defp recipient_count_text(1), do: "1 recipient"
  defp recipient_count_text(n), do: "#{n} recipients"

  defp removed_text(1), do: "1 external recipient removed"
  defp removed_text(n), do: "#{n} external recipients removed"

  defp draft_recipients_preview(draft) do
    addresses = draft.to_addresses || []

    people =
      case length(draft.to_user_ids || []) do
        0 -> []
        1 -> ["1 person"]
        n -> ["#{n} people"]
      end

    case addresses ++ people do
      [] -> "(no recipients)"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp people_choices(people, editor) do
    Enum.reject(people, &(&1.id in editor.to_user_ids))
  end

  # ── Form <-> attrs ──────────────────────────────────────────────────────

  defp account_form(%Account{} = account, _overrides) do
    %{
      "name" => account.name,
      "smtp_host" => account.smtp_host,
      "smtp_port" => account.smtp_port,
      "smtp_tls" => account.smtp_tls || "starttls",
      "username" => account.username,
      "send_enabled" => to_string(account.send_enabled),
      "internal_only" => to_string(account.internal_only),
      "read_enabled" => to_string(account.read_enabled),
      "imap_host" => account.imap_host,
      "imap_port" => account.imap_port,
      "imap_tls" => account.imap_tls || "tls",
      "read_scope" => if(account.read_folders in [nil, []], do: "all", else: "chosen"),
      "read_folders" => Enum.join(account.read_folders || [], ", "),
      "inbound_space_id" => account.inbound_space_id,
      "rate_limit_per_hour" => account.rate_limit_per_hour
    }
    |> to_form(as: :account)
  end

  defp account_attrs(params, org_id) do
    with {:ok, space_id} <- inbound_space_param(params["inbound_space_id"], org_id) do
      folders =
        case params["read_scope"] do
          "chosen" ->
            (params["read_folders"] || "")
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          _ ->
            []
        end

      attrs =
        params
        |> Map.take(~w(name smtp_host smtp_port smtp_tls username imap_host imap_port imap_tls
             send_enabled internal_only read_enabled rate_limit_per_hour))
        |> Map.new(fn {k, v} -> {k, blank_to_nil(v)} end)
        |> Map.put("read_folders", folders)
        |> Map.put("inbound_space_id", space_id)

      {:ok, attrs}
    end
  end

  # The select offers only channels this org owns; a crafted value outside
  # that list is refused rather than written.
  defp inbound_space_param(value, _org_id) when value in [nil, ""], do: {:ok, nil}

  defp inbound_space_param(value, org_id) do
    if Enum.any?(Mailbox.org_channels(org_id), &(&1.id == value)),
      do: {:ok, value},
      else: {:error, "Incoming mail can only post to a channel this org owns."}
  end

  defp secrets_param(params) do
    for kind <- @secret_kinds,
        value = params["#{kind}_secret"],
        is_binary(value) and value != "",
        into: %{},
        do: {String.to_existing_atom(kind), value}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # ── Text ────────────────────────────────────────────────────────────────

  defp add_error_text(:unauthorized), do: "You cannot add this org's mail to files."
  defp add_error_text(:project_not_found), do: "Pick a project this org owns."
  defp add_error_text(:not_found), do: "That email is no longer in the inbox."
  defp add_error_text(:project_archived), do: "That project is archived."
  defp add_error_text(reason), do: "Could not add to files: #{inspect(reason)}"

  defp account_error_text(:unauthorized), do: "Only org admins can change mail accounts."
  defp account_error_text(:account_archived), do: "That mail account was removed."
  defp account_error_text(:sender_key_not_found), do: "That sender is not on this account."
  defp account_error_text(:invalid_secret), do: "Enter a value to replace the secret."
  defp account_error_text(reason), do: "Could not save: #{inspect(reason)}"

  # Is there anything for Refresh to poll?
  defp refreshable?(accounts), do: Enum.any?(accounts, &Inbound.eligible?/1)

  @doc false
  # The flash after Refresh: one clause per account. Error reasons are
  # rendered from atoms only; any server text or other term in a reason is
  # dropped, so nothing a server or the Vault returned is echoed.
  def refresh_text([]), do: "No account is reading mail."

  def refresh_text(results) do
    Enum.map_join(results, " · ", fn
      {account, {:ok, %{ingested: 0}}} -> "#{account.name}: no new mail"
      {account, {:ok, %{ingested: 1}}} -> "#{account.name}: 1 new message"
      {account, {:ok, %{ingested: n}}} -> "#{account.name}: #{n} new messages"
      {account, {:ok, _}} -> "#{account.name}: checked"
      {account, {:error, reason}} -> "#{account.name}: failed (#{refresh_reason(reason)})"
    end)
  end

  defp refresh_reason(:secret_unavailable), do: "IMAP password missing or unreadable"
  defp refresh_reason(:not_configured), do: "no IMAP password set"
  defp refresh_reason(:timeout), do: "timed out"
  defp refresh_reason({:no, _detail}), do: "server refused the login or command"
  defp refresh_reason({:bad, _detail}), do: "server rejected a command"
  defp refresh_reason(reason) when is_atom(reason), do: humanize_reason(reason)

  defp refresh_reason({tag, inner}) when is_atom(tag) and is_atom(inner),
    do: "#{humanize_reason(tag)}: #{humanize_reason(inner)}"

  defp refresh_reason({tag, _}) when is_atom(tag), do: humanize_reason(tag)
  defp refresh_reason(_), do: "poll failed"

  defp humanize_reason(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  defp changeset_text(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {message, opts}} ->
      "#{Phoenix.Naming.humanize(field)} " <>
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
    end)
  end

  @doc false
  # The in-place result of "Send test". `{tone, text}`: tone `:error` for a
  # failure or refusal, `:neutral` otherwise — never a success colour.
  def test_result({:ok, delivery}) do
    code =
      case Regex.run(~r/^\s*(\d{3})/, delivery.smtp_response || "") do
        [_, code] -> "SMTP #{code}"
        _ -> "SMTP"
      end

    {:neutral, "Accepted (#{code}) for #{Enum.join(delivery.recipients, ", ")}"}
  end

  def test_result({:error, {:failed, error, _delivery}}), do: {:error, "Failed: #{error}"}

  def test_result({:error, {:refused, reason, _delivery}}),
    do: {:error, "Refused: #{refusal_text(reason)}"}

  def test_result({:error, :unauthorized}),
    do: {:error, "Refused: only org admins can send a test email."}

  def test_result({:error, :no_address}),
    do: {:error, "Failed: your account has no email address."}

  def test_result({:error, :sender_key_not_found}),
    do: {:error, "Failed: add a sender to this account first."}

  def test_result({:error, reason}), do: {:error, "Failed: #{inspect(reason)}"}

  @doc false
  def refusal_text(:send_disabled), do: "sending is off for this account"
  def refusal_text(:rate_limited), do: "this account's hourly rate limit is used up"

  def refusal_text({:external_recipients, addresses}),
    do: "outside this org: #{Enum.join(addresses, ", ")}"

  def refusal_text(_), do: "refused"

  @doc false
  # The status word of a Sent row. Never "Delivered".
  def status_text(%{status: "queued"}, _accounts), do: "Queued"
  def status_text(%{status: "sending"}, _accounts), do: "Sending"

  def status_text(%{status: "accepted", account_id: account_id}, accounts) do
    host =
      case Enum.find(accounts, &(&1.id == account_id)) do
        %{smtp_host: host} when is_binary(host) and host != "" -> host
        _ -> "the relay"
      end

    "Accepted by #{host}"
  end

  def status_text(%{status: "failed", error: error}, _accounts),
    do: "Failed: #{error || "unknown error"}"

  def status_text(%{status: status}, _accounts), do: status

  defp refused_reason(%{refusal_reason: reason}) do
    case Dispatch.decode_refusal(reason) do
      {:external_recipients, _} -> "Recipients outside this org"
      nil -> "Refused"
      other -> other |> refusal_text() |> String.capitalize()
    end
  end

  defp refused_addresses(%{refusal_reason: reason}) do
    case Dispatch.decode_refusal(reason) do
      {:external_recipients, addresses} -> addresses
      _ -> []
    end
  end

  # ── Components ──────────────────────────────────────────────────────────

  attr(:account, :map, required: true)
  attr(:label, :string, default: "Send test")

  # "Send test" for one account. One sender: a button. Several: pick which.
  # None: says so instead of offering a send that can only refuse.
  defp test_send_control(assigns) do
    ~H"""
    <form
      :if={@account.senders != []}
      phx-submit="send_test"
      class="flex flex-wrap items-center gap-2"
      id={"mail-test-send-#{@account.id}"}
      data-role="mail-test-send"
    >
      <input type="hidden" name="account_id" value={@account.id} />
      <select
        :if={length(@account.senders) > 1}
        name="sender_key"
        class="select select-bordered select-sm"
        aria-label="Send the test from"
      >
        <option :for={sender <- @account.senders} value={sender.key}>
          {sender.key} ({sender.address})
        </option>
      </select>
      <input
        :if={length(@account.senders) == 1}
        type="hidden"
        name="sender_key"
        value={hd(@account.senders).key}
      />
      <button type="submit" class="btn btn-sm min-h-11 lg:min-h-8">{@label}</button>
    </form>
    <span :if={@account.senders == []} class="text-xs text-subtle">
      Add a sender to send a test.
    </span>
    """
  end

  attr(:result, :any, required: true)

  defp test_send_result(assigns) do
    ~H"""
    <p
      :if={@result}
      class={[
        "text-sm",
        if(elem(@result, 0) == :error, do: "text-error", else: "text-base-content")
      ]}
      role="status"
      data-role="mail-test-send-result"
    >
      {elem(@result, 1)}
    </p>
    """
  end

  attr(:kind, :string, required: true)
  attr(:label, :string, required: true)
  attr(:account, :any, required: true)
  attr(:replacing, :any, required: true)

  # A Vault-held secret. Configured: the word "Configured" and a Replace
  # control; the stored value is never rendered, not even as dots. Replace
  # (or a new account) shows an empty write-only input.
  defp secret_field(assigns) do
    assigns =
      assign(
        assigns,
        :configured,
        secret_configured?(assigns.account, assigns.kind)
      )

    ~H"""
    <div class="flex flex-col gap-1 text-xs text-subtle">
      <span>{@label}</span>
      <div
        :if={@configured and not MapSet.member?(@replacing, @kind)}
        class="flex items-center gap-2"
      >
        <span class="text-sm text-base-content" data-role="mail-account-secret-status">
          Configured
        </span>
        <span class="text-subtle">stored in the Vault</span>
        <button
          type="button"
          phx-click="replace_secret"
          phx-value-kind={@kind}
          class="btn btn-ghost btn-xs min-h-11 lg:min-h-6"
          data-role="mail-account-secret-replace"
        >
          Replace
        </button>
      </div>
      <input
        :if={not @configured or MapSet.member?(@replacing, @kind)}
        type="password"
        name={"account[#{@kind}_secret]"}
        value=""
        autocomplete="new-password"
        placeholder={if(@configured, do: "New value", else: "Not set")}
        class="input input-bordered input-sm text-base-content"
        aria-label={@label}
        data-role={"mail-account-secret-input-#{@kind}"}
      />
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:field, :atom, required: true)
  attr(:label, :string, required: true)

  # A boolean setting as a labelled checkbox: the state is read from the
  # word next to it, not from colour.
  defp flag_field(assigns) do
    ~H"""
    <label class="flex items-center justify-between gap-2 border-t border-edge py-2 text-sm text-base-content">
      <span>{@label}</span>
      <span class="flex items-center gap-2">
        <span class="text-xs text-subtle">
          {on_off(checked?(@form, @field))}
        </span>
        <input type="hidden" name={"account[#{@field}]"} value="false" />
        <input
          type="checkbox"
          name={"account[#{@field}]"}
          value="true"
          checked={checked?(@form, @field)}
          class="toggle toggle-sm"
          data-role={"mail-account-flag-#{@field}"}
        />
      </span>
    </label>
    """
  end

  # ── View helpers ────────────────────────────────────────────────────────

  defp email_path(assigns, base, extra \\ []) do
    query =
      [
        {"org", if(length(assigns.orgs) > 1, do: assigns.org_id)},
        {"account", assigns.account_filter}
        | extra
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case query do
      [] -> base
      _ -> base <> "?" <> URI.encode_query(query)
    end
  end

  defp tab_path(assigns, tab),
    do: email_path(assigns, "/email", if(tab == "inbox", do: [], else: [{"tab", tab}]))

  defp list_path(assigns), do: tab_path(assigns, assigns.tab)

  defp dispatch_address(%Account{senders: [_ | _] = senders}),
    do: senders |> Enum.map(& &1.address) |> Enum.join(", ")

  defp dispatch_address(%Account{} = account), do: account.username || account.name

  defp account_label(accounts, id) do
    case Enum.find(accounts, &(&1.id == id)) do
      %Account{} = account -> dispatch_address(account)
      nil -> ""
    end
  end

  defp on_off(true), do: "On"
  defp on_off(_), do: "Off"

  defp read_scope_text(%Account{read_folders: folders}) when folders in [nil, []],
    do: "Reading: all folders except Sent, Drafts, Trash, Junk/Spam and All Mail"

  defp read_scope_text(%Account{read_folders: folders}),
    do: "Reading: " <> Enum.join(folders, ", ")

  defp channel_name(nil), do: nil

  defp channel_name(space_id) do
    case Platform.Chat.get_space(space_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp chat_post_path(%{chat_message_id: nil}), do: nil

  defp chat_post_path(%{chat_message_id: message_id, account_id: _}) do
    with %{space_id: space_id} <- Platform.Chat.get_message(message_id),
         %{slug: slug} when is_binary(slug) <- Platform.Chat.get_space(space_id) do
      "/chat/#{slug}?message=#{message_id}"
    else
      _ -> nil
    end
  end

  defp snippet(nil), do: ""

  defp snippet(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 140)
  end

  defp list_time(nil), do: ""

  defp list_time(%DateTime{} = at) do
    if DateTime.to_date(at) == Date.utc_today(),
      do: Calendar.strftime(at, "%H:%M"),
      else: Calendar.strftime(at, "%b %-d")
  end

  defp full_time(nil), do: ""
  defp full_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp secret_configured?(%Account{} = account, "smtp"), do: is_binary(account.smtp_secret_slug)
  defp secret_configured?(%Account{} = account, "imap"), do: is_binary(account.imap_secret_slug)
  defp secret_configured?(_, _), do: false

  defp checked?(form, field), do: to_string(form[field].value) == "true"

  defp rate_text(%Account{} = account) do
    {used, limit} = Dispatch.rate_usage(account)
    "#{used} of #{limit} sends used this hour"
  end

  defp tls_label("tls"), do: "TLS"
  defp tls_label("starttls"), do: "STARTTLS"
  defp tls_label("none"), do: "None"
  defp tls_label(other), do: other

  defp tls_modes, do: Account.tls_modes()
end
