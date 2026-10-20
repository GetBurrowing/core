defmodule Platform.Memory.Insights.SettingsTest do
  @moduledoc """
  Task 01a13867 stage 3: the `install_insight_settings` singleton.
  Dissemination ships OFF; only a root admin may change it. Task 01a15587
  stage 1 lifted the deferral: a root admin can turn on automatic page
  edits and backlog tasks, a non-admin still cannot, and the DB CHECK that
  refused them is gone.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Memory.Insights.Settings
  alias Platform.Repo

  test "dissemination is off on a fresh install" do
    assert Repo.aggregate(Settings, :count) == 1

    assert %Settings{
             dissemination_enabled: false,
             deliver_briefings: true,
             deliver_questions: true,
             apply_page_edits: false,
             file_tasks: false
           } = Settings.get()
  end

  test "a non-admin cannot update settings" do
    member = person!("member")
    assert Settings.update(member, %{dissemination_enabled: true}) == {:error, :unauthorized}
    refute Settings.get().dissemination_enabled

    # Positive control: a root admin can.
    assert {:ok, %Settings{dissemination_enabled: true}} =
             Settings.update(root_admin!(), %{dissemination_enabled: true})

    assert Settings.get().dissemination_enabled
  end

  test "a root admin can turn on apply_page_edits and file_tasks" do
    assert {:ok, %Settings{apply_page_edits: true, file_tasks: true}} =
             Settings.update(root_admin!(), %{apply_page_edits: true, file_tasks: true})

    assert %Settings{apply_page_edits: true, file_tasks: true} = Settings.get()

    # And back off.
    assert {:ok, %Settings{apply_page_edits: false, file_tasks: false}} =
             Settings.update(root_admin!(), %{apply_page_edits: false, file_tasks: false})
  end

  test "a non-admin still cannot turn on apply_page_edits or file_tasks" do
    member = person!("member")
    before = Settings.get()

    for field <- [:apply_page_edits, :file_tasks] do
      assert Settings.update(member, %{field => true}) == {:error, :unauthorized}
    end

    assert Settings.get() == before
    assert %Settings{apply_page_edits: false, file_tasks: false} = Settings.get()
  end

  test "a raw UPDATE setting apply_page_edits = true succeeds (the CHECK is gone)" do
    assert %Postgrex.Result{num_rows: 1} =
             Repo.query!(
               "UPDATE install_insight_settings SET apply_page_edits = true, file_tasks = true"
             )

    assert %Settings{apply_page_edits: true, file_tasks: true} = Settings.get()

    refute Repo.exists?(
             from(c in "pg_constraint",
               where: c.conname == "install_insight_settings_deferred_off",
               select: 1
             )
           )
  end
end
