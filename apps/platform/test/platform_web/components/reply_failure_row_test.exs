defmodule PlatformWeb.Components.ReplyFailureRowTest do
  @moduledoc """
  The reply-failure chat row (task 01a10322 stage 4): a system row, not a
  bubble, whose action depends on who is reading. A viewer
  `NativeAgents.can_manage?/2` admits sees the cause's action, linking to the
  agent on Agent Resources; anyone else reads the hand-off line.

  Mutants these name:

    * render the action for every viewer → the non-manager case fails;
    * route the notice through the ordinary bubble → the dispatch case fails
      (no `data-role="reply-failure"`, a hover toolbar present).
  """
  use Platform.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.NativeAgents
  alias Platform.Chat.ReplyFailure
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.ReplyFailureRow

  defp user!(label, role) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "rf-row-#{label}-#{n}@example.com",
        name: "RF #{label} #{n}",
        oidc_sub: "oidc-rf-row-#{label}-#{n}"
      })

    if role do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.acme_org_id(),
        role: role
      })
      |> Repo.insert!()
    end

    user
  end

  defp notice(agent, cause) do
    cause_atom = String.to_existing_atom(cause)

    %{
      id: Ecto.UUID.generate(),
      space_id: Ecto.UUID.generate(),
      participant_id: "p-system",
      content:
        ReplyFailure.headline(agent.name) <>
          "\n" <> ReplyFailure.cause_line(cause_atom, agent.name),
      content_type: "system",
      canvas_id: nil,
      inserted_at: ~U[2026-10-09 10:00:00.000000Z],
      day_label: nil,
      reactions: [],
      versions_count: 1,
      corrects_message_id: nil,
      metadata: %{
        "kind" => "reply_failure",
        "agent_id" => agent.id,
        "message_id" => Ecto.UUID.generate(),
        "cause" => cause
      }
    }
  end

  defp row_html(msg, viewer) do
    render_component(&ReplyFailureRow.row/1, msg: msg, viewer_user_id: viewer && viewer.id)
  end

  setup do
    owner = user!("owner", "member")
    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: "Ada", harness: "claude_code"})
    %{owner: owner, agent: agent}
  end

  test "a manager sees the action matching each cause", %{owner: owner, agent: agent} do
    for {cause, label, line2} <- [
          {"needs_login", "Log in", "Ada's Claude login has expired."},
          {"stopped", "Start Ada", "Ada is stopped."},
          {"crashed", "Restart Ada", "Ada stopped unexpectedly while replying."},
          # Stage 7 round 2: a NATIVE agent's unknown cause (the no-reply
          # watchdog's) offers Restart, which the install can do. The canvas's
          # "Open Ada" stays for agents Suite cannot restart.
          {"unknown", "Restart Ada", "Something went wrong before Ada could reply."}
        ] do
      doc = notice(agent, cause) |> row_html(owner) |> LazyHTML.from_fragment()

      assert LazyHTML.text(doc) =~ "Ada couldn't reply to this message."
      assert LazyHTML.text(doc) =~ line2

      [action] = doc |> LazyHTML.query(~s([data-role="reply-failure-action"])) |> Enum.to_list()
      assert String.trim(LazyHTML.text(action)) == label
      assert LazyHTML.attribute(action, "href") == ["/control/#{agent.slug}"]
      assert doc |> LazyHTML.query(~s([data-role="reply-failure-handoff"])) |> Enum.empty?()
    end
  end

  test "an admin who does not own the agent is a manager too", %{agent: agent} do
    admin = user!("admin", "admin")
    html = row_html(notice(agent, "stopped"), admin)
    assert html =~ ~s(data-role="reply-failure-action")
  end

  test "a non-manager reads the hand-off line, with no action", %{agent: agent} do
    other = user!("other", "member")

    for viewer <- [other, nil] do
      doc = notice(agent, "stopped") |> row_html(viewer) |> LazyHTML.from_fragment()

      assert LazyHTML.text(doc) =~ "Ada couldn't reply to this message."

      assert LazyHTML.text(doc) =~
               "Someone who manages Ada can fix this in Agent Resources."

      assert doc |> LazyHTML.query(~s([data-role="reply-failure-action"])) |> Enum.empty?()
    end
  end

  test "the row is the canvas's system row: dimmed avatar, error icon, error tint", %{
    owner: owner,
    agent: agent
  } do
    doc = notice(agent, "crashed") |> row_html(owner) |> LazyHTML.from_fragment()

    [row] = doc |> LazyHTML.query(~s([data-role="reply-failure"])) |> Enum.to_list()
    class = row |> LazyHTML.attribute("class") |> hd()
    assert class =~ "rounded-box"
    assert class =~ "bg-error/10"
    refute doc |> LazyHTML.query(".opacity-50") |> Enum.empty?()
    refute doc |> LazyHTML.query(".hero-exclamation-circle.text-error") |> Enum.empty?()
  end

  test "ChatMessage renders a notice as the system row, not a bubble", %{
    owner: owner,
    agent: agent
  } do
    assigns = %{msg: notice(agent, "stopped"), viewer: owner.id}

    html =
      rendered_to_string(~H"""
      <PlatformWeb.Components.ChatMessage.chat_message
        dom_id="row-1"
        msg={@msg}
        current_participant={nil}
        agent_participant_ids={MapSet.new()}
        agent_colors_map={%{}}
        participants_map={%{}}
        quick_emojis={[]}
        pinned_message_ids={MapSet.new()}
        canvases_by_id={%{}}
        attachments_map={%{}}
        thread_previews={%{}}
        expanded_threads={MapSet.new()}
        inline_thread_messages={%{}}
        viewer_user_id={@viewer}
      />
      """)

    assert html =~ ~s(id="row-1")
    assert html =~ ~s(data-role="reply-failure")
    assert html =~ "Start Ada"
    refute html =~ "message-row-inner"
  end
end
