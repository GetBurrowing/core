# Module rig (ADR 0055 stage 4, task 01a0ee08): run inside a booted release
# with `bin/platform rpc`. Creates core rows a without-module install holds
# before a module is enabled: a project, a task and an experiment.
# Prints `RIG key=value` lines for scripts/module-enable-later-rig.sh.
alias Platform.Experiments
alias Platform.Tasks

u = System.unique_integer([:positive])

{:ok, project} =
  Tasks.create_project(%{name: "Rig #{u}", repo_url: "https://github.com/example/rig-01a0ee08"})

{:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Rig task #{u}"})

{:ok, experiment} =
  Experiments.create_experiment(%{
    slug: "rig-01a0ee08-#{u}",
    name: "Rig experiment #{u}",
    project_id: project.id
  })

IO.puts("RIG project_id=#{project.id}")
IO.puts("RIG task_id=#{task.id}")
IO.puts("RIG experiment_id=#{experiment.id}")
