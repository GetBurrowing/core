defmodule PlatformWeb.ControlCenter.ExternalAgentVoiceTest do
  @moduledoc """
  Task 01a06dff — a per-agent voice was unreachable for every agent that has
  one.

  The voice controls lived only in `AgentDetail.config_form/1`, which
  `control_center_live.ex` renders under `runtime_type != "external"`. Every
  external agent therefore had a `voice_config` column that nothing in the UI
  could write. `agent_voice_config_test.exs` covers the same round-trip and
  passes TODAY against a built-in agent — it is completely blind to this bug,
  which is why every case here PINS `runtime_type: "external"`.

  Mutants these name:

  * Restore a `runtime_type != "external"` guard around the voice card, or
    drop `<.voice_card>` from `federation_panels/1` → "the voice card renders
    for an external agent" and the round-trip case both fail.
  * Wire the effective-voice line to `@config_form` instead of
    `Voice.config_for(@agent)` → "the effective-voice line reads the stored
    row, not the form" fails: it asserts the line still says the fallback
    sentence while an unsaved voice id sits in the form.
  * Move the voice inputs into their own `<form phx-submit="save_config">` →
    "a voice save leaves the rest of the config alone" fails, because
    `config_attrs_from_params/2` has no agent fallback for `color`.
  * Flip the condition the wrong way and hide voice from built-ins → the
    built-in case fails.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, Voice}
  alias Platform.Repo

  @voice_id "JBFqnCBsd6RMkjVDRZzb"

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "ext_voice_#{System.unique_integer([:positive])}@example.com",
        name: "External Voice User",
        oidc_sub: "oidc-ext-voice-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "ext-voice-agent-#{System.unique_integer([:positive, :monotonic])}",
          name: "External Voice Agent",
          status: "active"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # A colour and a display name that are BOTH non-blank, so a save that blanks
  # unrelated config is detectable rather than invisible.
  defp create_external_agent(attrs \\ %{}) do
    create_agent(Map.merge(%{runtime_type: "external", color: "teal"}, attrs))
  end

  describe "the voice card on the external branch" do
    test "renders for an agent whose runtime_type is external", %{conn: conn} do
      agent = create_external_agent()
      assert agent.runtime_type == "external"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      assert has_element?(view, ~s{[data-role="agent-voice-card"]})

      # And the controls are inside the identity form, not a second form of
      # their own — that is what carries name and colour along with the voice.
      assert has_element?(
               view,
               ~s{#federated-identity-form select[name="config[voice_provider]"]}
             )

      assert has_element?(view, ~s{#federated-identity-form input[name="config[voice_id]"]})
      assert has_element?(view, ~s{#federated-identity-form input[name="config[voice_model]"]})
    end

    test "a voice set through the external form round-trips to the stored row", %{conn: conn} do
      agent = create_external_agent()
      assert agent.voice_config == %{}

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      html =
        view
        |> form("#federated-identity-form",
          config: %{voice_provider: "elevenlabs", voice_id: @voice_id}
        )
        |> render_submit()

      assert html =~ "Updated #{agent.name}"

      updated = Repo.get!(Agent, agent.id)

      assert updated.voice_config == %{
               "provider" => "elevenlabs",
               "voice_id" => @voice_id
             }

      # Through the seam the dispatcher reads, not just as a raw jsonb blob.
      assert Voice.config_for(updated) == %{
               "provider" => "elevenlabs",
               "voice_id" => @voice_id
             }
    end

    test "a voice save leaves the agent's name, colour and status alone", %{conn: conn} do
      agent = create_external_agent(%{name: "Octavius", color: "teal", status: "active"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> form("#federated-identity-form",
        config: %{voice_provider: "elevenlabs", voice_id: @voice_id}
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)

      # The whole reason the voice inputs live in `federated-identity-form`:
      # `AgentData.config_attrs_from_params/2` rebuilds the FULL attrs map and
      # `color` has no fallback to the stored agent, so a voice-only form
      # would blank it and the operator would read that as the avatar
      # breaking.
      assert updated.color == "teal"
      assert updated.name == "Octavius"
      assert updated.status == "active"
      assert Voice.config_for(updated)["voice_id"] == @voice_id
    end

    test "the effective-voice line reads the stored row, not the form", %{conn: conn} do
      agent = create_external_agent()

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

      assert html =~ "Using the shared fallback voice"

      # Type a voice into the form WITHOUT saving. A line wired to form state
      # would already claim the agent speaks with it — which is exactly the
      # bug class this ticket came from: a form that can only echo itself back
      # can never tell you whether the save landed.
      changed =
        view
        |> form("#federated-identity-form",
          config: %{voice_provider: "elevenlabs", voice_id: @voice_id}
        )
        |> render_change()

      assert changed =~ "Using the shared fallback voice"
      refute effective_line(changed) =~ @voice_id

      # Now save, and the same line switches — because the row changed.
      view
      |> form("#federated-identity-form",
        config: %{voice_provider: "elevenlabs", voice_id: @voice_id}
      )
      |> render_submit()

      saved = render(view)
      line = effective_line(saved)

      assert line =~ "Speaking as"
      assert line =~ @voice_id
      assert line =~ "elevenlabs"
      refute saved =~ "Using the shared fallback voice"
    end

    test "the stored state renders on first mount, with the id in mono", %{conn: conn} do
      agent =
        create_external_agent(%{
          voice_config: %{"provider" => "elevenlabs", "voice_id" => @voice_id}
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

      assert effective_line(html) =~ @voice_id

      # An opaque token that gets compared character by character, so it is
      # mono and it wraps rather than truncating.
      id_classes =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s{[data-role="agent-voice-effective-id"]})
        |> LazyHTML.attribute("class")
        |> List.first()

      assert id_classes =~ "font-mono"
      assert id_classes =~ "break-all"
      refute id_classes =~ "truncate"
    end

    test "a provider with a blank voice id warns instead of failing silently", %{conn: conn} do
      agent = create_external_agent()

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      changed =
        view
        |> form("#federated-identity-form", config: %{voice_provider: "elevenlabs", voice_id: ""})
        |> render_change()

      assert changed =~ "A provider without a voice id saves as no voice at all"
      assert has_element?(view, ~s{[data-role="agent-voice-half-set"]})

      # Amber is spent here and only here. The unset state above is the normal
      # permanent condition for most agents and stays informational.
      assert effective_line(changed) =~ "Using the shared fallback voice"
    end

    test "the help line names where the id comes from", %{conn: conn} do
      agent = create_external_agent()

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

      assert html =~ "Paste the id from ElevenLabs. Both fields or neither."
    end
  end

  describe "the built-in surface" do
    # Present so a fix that flips the condition the wrong way — voice for
    # external agents, hidden from built-ins — is caught rather than shipped.
    test "a built-in agent still gets its voice controls in the config form", %{conn: conn} do
      agent = create_agent(%{name: "Built In", color: "blue"})
      refute agent.runtime_type == "external"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      assert has_element?(view, ~s{#agent-config-form select[name="config[voice_provider]"]})
      assert has_element?(view, ~s{#agent-config-form input[name="config[voice_id]"]})
      assert has_element?(view, ~s{#agent-config-form input[name="config[voice_model]"]})

      view
      |> form("#agent-config-form",
        config: %{name: agent.name, voice_provider: "elevenlabs", voice_id: @voice_id}
      )
      |> render_submit()

      assert Voice.config_for(Repo.get!(Agent, agent.id))["voice_id"] == @voice_id
    end
  end

  # `LazyHTML.query/2` descends the whole tree; scoping to the effective line
  # keeps "the id appears somewhere on the page" — it is also in the input's
  # value attribute — from passing for "the line reads it back".
  defp effective_line(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s{[data-role="agent-voice-effective"]})
    |> LazyHTML.text()
  end
end
