defmodule Wiregrid.Foreign.Gateway do
  @moduledoc """
  Optional TCP gateway for non-BEAM clients.

  The gateway exposes a versioned binary protocol, not Erlang distribution.
  It binds to loopback unless you pick another address. Anonymous access is
  off unless `allow_anonymous: true` is set, and that option is refused for
  any bind address that is not loopback. Put TLS in front of the socket
  before it leaves a private network.
  """

  use GenServer

  alias Wiregrid.Foreign.Protocol

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    with {:ok, _prepared} <- prepare(opts) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    end
  end

  def protocol_version, do: Protocol.version()
  def c_abi_major, do: 1
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    case prepare(opts) do
      {:error, %ArgumentError{} = error} ->
        {:stop, error}

      {:ok, prepared} ->
        listen(prepared)
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info(:accept, %{socket: socket} = state) do
    parent = self()

    case Task.Supervisor.start_child(Wiregrid.TaskSupervisor, fn ->
           accept_once(parent, socket, state.instance, state.conn_opts)
         end) do
      {:ok, _pid} ->
        {:noreply, state}

      {:error, _} ->
        Process.send_after(self(), :accept, 50)
        {:noreply, state}
    end
  end

  def handle_info({:accepted, _pid}, %{connections: count, max_connections: limit} = state) do
    next = %{state | connections: min(count + 1, limit)}
    if next.connections < limit, do: send(self(), :accept)
    {:noreply, next}
  end

  def handle_info({:accept_failed, _reason}, state) do
    Process.send_after(self(), :accept, 100)
    {:noreply, state}
  end

  def handle_info(
        {:connection_closed, _pid},
        %{connections: count, max_connections: limit} = state
      ) do
    next = %{state | connections: max(count - 1, 0)}
    if count >= limit, do: send(self(), :accept)
    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp prepare(opts) when is_list(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    with {:ok, instance} <- fetch_instance(opts),
         :ok <- validate_port(Keyword.get(opts, :port, 0)),
         :ok <- validate_max_connections(Keyword.get(opts, :max_connections, 1_024)),
         {:ok, idle_timeout_ms} <-
           fetch_bounded(opts, :idle_timeout_ms, 60_000, 1_000, 3_600_000),
         {:ok, send_timeout_ms} <- fetch_bounded(opts, :send_timeout_ms, 5_000, 100, 120_000),
         {:ok, max_protocol_errors} <- fetch_bounded(opts, :max_protocol_errors, 8, 1, 100),
         {:ok, authenticate} <- fetch_authenticate(opts, ip) do
      {:ok,
       %{
         instance: instance,
         ip: ip,
         port: Keyword.get(opts, :port, 0),
         max_connections: Keyword.get(opts, :max_connections, 1_024),
         authenticate: authenticate,
         idle_timeout_ms: idle_timeout_ms,
         send_timeout_ms: send_timeout_ms,
         max_protocol_errors: max_protocol_errors
       }}
    end
  end

  defp prepare(_opts), do: {:error, argument_error("gateway options must be a keyword list")}

  defp listen(prepared) do
    listen_opts = [
      :binary,
      packet: 4,
      active: false,
      reuseaddr: true,
      nodelay: true,
      ip: prepared.ip,
      backlog: min(prepared.max_connections, 4_096),
      packet_size: Protocol.max_frame_bytes()
    ]

    case :gen_tcp.listen(prepared.port, listen_opts) do
      {:ok, socket} ->
        case :inet.sockname(socket) do
          {:ok, {_addr, bound_port}} ->
            state = %{
              socket: socket,
              instance: prepared.instance,
              max_connections: prepared.max_connections,
              connections: 0,
              port: bound_port,
              conn_opts: %{
                authenticate: prepared.authenticate,
                idle_timeout_ms: prepared.idle_timeout_ms,
                max_protocol_errors: prepared.max_protocol_errors,
                send_timeout_ms: prepared.send_timeout_ms
              }
            }

            send(self(), :accept)
            {:ok, state}

          {:error, reason} ->
            _ = :gen_tcp.close(socket)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp fetch_instance(opts) do
    case Keyword.fetch(opts, :instance) do
      {:ok, instance} -> {:ok, instance}
      :error -> {:error, argument_error("instance is required")}
    end
  end

  defp validate_port(port) when is_integer(port) and port in 0..65_535, do: :ok
  defp validate_port(_port), do: {:error, argument_error("port must be in 0..65535")}

  defp validate_max_connections(max) when is_integer(max) and max in 1..100_000, do: :ok

  defp validate_max_connections(_max),
    do: {:error, argument_error("max_connections must be in 1..100000")}

  defp fetch_bounded(opts, key, default, min, max) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= min and value <= max do
      {:ok, value}
    else
      {:error, argument_error("#{key} must be in #{min}..#{max}")}
    end
  end

  defp fetch_authenticate(opts, ip) do
    allow_anonymous = Keyword.get(opts, :allow_anonymous, false)
    fun = Keyword.get(opts, :authenticate)

    cond do
      is_function(fun, 2) ->
        {:ok, fun}

      fun != nil ->
        {:error, argument_error("authenticate must be a function of arity 2")}

      allow_anonymous == true and loopback?(ip) ->
        {:ok, fn _user_id, _token -> :ok end}

      allow_anonymous == true ->
        {:error,
         argument_error("allow_anonymous is only valid when the gateway binds a loopback address")}

      true ->
        {:ok, fn _user_id, _token -> {:error, :authentication_required} end}
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, 1}), do: true
  defp loopback?(_ip), do: false

  defp argument_error(message), do: %ArgumentError{message: message}

  defp accept_once(parent, socket, instance, opts) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        send(parent, {:accepted, self()})
        _ = :inet.setopts(client, send_timeout: opts.send_timeout_ms, send_timeout_close: true)
        Wiregrid.Foreign.Connection.run(client, instance, parent, opts)

      {:error, reason} ->
        send(parent, {:accept_failed, reason})
    end
  end
end
