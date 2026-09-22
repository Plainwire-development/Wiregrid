defmodule Wiregrid.Transport.Protocol.Term do
  @moduledoc "Safe ETF protocol for native BEAM clients. Compressed and non-portable external terms are rejected."
  @behaviour Wiregrid.Transport.Protocol
  @max 16_777_216

  @impl true
  def decode(binary) do
    with {:ok, term} <- Wiregrid.SafeTerm.decode(binary, @max),
         :ok <- Wiregrid.Validation.portable_term(term, 0, 12, 4_096) do
      {:ok, term}
    else
      {:error, _} = error -> error
    end
  end

  @impl true
  def encode(term) do
    with :ok <- Wiregrid.Validation.portable_term(term, 0, 12, 4_096) do
      Wiregrid.SafeTerm.encode(term, @max)
    end
  end
end
