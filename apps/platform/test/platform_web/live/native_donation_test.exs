defmodule PlatformWeb.NativeDonationTest do
  @moduledoc """
  Task 01a111bb stage 2: the web donation bridge. Each call site pushes
  `native_donate` with ids only, and no payload carries a text, content,
  title, body or name key.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Project
  alias PlatformWeb.NativeDonation

  @forbidden_keys ~w(text content title body name message question note feedback)

  defp u, do: System.unique_integer([:positive])

  defp user!(name) do
    Repo.insert!(%User{
      email: "donate-#{u()}@example.com",
      name: "#{name} #{u()}",
      oidc_sub: "oidc-donate-#{u()}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp assert_ids_only(payload, sentinel) do
    keys = payload |> Map.keys() |> Enum.map(&to_string/1)

    for key <- @forbidden_keys do
      refute key in keys, "donation payload carries #{key}: #{inspect(payload)}"
    end

    refute inspect(payload) =~ sentinel
  end

  describe "NativeDonation.payload/2" do
    test "keeps only the kind's id keys, whatever the caller passes" do
      payload =
        NativeDonation.payload("message_sent", %{
          space_id: "s",
          recipient_ids: [],
          content: "secret",
          title: "t"
        })

      assert payload == %{kind: "message_sent", space_id: "s", recipient_ids: []}
    end

    test "no kind allows a content-bearing key" do
      for kind <- NativeDonation.kinds(), key <- NativeDonation.allowed_keys(kind) do
        refute to_string(key) in @forbidden_keys, "#{kind} allows #{key}"
      end
    end
  end

  describe "message_sent" do
    test "a DM send donates the space and the other person, never the text", %{conn: conn} do
      me = user!("Sender")
      other = user!("Recipient")
      {:ok, dm} = Chat.find_or_create_dm(me.id, "user", other.id)

      {:ok, view, _html} = live(login(conn, me), ~p"/chat/#{dm.id}")
      sentinel = "zq-sentinel-#{u()}"

      view |> form("#compose-form", compose: %{text: sentinel}) |> render_submit()

      assert_push_event(view, "native_donate", payload)
      assert payload.kind == "message_sent"
      assert payload.space_id == dm.id
      assert payload.recipient_ids == [%{type: "user", id: other.id}]
      assert_ids_only(payload, sentinel)
    end

    test "a channel send donates the space with no recipients", %{conn: conn} do
      me = user!("Channel Sender")
      n = u()
      {:ok, channel} = Chat.create_space(%{name: "Donate #{n}", slug: "donate-#{n}"})

      {:ok, _} =
        Chat.add_participant(channel.id, %{
          participant_type: "user",
          participant_id: me.id,
          joined_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(login(conn, me), ~p"/chat/#{channel.slug}")
      view |> form("#compose-form", compose: %{text: "hello channel"}) |> render_submit()

      assert_push_event(view, "native_donate", payload)
      assert payload == %{kind: "message_sent", space_id: channel.id, recipient_ids: []}
    end
  end

  describe "task_created" do
    test "the New Task sheet donates the task and project ids", %{conn: conn} do
      me = user!("Filer")
      {:ok, project} = Tasks.create_project(%{name: "Donate Project #{u()}"})
      {:ok, view, _html} = live(login(conn, me), ~p"/tasks")
      title = "Donated task #{u()}"

      view
      |> with_target("#tasks-create")
      |> render_submit("taskcreate_submit", %{
        "task" => %{
          "title" => title,
          "project_id" => project.id,
          "what" => "zq-what",
          "why" => "zq-why",
          "action" => "create",
          "deploy_target" => "",
          "epic_id" => ""
        }
      })

      task = project.id |> Tasks.list_tasks_by_project() |> Enum.find(&(&1.title == title))
      assert_push_event(view, "native_donate", payload)
      assert payload == %{kind: "task_created", task_id: task.id, project_id: project.id}
      assert_ids_only(payload, "zq-what")
    end
  end

  describe "approval_acted" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Donate Approvals #{u()}"})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Approve me #{u()}", status: "planning"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, plan} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
      %{task: task, plan: plan}
    end

    test "approve donates the task id and the action", %{conn: conn, task: task, plan: plan} do
      {:ok, view, _html} = live(login(conn, user!("Approver")), ~p"/tasks/#{task.id}")

      view
      |> element(~s{button[phx-click="plan_approve"][phx-value-plan-id="#{plan.id}"]})
      |> render_click()

      assert Repo.get!(Plan, plan.id).status == "approved"
      assert_push_event(view, "native_donate", payload)
      assert payload == %{kind: "approval_acted", task_id: task.id, action: "approve"}
    end

    test "reject with feedback donates the action and never the feedback", %{
      conn: conn,
      task: task,
      plan: plan
    } do
      {:ok, view, _html} = live(login(conn, user!("Rejecter")), ~p"/tasks/#{task.id}")
      sentinel = "zq-feedback-#{u()}"

      view
      |> element(~s{button[phx-click="plan_toggle_reject_feedback"][phx-value-plan-id="#{plan.id}"]})
      |> render_click()

      view
      |> element(~s{textarea[phx-keyup="plan_update_reject_feedback_text"]})
      |> render_keyup(%{"value" => sentinel})

      view
      |> element(
        ~s{button[phx-click="plan_submit_reject_with_feedback"][phx-value-plan-id="#{plan.id}"]}
      )
      |> render_click()

      assert Repo.get!(Plan, plan.id).status == "rejected"
      assert_push_event(view, "native_donate", payload)
      assert payload == %{kind: "approval_acted", task_id: task.id, action: "reject"}
      assert_ids_only(payload, sentinel)
    end
  end

  describe "meeting_started" do
    test "Meet now donates the meeting id only", %{conn: conn} do
      me = user!("Meeter")

      {:ok, _project} =
        %Project{}
        |> Project.changeset(%{
          name: "Donate Meet #{u()}",
          slug: "donate-meet-#{u()}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
        |> Repo.insert()

      {:ok, view, _html} = live(login(conn, me), ~p"/meetings")
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
      _ = render_click(view, "meet_now", %{})

      meeting = Repo.one!(Meeting)
      assert_push_event(view, "native_donate", payload)
      assert payload == %{kind: "meeting_started", meeting_id: meeting.id}
    end
  end
end
