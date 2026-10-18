defmodule PlatformWeb.Tasks.TaskDisplayDeployTargetLabelTest do
  @moduledoc """
  Task 01a14b9e stage 2: a deploy target's label is humanised from the
  target's own name (project deploy_config data), so no install's target
  name is spelled in code. Product-defined targets keep their spelling.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.Tasks.TaskDisplay

  test "an install's target is humanised from the data" do
    assert TaskDisplay.deploy_target_label("acme_production") == "Acme Production"
    assert TaskDisplay.deploy_target_label("staging") == "Staging"
    assert TaskDisplay.deploy_target_label("acme__edge_") == "Acme Edge"
  end

  test "product-defined targets keep their exact spelling" do
    assert TaskDisplay.deploy_target_label("github_pr") == "GitHub PR"
    assert TaskDisplay.deploy_target_label("google_drive") == "Google Drive"
  end

  test "degenerate values pass through" do
    assert TaskDisplay.deploy_target_label("_") == "_"
    assert TaskDisplay.deploy_target_label("") == ""
    assert TaskDisplay.deploy_target_label(nil) == nil
  end
end
