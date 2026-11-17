defmodule PlatformWeb.Chat.CanvasHooksShowrunnerTest do
  @moduledoc """
  The episode board's Needs-you option buttons, clicked in chat (task
  01a1eaf6 stage 4 review fix).

  `Platform.Chat.Canvas.Kinds.NeedsYou` (stage 2) renders each option as a
  `canvas_action_click` whose value is `"<item id>:<option>"`. Before this fix
  ChatLive only emitted that click as a canvas event, which nothing on the
  showrunner side consumed, so the button did nothing. The click is now
  routed to `Platform.Showrunner.answer/4`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ShowrunnerResearchBrief, as: Brief
  alias Platform.Responsibilities.Handlers.ShowrunnerRunSheet, as: RunSheet
  alias Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch, as: Pitch
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Config
  alias Platform.Tenancy

  @topics [
    %{"title" => "Where automation savings go", "angle" => "a", "why_now" => "w"},
    %{"title" => "The 3% rule for backups", "angle" => "a", "why_now" => "w"},
    %{"title" => "Why printers still jam", "angle" => "a", "why_now" => "w"}
  ]

  setup do
    :ok = Seeds.seed_defaults(only_keys: ["showrunner"])
    org = Tenancy.get_org_by_slug!("globex")

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "showrunner-#{System.unique_integer([:positive])}",
        name: "Showrunner",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role("showrunner", agent.id)

    producer = create_user!()
    plain_member!(producer, org)
    bystander = create_user!()
    plain_member!(bystander, org)

    space = channel!(%{org_id: org.id, name: "How to Computer"})
    add_user!(space.id, producer.id)
    add_user!(space.id, bystander.id)

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        joined_at: DateTime.utc_now()
      })

    rows =
      for handler <- [Pitch, Brief, RunSheet], into: %{} do
        [spec] = handler.register()
        {:ok, row} = Responsibilities.upsert_by_key(spec)

        {:ok, config} =
          Config.to_trigger(row.trigger_config, %{
            space_id: space.id,
            escalate_user_id: producer.id
          })

        {:ok, row} = Responsibilities.update_responsibility(row, %{trigger_config: config})
        {handler, row}
      end

    assert :ok = Pitch.handle_output(rows[Pitch], %{"topics" => @topics}, %{})
    canvas = Board.current(space.id)
    on_exit(fn -> CanvasServer.stop(canvas.id) end)

    %{producer: producer, bystander: bystander, space: space, canvas: canvas}
  end

  defp mount!(user, space) do
    {:ok, view, _html} = live(login(build_conn(), user.id), ~p"/chat/#{space.id}")
    view
  end

  defp click(view, canvas, value) do
    render_click(view, "canvas_action_click", %{
      "node-id" => "needs_you",
      "canvas-id" => canvas.id,
      "action" => value
    })
  end

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  defp open_pick_rows(user) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and is_nil(i.dismissed_at) and
            i.title == "Showrunner needs you: Pick this topic"
      )
    )
  end

  test "the producer's click on a topic picks it: rail to Research, item and inbox row cleared",
       ctx do
    assert [_] = open_pick_rows(ctx.producer)
    view = mount!(ctx.producer, ctx.space)

    click(view, ctx.canvas, "pick-topic:The 3% rule for backups")

    assert {:ok, episode, _} = Board.read(ctx.canvas)
    assert episode.title == "The 3% rule for backups"
    assert episode.stage == :research
    assert episode.needs_you == []
    assert open_pick_rows(ctx.producer) == []
  end

  test "someone who is not the show's producer cannot answer", ctx do
    view = mount!(ctx.bystander, ctx.space)

    click(view, ctx.canvas, "pick-topic:The 3% rule for backups")

    assert flash(view)["error"] =~ "producer"
    assert {:ok, episode, _} = Board.read(ctx.canvas)
    assert episode.stage == :pitch
    assert [%{id: "pick-topic"}] = episode.needs_you
  end

  test "an option that is not on the item changes nothing", ctx do
    view = mount!(ctx.producer, ctx.space)

    click(view, ctx.canvas, "pick-topic:Something else entirely")

    assert {:ok, episode, _} = Board.read(ctx.canvas)
    assert episode.stage == :pitch
    assert [%{id: "pick-topic"}] = episode.needs_you
  end
end
