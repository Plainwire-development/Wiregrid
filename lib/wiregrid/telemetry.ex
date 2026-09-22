defmodule Wiregrid.Telemetry do
  @moduledoc false

  @availability_key {__MODULE__, :available}

  @doc false
  def refresh do
    available = Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3)
    :persistent_term.put(@availability_key, available)
    available
  end

  @doc false
  def available? do
    case :persistent_term.get(@availability_key, :unknown) do
      :unknown -> refresh()
      available when is_boolean(available) -> available
    end
  end

  def emit(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    if available?() do
      apply(:telemetry, :execute, [[:wiregrid | event], measurements, metadata])
    end

    :ok
  end
end
