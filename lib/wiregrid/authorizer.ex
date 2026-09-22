defmodule Wiregrid.Authorizer do
  @moduledoc "Application authorization boundary. Wiregrid validates inputs first and fails closed if the callback fails."

  @callback authorize(term(), map(), term(), map()) :: :ok | {:error, term()} | boolean()

  def check(instance, cfg, action, session, resource, context)
      when is_map(cfg) and is_map(session) and is_map(context) do
    case Wiregrid.Callback.run(instance, cfg, fn ->
           cfg.authorizer.authorize(action, session, resource, context)
         end) do
      {:ok, result} -> normalize(result)
      {:error, :callback_timeout} -> {:error, :authorization_timeout}
      {:error, :callback_overloaded} -> {:error, :authorization_overloaded}
      {:error, _} -> {:error, :authorization_failed}
    end
  end

  def check(_, _, _, _, _, _), do: {:error, :authorization_failed}

  defp normalize(:ok), do: :ok
  defp normalize(true), do: :ok
  defp normalize(false), do: {:error, :unauthorized}
  defp normalize({:error, _} = error), do: error
  defp normalize(_), do: {:error, :authorization_failed}
end
