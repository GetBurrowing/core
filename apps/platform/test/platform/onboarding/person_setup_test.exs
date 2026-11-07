defmodule Platform.Onboarding.PersonSetupTest do
  @moduledoc """
  The person setup checklist, task 01a1b6de stage 2. Each step flips only on
  its own real row; an API-key connection never marks the AI login done; the
  stuck threshold is data and is respected.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.AgentHost.State
  alias Platform.Agents.{NativeAgents, NativeLogin}
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Mobile
  alias Platform.Onboarding.{MemberWelcome, PersonSetup}
  alias Platform.Push
  alias Platform.Repo

  @day 24 * 60 * 60

  setup do
    State.init_table()
    :ok
  end

  defp user!(label \\ "member") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ps-#{label}-#{n}@example.com",
      name: "Person #{label} #{n}",
      oidc_sub: "oidc-ps-#{label}-#{n}"
    })
  end

  defp sign_in!(user, event_type \\ "platform.auth.external_admission", action \\ "full") do
    {:ok, event} =
      Audit.record(%{
        event_type: event_type,
        actor_id: user.id,
        actor_type: "user",
        action: action,
        resource_type: "session",
        resource_id: user.id
      })

    event.inserted_at
  end

  defp state(status, step) do
    Enum.find_value(status.steps, fn %{step: s, state: state} -> s == step && state end)
  end

  defp states(user, opts \\ []) do
    status = PersonSetup.status(user, Keyword.put_new(opts, :stuck_after_seconds, nil))
    Map.new(status.steps, &{&1.step, &1.state})
  end

  defp dm_space!(user) do
    space = Repo.insert!(%Space{kind: "dm", is_direct: true, name: nil})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {space, participant}
  end

  defp channel!(user) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Channel #{n}",
        slug: "ps-channel-#{n}",
        kind: "channel",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp native_agent!(owner, name, harness) do
    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: name, harness: harness})

    on_exit(fn ->
      if :ets.whereis(State.table()) != :undefined, do: :ets.delete(State.table(), agent.id)
    end)

    agent
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_session!(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)

    {:ok, %{session: session}} =
      Mobile.exchange_code(code, verifier, %{app_install_id: "install-1", device_name: "Phone"})

    session
  end

  test "the steps are walked in this order" do
    assert PersonSetup.steps() ==
             [:signed_in, :notifications, :phone_app, :ai_login, :channels, :who_to_ask]
  end

  test "a brand new user row has every step open and the phone app unknown" do
    user = user!()

    assert states(user) == %{
             signed_in: :todo,
             notifications: :todo,
             phone_app: :unknown,
             ai_login: :todo,
             channels: :todo,
             who_to_ask: :todo
           }

    assert %{next: :signed_in, complete?: false, first_sign_in_at: nil} =
             PersonSetup.status(user, stuck_after_seconds: nil)
  end

  test "an unknown or malformed id has no checklist" do
    assert PersonSetup.status(Ecto.UUID.generate()) == nil
    assert PersonSetup.status("not-a-uuid") == nil
    assert PersonSetup.status(nil) == nil
  end

  describe "signed in" do
    test "flips on an admission audit row, not on the users row" do
      user = user!()
      assert states(user).signed_in == :todo

      at = sign_in!(user)

      assert states(user).signed_in == :done
      assert PersonSetup.status(user).first_sign_in_at == at
    end

    test "an OIDC callback success row counts; a failure row does not" do
      user = user!()
      sign_in!(user, "platform.auth.callback", "failure")
      assert states(user).signed_in == :todo

      sign_in!(user, "platform.auth.callback", "success")
      assert states(user).signed_in == :done
    end

    test "another person's sign-in does not count" do
      user = user!()
      sign_in!(user!("other"))
      assert states(user).signed_in == :todo
    end
  end

  describe "notifications" do
    test "flips on a web push subscription row, not on a participant row" do
      user = user!()
      {_space, participant} = dm_space!(user)
      assert states(user).notifications == :todo

      {:ok, _} =
        Push.subscribe(participant.id, %{
          endpoint: "https://push.example.com/#{System.unique_integer([:positive])}",
          keys: %{p256dh: "p256dh-key", auth: "auth-key"}
        })

      assert states(user).notifications == :done
    end
  end

  test "notifications: another person's subscription does not count" do
    user = user!()
    dm_space!(user)
    {_space, theirs} = dm_space!(user!("other"))

    {:ok, _} =
      Push.subscribe(theirs.id, %{
        endpoint: "https://push.example.com/#{System.unique_integer([:positive])}",
        keys: %{p256dh: "p256dh-key", auth: "auth-key"}
      })

    assert states(user).notifications == :todo
  end

  describe "phone app" do
    test "flips on an APNs token row; an app session alone stays unknown" do
      user = user!()
      session = app_session!(user)
      assert states(user).phone_app == :unknown

      {:ok, _} =
        Mobile.register_device(session, %{
          "token" => String.duplicate("5e17", 16),
          "environment" => "sandbox",
          "bundle_id" => "com.example.app",
          "app_install_id" => "install-1"
        })

      assert states(user).phone_app == :done
      assert Push.native_platforms(user.id) == [:ios]
    end

    test "an FCM token row counts as the phone app" do
      user = user!()

      {:ok, _} =
        Mobile.register_device(app_session!(user), %{
          "platform" => "android",
          "token" => "fcmInstance01:APA91b" <> String.duplicate("T0ken-", 12),
          "package_name" => Platform.Mobile.FcmDevice.package_name(),
          "app_install_id" => "install-1"
        })

      assert states(user).phone_app == :done
      assert Push.native_platforms(user.id) == [:android]
    end

    test "is never stuck, however long ago the first sign-in was" do
      user = user!()
      at = sign_in!(user)
      status = PersonSetup.status(user, now: DateTime.add(at, 30 * @day), stuck_after_seconds: 60)
      assert state(status, :phone_app) == :unknown
      refute :phone_app in status.stuck
    end
  end

  describe "AI login" do
    test "flips when an agent the member owns runs on a subscription login" do
      user = user!()
      agent = native_agent!(user, "Helper", "codex")
      assert states(user).ai_login == :todo

      State.put(agent.id, :needs_login)
      assert states(user).ai_login == :todo

      State.put(agent.id, :running)
      assert states(user).ai_login == :done
    end

    test "a running Claude agent with an API key saved never counts" do
      user = user!()
      agent = native_agent!(user, "Keyed", "claude_code")
      :ok = NativeLogin.put_api_key(user.id, agent, "sk-ant-" <> String.duplicate("a", 40))
      State.put(agent.id, :running)

      assert NativeLogin.api_key_set?(agent)
      assert states(user).ai_login == :todo
    end

    test "a running Claude agent with no key (subscription) counts" do
      user = user!()
      agent = native_agent!(user, "Subscribed", "claude_code")
      State.put(agent.id, :running)

      assert states(user).ai_login == :done
    end

    test "someone else's running agent does not count" do
      user = user!()
      agent = native_agent!(user!("owner"), "Theirs", "codex")
      State.put(agent.id, :running)

      assert states(user).ai_login == :todo
    end
  end

  describe "channels" do
    test "flips on a channel participant row; a DM does not count" do
      user = user!()
      dm_space!(user)
      assert states(user).channels == :todo

      channel!(user)
      assert states(user).channels == :done
    end
  end

  describe "who to ask" do
    test "flips only once the welcome naming the admins is posted" do
      owner = user!("owner")
      burrow = native_agent!(owner, "Burrow", "codex")
      assert burrow.slug == "burrow"

      user = user!()
      assert states(user).who_to_ask == :todo

      assert {:ok, %{}} = MemberWelcome.ensure(user)
      assert states(user).who_to_ask == :done
    end

    test "a preference pointing at no real welcome message does not count" do
      user = user!()

      {:ok, _} =
        Platform.Accounts.update_user_preference(
          user.id,
          MemberWelcome.pref_key(),
          Ecto.UUID.generate()
        )

      assert states(user).who_to_ask == :todo

      {:ok, _} =
        Platform.Accounts.update_user_preference(user.id, MemberWelcome.pref_key(), "posting")

      assert states(user).who_to_ask == :todo
    end
  end

  describe "stuck" do
    test "a todo step is stuck only strictly past the threshold after the first sign-in" do
      user = user!()
      at = sign_in!(user)

      at_threshold =
        PersonSetup.status(user, now: DateTime.add(at, 3600), stuck_after_seconds: 3600)

      assert state(at_threshold, :notifications) == :todo
      assert at_threshold.stuck == []

      past = PersonSetup.status(user, now: DateTime.add(at, 3601), stuck_after_seconds: 3600)
      assert state(past, :notifications) == :stuck
      assert past.stuck == [:notifications, :ai_login, :channels, :who_to_ask]
      assert state(past, :signed_in) == :done
      assert past.next == :notifications
    end

    test "a done step is never stuck" do
      user = user!()
      at = sign_in!(user)
      channel!(user)

      status = PersonSetup.status(user, now: DateTime.add(at, 10 * @day), stuck_after_seconds: 60)
      assert state(status, :channels) == :done
      refute :channels in status.stuck
    end

    test "nobody is stuck before a first sign-in" do
      user = user!()

      status =
        PersonSetup.status(user,
          now: DateTime.add(DateTime.utc_now(), 365 * @day),
          stuck_after_seconds: 1
        )

      assert status.stuck == []
    end

    test "the threshold comes from config, and unset means nobody is stuck" do
      previous = Application.get_env(:platform, PersonSetup)
      on_exit(fn -> Application.put_env(:platform, PersonSetup, previous) end)

      user = user!()
      at = sign_in!(user)
      now = DateTime.add(at, 600)

      Application.put_env(:platform, PersonSetup, stuck_after_seconds: 300)
      assert PersonSetup.stuck_after_seconds() == 300
      assert state(PersonSetup.status(user, now: now), :channels) == :stuck

      Application.put_env(:platform, PersonSetup, stuck_after_seconds: 900)
      assert state(PersonSetup.status(user, now: now), :channels) == :todo

      Application.put_env(:platform, PersonSetup, [])
      assert PersonSetup.stuck_after_seconds() == nil
      assert PersonSetup.status(user, now: DateTime.add(at, 365 * @day)).stuck == []
    end

    test "the shipped config sets a threshold" do
      assert is_integer(PersonSetup.stuck_after_seconds())
    end
  end

  describe "evaluate/2" do
    test "is pure: the same facts, now and threshold give the same answer" do
      facts = %{
        user_id: Ecto.UUID.generate(),
        first_sign_in_at: ~U[2026-01-01 00:00:00Z],
        notifications: true,
        phone_app: false,
        ai_login: true,
        channels: true,
        who_to_ask: true
      }

      opts = [now: ~U[2026-02-01 00:00:00Z], stuck_after_seconds: 60]
      assert PersonSetup.evaluate(facts, opts) == PersonSetup.evaluate(facts, opts)
      assert %{complete?: true, next: nil, stuck: []} = PersonSetup.evaluate(facts, opts)
    end
  end

  test "Platform.Onboarding.PersonSetup and MemberWelcome make no Repo call" do
    for file <- ~w(person_setup.ex member_welcome.ex) do
      source = File.read!(Path.join([File.cwd!(), "lib/platform/onboarding", file]))
      refute source =~ ~r/\bRepo\./, "#{file} calls Repo directly"
      refute source =~ ~r/alias Platform\.Repo\b/, "#{file} aliases Platform.Repo"
      refute source =~ ~r/import Ecto\.Query/, "#{file} builds its own queries"
    end
  end
end
