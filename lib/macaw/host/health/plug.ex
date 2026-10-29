if Code.ensure_loaded?(Plug) do
  defmodule Macaw.Host.Health.Plug do
    @moduledoc """
    Serves an app's health report as JSON: `200` when healthy, `503` when not.
    The JSON is the report's wire form (`Macaw.Host.Health.to_wire/1`): each
    check's result worded as text here, at the edge.

        get "/healthz", Macaw.Host.Health.Plug, report: {MyApp.Health, :report, []}

    or as a plug in an endpoint, answering only its `:path` (default
    `/healthz`) and passing every other request on.
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts) do
      {m, f, a} = Keyword.fetch!(opts, :report)
      %{report: {m, f, a}, path: Keyword.get(opts, :path, "/healthz")}
    end

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, %{path: path, report: {m, f, a}}) do
      report = apply(m, f, a)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        if(report.healthy, do: 200, else: 503),
        JSON.encode!(Macaw.Host.Health.to_wire(report))
      )
      |> halt()
    end

    def call(conn, _opts), do: conn
  end
end
