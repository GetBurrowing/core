defmodule PlatformWeb.ControlCenter.AgentVoiceConfigTest do
  @moduledoc """
  Task 01a03f4f — the per-agent voice must be SETTABLE by a human, not only
  by a migration or an iex session.

  A config field nobody can reach is the other way this feature fails
  quietly, so these drive the real Control Center form through
  `render_submit/1` rather than calling `config_attrs_from_params/2`
  directly.

  Mutants these name:

  * Drop `voice_config: voice_config_from_params(params)` from
    `AgentData.config_attrs_from_params/2` → the round-trip test fails, the
    stored config staying `%{}`.
  * Drop the `voice_provider`/`voice_id` keys from
    `AgentData.build_config_form/2` → the "form is populated from the stored
    row" test fails, because the inputs render empty.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.{Agent, Voice}
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user = Platform.TenancyFixtures.root_admin!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "voice-cfg-agent-#{System.unique_integer([:positive, :monotonic])}",
          name: "Voice Config Agent",
          status: "active"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "a voice is settable from the agent config form", %{conn: conn} do
    agent = create_agent()
    assert agent.voice_config == %{}

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      view
      |> form("#agent-config-form",
        config: %{
          name: agent.name,
          status: "active",
          voice_provider: "elevenlabs",
          voice_id: "21m00Tcm4TlvDq8ikWAM",
          voice_model: "eleven_turbo_v2_5"
        }
      )
      |> render_submit()

    assert html =~ "Updated #{agent.name}"

    updated = Repo.get!(Agent, agent.id)

    assert updated.voice_config == %{
             "provider" => "elevenlabs",
             "voice_id" => "21m00Tcm4TlvDq8ikWAM",
             "model" => "eleven_turbo_v2_5"
           }

    # And it resolves through the seam the dispatcher reads, not just as a
    # raw jsonb blob.
    assert Voice.config_for(updated)["voice_id"] == "21m00Tcm4TlvDq8ikWAM"
  end

  test "the form is populated from the stored row, so an existing voice survives an unrelated save",
       %{conn: conn} do
    agent =
      create_agent(%{
        voice_config: %{"provider" => "openai", "voice_id" => "alloy"}
      })

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

    # Rendered into the inputs — this is what makes the save below carry the
    # voice forward without the test restating it.
    assert html =~ "alloy"

    # A save that changes ONLY the name. `form/3` submits the rendered
    # inputs, exactly as a browser would.
    view
    |> form("#agent-config-form", config: %{name: "Renamed"})
    |> render_submit()

    updated = Repo.get!(Agent, agent.id)
    assert updated.name == "Renamed"
    assert updated.voice_config == %{"provider" => "openai", "voice_id" => "alloy"}
  end

  test "clearing the voice id clears the whole selection rather than persisting a half-set one",
       %{conn: conn} do
    agent =
      create_agent(%{voice_config: %{"provider" => "elevenlabs", "voice_id" => "abc"}})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    view
    |> form("#agent-config-form",
      config: %{name: agent.name, voice_provider: "elevenlabs", voice_id: ""}
    )
    |> render_submit()

    updated = Repo.get!(Agent, agent.id)

    # Not %{"provider" => "elevenlabs"} — that is precisely the shape
    # Voice.validate_config/1 rejects, which would make an empty text box an
    # unsaveable form.
    assert updated.voice_config == %{}
  end

  test "the provider control offers every known provider and no hard-coded vendor list", %{
    conn: conn
  } do
    agent = create_agent()
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    doc = LazyHTML.from_document(html)

    options =
      doc
      |> LazyHTML.query(~s{select[name="config[voice_provider]"] option})
      |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first()))

    # The blank "No voice" option plus one per known provider.
    assert "" in options

    for provider <- Voice.known_providers() do
      assert provider in options,
             "#{provider} is in Voice.known_providers/0 but not offered by the form"
    end
  end
end
