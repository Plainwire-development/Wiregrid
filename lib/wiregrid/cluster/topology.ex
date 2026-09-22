defmodule Wiregrid.Cluster.Topology do
  @moduledoc false
  use GenServer

  @resync_interval 60_000

  def start_link({instance, config}) do
    GenServer.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  def via(instance),
    do: {:via, Registry, {Wiregrid.ProcessRegistry, {:cluster_topology, instance}}}

  @impl true
  def init({instance, config}) do
    if Node.alive?(), do: :net_kernel.monitor_nodes(true, node_type: :visible)
    seed_connected_nodes(instance)
    Process.send_after(self(), :periodic_resync, @resync_interval)
    {:ok, %{instance: instance, config: config, resyncing: MapSet.new()}}
  end

  @impl true
  def handle_info({:nodeup, remote, _info}, state) do
    mark_connected(state.instance, remote)
    {:noreply, start_resync(state, remote)}
  end

  def handle_info({:nodeup, remote}, state) do
    mark_connected(state.instance, remote)
    {:noreply, start_resync(state, remote)}
  end

  def handle_info({:nodedown, remote, _info}, state) do
    mark_disconnected(state.instance, remote)
    Wiregrid.Cluster.remove_node(state.instance, remote)
    {:noreply, %{state | resyncing: MapSet.delete(state.resyncing, remote)}}
  end

  def handle_info({:nodedown, remote}, state) do
    mark_disconnected(state.instance, remote)
    Wiregrid.Cluster.remove_node(state.instance, remote)
    {:noreply, %{state | resyncing: MapSet.delete(state.resyncing, remote)}}
  end

  def handle_info({:resync_done, remote}, state) do
    {:noreply, %{state | resyncing: MapSet.delete(state.resyncing, remote)}}
  end

  def handle_info(:periodic_resync, state) do
    next = Enum.reduce(Node.list(:visible), state, &start_resync(&2, &1))
    Process.send_after(self(), :periodic_resync, @resync_interval)
    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_resync(state, remote) do
    if MapSet.member?(state.resyncing, remote) do
      state
    else
      owner = self()

      case Task.Supervisor.start_child(Wiregrid.TaskSupervisor, fn ->
             try do
               _ = Wiregrid.Cluster.resync_to(state.instance, remote)
             after
               send(owner, {:resync_done, remote})
             end
           end) do
        {:ok, _pid} -> %{state | resyncing: MapSet.put(state.resyncing, remote)}
        _ -> state
      end
    end
  end

  defp seed_connected_nodes(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        :ets.delete_all_objects(t.cluster_nodes)
        Enum.each(Node.list(:visible), &:ets.insert(t.cluster_nodes, {&1, true}))

      _ ->
        :ok
    end
  end

  defp mark_connected(instance, remote) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :ets.insert(t.cluster_nodes, {remote, true})
      _ -> :ok
    end
  end

  defp mark_disconnected(instance, remote) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :ets.delete(t.cluster_nodes, remote)
      _ -> :ok
    end
  end
end
