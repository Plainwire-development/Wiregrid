defmodule Wiregrid.Authorizer.AllowAll do
  @moduledoc "Permissive authorizer intended for trusted in-process applications and prototypes."
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(_action, _session, _resource, _context), do: :ok
end
