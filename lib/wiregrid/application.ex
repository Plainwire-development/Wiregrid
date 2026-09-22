defmodule Wiregrid.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Optional Telemetry is resolved once at application start. Metrics are a
    # hot path; repeatedly consulting the code loader per delivery is avoidable.
    _ = Wiregrid.Telemetry.refresh()

    task_supervisor =
      Supervisor.child_spec(
        {Task.Supervisor, name: Wiregrid.TaskSupervisor},
        restart: :permanent
      )

    children = [
      {Registry, keys: :unique, name: Wiregrid.ProcessRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Wiregrid.InstanceSupervisor},
      task_supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Wiregrid.Supervisor)
  end
end
