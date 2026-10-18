# Ad-hoc evidence seed for task 01a08e0d stage 2 (desktop stack-member title
# on its own line). NOT a permanent fixture — run once against the dev DB to
# get real long-title data for a screenshot, per the stage's Evidence steps.
#
#   PLATFORM_DEV_DATABASE=platform_dev_stage2_01a0ce5f mix run priv/scripts/seed_stage2_long_title_evidence.exs

alias Platform.Tasks
alias Platform.Tasks.Stacks

slug = "stage2-evidence-#{System.unique_integer([:positive])}"

{:ok, project} =
  Tasks.create_project(%{
    name: "Stage 2 Evidence Project",
    repo_url: "git@github.com:test/repo.git"
  })

{:ok, stack} =
  Stacks.create_stack(%{
    project_id: project.id,
    slug: slug,
    name: "Evidence stack for long titles",
    rollup_branch: Stacks.rollup_branch_name(slug)
  })

{:ok, m1} =
  Tasks.create_task(%{
    project_id: project.id,
    stack_id: stack.id,
    stack_position: 1,
    title:
      "Reconcile the federated dead-letter buffer replay path with the presence-subscribe confidentiality fence before the next prod deploy window",
    status: "in_review",
    priority: "medium"
  })

{:ok, m2} =
  Tasks.create_task(%{
    project_id: project.id,
    stack_id: stack.id,
    stack_position: 2,
    title: "Short title member",
    status: "backlog",
    priority: "medium"
  })

{:ok, _stack} = Stacks.recompute_stack_status(stack)

IO.puts("project_id=#{project.id}")
IO.puts("stack_id=#{stack.id}")
IO.puts("stack_slug=#{slug}")
IO.puts("member1_id=#{m1.id} title=#{m1.title}")
IO.puts("member2_id=#{m2.id} title=#{m2.title}")
