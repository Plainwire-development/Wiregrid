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
  require Logger

  alias Wiregrid.Foreign.Protocol

  @option_keys [
    :name,
    :instance,
    :ip,
    :port,
    :max_connections,
    :authenticate,
    :allow_anonymous,
    :idle_timeout_ms,
    :send_timeout_ms,
    :max_protocol_errors,
    :handshake_timeout_ms,
    :max_auth_attempts,
    :frame_rate_limit,
    :frame_window_ms,
    :debug
  ]

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
  def handle_info(:accept, %{acceptor: nil, socket: socket} = state)
      when map_size(state.connections) < state.max_connections do
    parent = self()

    case Task.Supervisor.start_child(Wiregrid.TaskSupervisor, fn ->
           accept_once(parent, socket, state.instance, state.conn_opts)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:noreply, %{state | acceptor: {pid, ref}}}

      {:error, _} ->
        Process.send_after(self(), :accept, 50)
        {:noreply, state}
    end
  end

  def handle_info(:accept, state), do: {:noreply, state}

  def handle_info({:accepted, pid}, %{acceptor: {pid, ref}} = state) do
    next = %{state | acceptor: nil, connections: Map.put(state.connections, pid, ref)}
    debug(next, :accepted)
    send(self(), :accept)
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{acceptor: {pid, ref}} = state) do
    Process.send_after(self(), :accept, 100)
    {:noreply, %{state | acceptor: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    next =
      if Map.get(state.connections, pid) == ref do
        %{state | connections: Map.delete(state.connections, pid)}
      else
        state
      end

    debug(next, :closed)
    send(self(), :accept)
    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp prepare(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         ip <- Keyword.get(opts, :ip, {127, 0, 0, 1}),
         :ok <- validate_ip(ip),
         {:ok, instance} <- fetch_instance(opts),
         :ok <- validate_port(Keyword.get(opts, :port, 0)),
         :ok <- validate_max_connections(Keyword.get(opts, :max_connections, 1_024)),
         {:ok, idle_timeout_ms} <-
           fetch_bounded(opts, :idle_timeout_ms, 60_000, 1_000, 3_600_000),
         {:ok, send_timeout_ms} <- fetch_bounded(opts, :send_timeout_ms, 5_000, 100, 120_000),
         {:ok, max_protocol_errors} <- fetch_bounded(opts, :max_protocol_errors, 8, 1, 100),
         {:ok, handshake_timeout_ms} <-
           fetch_bounded(opts, :handshake_timeout_ms, 5_000, 100, 120_000),
         {:ok, max_auth_attempts} <- fetch_bounded(opts, :max_auth_attempts, 5, 1, 100),
         {:ok, frame_rate_limit} <- fetch_bounded(opts, :frame_rate_limit, 240, 1, 100_000),
         {:ok, frame_window_ms} <- fetch_bounded(opts, :frame_window_ms, 60_000, 100, 3_600_000),
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
         max_protocol_errors: max_protocol_errors,
         handshake_timeout_ms: handshake_timeout_ms,
         max_auth_attempts: max_auth_attempts,
         frame_rate_limit: frame_rate_limit,
         frame_window_ms: frame_window_ms,
         debug: Keyword.get(opts, :debug, false)
       }}
    end
  end

  defp prepare(_opts), do: {:error, argument_error("gateway options must be a keyword list")}

  defp listen(prepared) do
    listen_opts = [
      :binary,
      if(tuple_size(prepared.ip) == 8, do: :inet6, else: :inet),
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
              connections: %{},
              acceptor: nil,
              port: bound_port,
              debug: prepared.debug,
              conn_opts: %{
                authenticate: prepared.authenticate,
                idle_timeout_ms: prepared.idle_timeout_ms,
                max_protocol_errors: prepared.max_protocol_errors,
                send_timeout_ms: prepared.send_timeout_ms,
                handshake_timeout_ms: prepared.handshake_timeout_ms,
                max_auth_attempts: prepared.max_auth_attempts,
                frame_rate_limit: prepared.frame_rate_limit,
                frame_window_ms: prepared.frame_window_ms,
                debug: prepared.debug
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

  defp validate_options(opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @option_keys),
         true <- is_boolean(Keyword.get(opts, :debug, false)),
         true <- is_boolean(Keyword.get(opts, :allow_anonymous, false)) do
      :ok
    else
      _ ->
        {:error,
         argument_error(
           "gateway options must be known, unique keyword options with boolean debug and allow_anonymous"
         )}
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

  defp validate_ip(ip) do
    if :inet.is_ip_address(ip),
      do: :ok,
      else: {:error, argument_error("ip must be an IPv4 or IPv6 address tuple")}
  end

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

      {:error, _reason} ->
        :ok
    end
  end

  defp debug(%{debug: true} = state, event) do
    Logger.debug("wiregrid foreign gateway #{event} connections=#{map_size(state.connections)}")
  end

  defp debug(_state, _event), do: :ok
end
