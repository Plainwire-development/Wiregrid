defmodule Wiregrid.Transport.Protocol do
  @moduledoc "Transport protocol behaviour used by optional WebSocket adapters."

  @callback decode(binary()) :: {:ok, term()} | {:error, term()}
  @callback encode(term()) :: {:ok, binary()} | {:error, term()}
end
