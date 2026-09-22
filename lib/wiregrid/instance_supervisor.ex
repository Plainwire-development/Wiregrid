defmodule Wiregrid.InstanceSupervisor do
  @moduledoc false
  use Supervisor

  def start_link({instance, config}) do
    config =
      config
      |> normalize_cluster_namespace(instance)
      |> Map.put_new(:prepared_mac_key, :crypto.strong_rand_bytes(32))

    Supervisor.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  defp normalize_cluster_namespace(%{cluster_namespace: :instance} = config, instance),
    do: Map.put(config, :cluster_namespace, {:wiregrid_instance, instance})

  defp normalize_cluster_namespace(config, _instance), do: config

  def via(instance),
    do: {:via, Registry, {Wiregrid.ProcessRegistry, {:instance_supervisor, instance}}}

  @impl true
  def init({instance, config}) do
    children =
      [
        {Wiregrid.Tables, {instance, config}},
        {Wiregrid.Expiry, {instance, config}},
        {Wiregrid.Runtime, {instance, config}}
      ] ++ webhook_children(instance, config) ++ Wiregrid.Cluster.child_specs(instance, config)

    # If ETS ownership is lost, all later processes must restart against the new
    # tables. Runtime itself can rebuild process monitors when only it restarts.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp webhook_children(instance, config) do
    if Keyword.get(config.webhooks, :enabled, false) do
      [{Wiregrid.Webhook.Dispatcher, {instance, config}}]
    else
      []
    end
  end
end
