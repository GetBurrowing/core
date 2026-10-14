defmodule PlatformWeb.ChatLive.PrototypeUploadTest do
  @moduledoc """
  The New canvas form's Prototype choice (task 01a1316b-4e46 stage 2), driven
  through the real `ChatLive` mount: hidden when publishing is off or the
  viewer may not publish, and a dropped zip publishes v1 and creates a canvas
  framing it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Prototypes.Prototype
  alias Platform.Repo

  @kind_choice ~s([data-role="new-canvas-kind"])

  setup do
    scratch_storage!("prototype_upload_test")
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    previous = Application.get_env(:platform, :canvas_persist_sync)
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, previous) end)

    n = System.unique_integer([:positive])
    org_id = tenant_org_id("proto-upload-#{n}")
    user = user!("Uploader")
    member!(user, org_id)

    {:ok, space} =
      Chat.create_space(%{
        name: "Proto Upload #{n}",
        slug: "proto-upload-#{n}",
        kind: "channel",
        org_id: org_id
      })

    {:ok, user: user, space: space, org_id: org_id}
  end

  defp open_drawer(conn, user, space) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}", on_error: :warn)
    render_click(view, "canvas_panel_toggle", %{})
    view
  end

  defp zip!(files) do
    entries = Enum.map(files, fn {name, body} -> {String.to_charlist(name), body} end)
    {:ok, {_name, bin}} = :zip.create(~c"bundle.zip", entries, [:memory])
    bin
  end

  test "Prototype is offered to a member when publishing is on", ctx do
    view = open_drawer(ctx.conn, ctx.user, ctx.space)
    assert has_element?(view, "#new-canvas-form")
    assert has_element?(view, @kind_choice)
  end

  test "Prototype is hidden while publishing is off", ctx do
    set_settings!(%{enabled: false})
    view = open_drawer(ctx.conn, ctx.user, ctx.space)

    # Positive control on the same render: the form itself is there.
    assert has_element?(view, "#new-canvas-form")
    refute has_element?(view, @kind_choice)
  end

  test "Prototype is hidden when the policy does not admit the viewer", ctx do
    set_settings!(%{who_may_publish: "agents_only"})
    view = open_drawer(ctx.conn, ctx.user, ctx.space)

    assert has_element?(view, "#new-canvas-form")
    refute has_element?(view, @kind_choice)
  end

  test "dropping a zip publishes v1 and creates a canvas framing it", ctx do
    view = open_drawer(ctx.conn, ctx.user, ctx.space)

    view
    |> form("#new-canvas-form", %{"canvas" => %{"kind" => "prototype"}})
    |> render_change()

    assert has_element?(view, ~s([data-role="prototype-drop"]))

    zip = zip!([{"index.html", "<p>hello</p>"}, {"app.js", "1;"}])

    view
    |> file_input("#new-canvas-form", :prototype_bundle, [
      %{name: "checkout.zip", content: zip, type: "application/zip"}
    ])
    |> render_upload("checkout.zip")

    html =
      view
      |> form("#new-canvas-form", %{"canvas" => %{"kind" => "prototype", "title" => "Checkout"}})
      |> render_submit()

    assert [%Prototype{} = p] = Repo.all(Prototype) |> Enum.filter(&(&1.org_id == ctx.org_id))
    assert p.name == "Checkout"
    assert p.latest_version == 1
    assert p.space_id == ctx.space.id

    assert html =~ "Published Checkout v1 · "

    [canvas] = Chat.list_canvases(ctx.space.id)
    [child] = canvas.document["root"]["children"]
    assert child["type"] == "prototype"
    assert child["props"] == %{"prototype_id" => p.id}

    # The canvas opened in the panel frames v1.
    assert render(view) =~ ~s(src="/proto/#{p.id}/1/")
  end
end
