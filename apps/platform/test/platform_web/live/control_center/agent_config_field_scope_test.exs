defmodule PlatformWeb.ControlCenter.AgentConfigFieldScopeTest do
  @moduledoc """
  Task 01a06e25 — saving the external agent form wiped `model_config["primary"]`,
  `model_config["fallbacks"]` and `thinking_default`.

  `AgentData.config_attrs_from_params/2` rebuilds the FULL attrs map from the
  submitted params. `name`, `status`, `max_concurrent` and `sandbox_mode` all
  fall back to the stored agent when their param is absent; those three did
  not — `Map.put/3` was unconditional with a `""` default, and
  `thinking_default` went through `blank_to_nil/1`. The external panel's
  `federated-identity-form` carries none of the three (they live only inside
  `AgentDetail.config_form/1`, the built-in branch), so every external save
  overwrote them.

  The two surfaces mean OPPOSITE things by an absent param: on the built-in
  form absent means "the human cleared the box", on the external form it means
  "this form does not edit that field". The fix keys off the same fact that
  decides which form renders at all — `agent.runtime_type == "external"` in
  `control_center_live.ex` — so the branch here and the branch there cannot
  drift apart.

  Anti-vacuity: every external fixture starts with a NON-EMPTY `model_config`
  and a non-nil `thinking_default`. An empty-`model_config` fixture is the
  state nearly every external agent happens to be in, and is exactly why this
  went unnoticed — such a fixture makes these assertions pass against the
  broken code.

  Mutants these name:

  * Make the external path preserve nothing (drop the `runtime_type` branch
    from `config_attrs_from_params/2`) → the three-field survival cases go RED.
  * Make the built-in path preserve on blank (apply the external branch to
    every agent) → "clearing primary_model on the built-in form still clears
    it" goes RED. A fix that turns a real clear into a no-op is not a fix.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "cfg_scope_#{System.unique_integer([:positive])}@example.com",
        name: "Config Scope User",
        oidc_sub: "oidc-cfg-scope-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "cfg-scope-agent-#{System.unique_integer([:positive, :monotonic])}",
          name: "Config Scope Agent",
          status: "active"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # Populated routing, a populated thinking default, and a colour — so a save
  # that drops any of them is detectable rather than invisible.
  defp create_routed_external_agent(attrs \\ %{}) do
    create_agent(
      Map.merge(
        %{
          runtime_type: "external",
          color: "teal",
          thinking_default: "think",
          model_config: %{
            "primary" => "claude-opus-4",
            "fallbacks" => ["claude-sonnet-4", "gpt-4o"]
          }
        },
        attrs
      )
    )
  end

  defp assert_routing_intact(%Agent{} = agent) do
    assert agent.thinking_default == "think"
    assert agent.model_config["primary"] == "claude-opus-4"
    assert agent.model_config["fallbacks"] == ["claude-sonnet-4", "gpt-4o"]
  end

  describe "the external identity form does not edit model routing" do
    test "none of the three fields is even present on that form", %{conn: conn} do
      agent = create_routed_external_agent()

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      # This is the PREMISE of the whole ticket, pinned: the params of an
      # external submit cannot carry these, so an absent param can never mean
      # "the human cleared it". If someone later adds the inputs, this fails
      # and the preservation branch below needs revisiting rather than
      # silently becoming wrong.
      refute has_element?(view, ~s{#federated-identity-form [name="config[primary_model]"]})
      refute has_element?(view, ~s{#federated-identity-form [name="config[fallback_models]"]})
      refute has_element?(view, ~s{#federated-identity-form [name="config[thinking_default]"]})

      # And the fields that ARE editable there, so this is not just an
      # everything-is-missing assertion passing on a blank page.
      assert has_element?(view, ~s{#federated-identity-form [name="config[name]"]})
      assert has_element?(view, ~s{#federated-identity-form [name="config[color]"]})
    end

    test "an identity save preserves primary, fallbacks and thinking_default", %{conn: conn} do
      agent = create_routed_external_agent(%{name: "Octavius"})
      assert_routing_intact(agent)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      html =
        view
        |> form("#federated-identity-form", config: %{name: "Orion"})
        |> render_submit()

      assert html =~ "Updated Orion"

      updated = Repo.get!(Agent, agent.id)

      # The edit the human actually made landed...
      assert updated.name == "Orion"
      # ...and nothing they could not see from that screen was touched.
      assert_routing_intact(updated)
    end

    test "a voice-only save preserves primary, fallbacks and thinking_default", %{conn: conn} do
      agent = create_routed_external_agent()

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> form("#federated-identity-form",
        config: %{voice_provider: "elevenlabs", voice_id: "JBFqnCBsd6RMkjVDRZzb"}
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)

      assert updated.voice_config["voice_id"] == "JBFqnCBsd6RMkjVDRZzb"
      assert_routing_intact(updated)
    end

    test "keys beside primary and fallbacks survive an external save too", %{conn: conn} do
      agent =
        create_routed_external_agent(%{
          model_config: %{
            "primary" => "claude-opus-4",
            "fallbacks" => ["gpt-4o"],
            "temperature" => 0.4
          }
        })

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> form("#federated-identity-form", config: %{name: "Orion"})
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)

      assert updated.model_config == %{
               "primary" => "claude-opus-4",
               "fallbacks" => ["gpt-4o"],
               "temperature" => 0.4
             }
    end
  end

  describe "the built-in form still means it when a box is cleared" do
    test "clearing primary_model, fallbacks and thinking_default clears them", %{conn: conn} do
      agent =
        create_agent(%{
          runtime_type: "built_in",
          thinking_default: "think",
          model_config: %{"primary" => "claude-opus-4", "fallbacks" => ["gpt-4o"]}
        })

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> form("#agent-config-form",
        config: %{primary_model: "", fallback_models: "", thinking_default: ""}
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)

      # Here the params ARE the intent: a blank box means "clear it". A fix
      # that preserves on blank everywhere would turn this into a no-op.
      assert updated.model_config["primary"] == ""
      assert updated.model_config["fallbacks"] == []
      assert is_nil(updated.thinking_default)
    end

    test "a populated built-in save still writes what was typed", %{conn: conn} do
      agent = create_agent(%{runtime_type: "built_in"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      view
      |> form("#agent-config-form",
        config: %{
          primary_model: "claude-sonnet-4",
          fallback_models: "gpt-4o, gpt-4o-mini",
          thinking_default: "think_hard"
        }
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)

      assert updated.model_config["primary"] == "claude-sonnet-4"
      assert updated.model_config["fallbacks"] == ["gpt-4o", "gpt-4o-mini"]
      assert updated.thinking_default == "think_hard"
    end
  end
end
