defmodule Wiregrid.Authorizer.DenyAll do
  @moduledoc "Fail-closed authorizer useful as a production starting point."
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(_action, _session, _resource, _context), do: {:error, :unauthorized}
end
