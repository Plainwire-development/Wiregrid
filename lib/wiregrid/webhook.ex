defmodule Wiregrid.Webhook do
  @moduledoc "Bounded optional webhook delivery. HTTPS destinations are revalidated on every attempt."

  def enqueue(instance, url, body, opts \\ []) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        if Keyword.get(cfg.webhooks, :enabled, false) do
          Wiregrid.Webhook.Dispatcher.enqueue(instance, url, body, opts)
        else
          {:error, :webhooks_disabled}
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def pending(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :ets.info(t.webhook_jobs, :size) || 0
      _ -> 0
    end
  end
end
