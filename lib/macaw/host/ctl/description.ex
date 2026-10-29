defmodule Macaw.Host.Ctl.Description do
  @moduledoc """
  The app description `<app>-ctl` is generated from: the `:ctl` key of the
  app's `mix.exs` project config, checked once here so the templates can
  trust every value.

      ctl: [
        name: "astex",
        image: "gitlab.conet.yarina.org:5005/dco-tek/astex",
        env_prefix: "ASTEX",
        release: "Astex.Release",
        uid: "2060:2060",
        port: 4000
      ]

  Required:

  | Key | What it is |
  |---|---|
  | `:name` | the app's name: the script is `<name>-ctl`, its settings `<name>.conf` |
  | `:image` | the image, without a tag |
  | `:env_prefix` | the release protocol's prefix: `<PREFIX>_CTL_ARGS` and the like |
  | `:release` | the release module whose `config/0` and `status/0` the script calls |
  | `:uid` | the container user's fixed `"uid:gid"` |
  | `:port` | the port the app listens on in the container, and the default PORT |

  Optional, with their defaults:

  | Key | Default | What it is |
  |---|---|---|
  | `:title` | the name, capitalized | the app's name in prose |
  | `:otp_app` | the project's `:app` | names the release's start script |
  | `:release_bin` | `"/app/bin/<otp_app>"` | the release's start script in the image |
  | `:tag` | `"latest"` | the default TAG |
  | `:network` | `"bridge"` | the default NETWORK; `"host"` shares the host's |
  | `:bind` | `"127.0.0.1"` | the default BIND, the host address PORT is published on; `"0.0.0.0"` is every interface, and must be with `network: "host"` |
  | `:container_data` | `"/data"` | where the data volume is mounted |
  | `:docker_run_args` | `"--restart unless-stopped"` | the default DOCKER_RUN_ARGS |
  | `:stop_timeout` | `30` | seconds `stop` gives the app |
  | `:data_home` | `"/srv/<name>"` | the data directory `init` offers |
  | `:seeds` | `[]` | app config `init` seeds: `[tz: :timezone, phx_host: :hostname, phx_scheme: "http"]` |
  | `:migrate_keys` | `[]` | `{old key, config key, old default}` that `init --migrate` carries from `<name>-env` |
  | `:settings` | `[]` | the app's own host settings: `{"KEY", "default", "help"}` |
  | `:host_network` | `true` | `false` refuses `NETWORK=host`, for an app whose listeners must stay off the host's interfaces |
  | `:app_keys` | `[]` | `{"KEY", "config_key"}`: a name `env set` refuses, pointing at `config set config_key` |
  | `:update_note` | `nil` | what `update` says once it has recreated the container, or `nil` for nothing |
  | `:app_commands` | `"ctl/app_commands.ex"` | the file defining `Ctl.AppCommands`, or `false` for none |
  | `:output` | `"container/<name>-ctl"` | where the script is written |

  Any other key is an error: a misspelled optional key silently taking its
  default is the bug this refuses.
  """

  @required [:name, :image, :env_prefix, :release, :uid, :port]
  @optional [
    :title,
    :otp_app,
    :release_bin,
    :tag,
    :network,
    :bind,
    :container_data,
    :docker_run_args,
    :stop_timeout,
    :data_home,
    :seeds,
    :migrate_keys,
    :settings,
    :host_network,
    :app_keys,
    :update_note,
    :app_commands,
    :output
  ]

  @core_settings ~w(PORT NETWORK BIND IMAGE TAG NAME DOCKER_RUN_ARGS)

  @type t :: %{atom() => term()}

  @doc """
  The checked description, with every default filled in and the values the
  templates derive (`:script`, `:ids`, the full `:settings`): `{:ok, map}`,
  or `{:error, message}` naming the first fault. `otp_app` is the project's
  `:app`, the default for `:otp_app`.
  """
  @spec new(keyword() | map() | nil, atom() | String.t() | nil) ::
          {:ok, t()} | {:error, String.t()}
  def new(description, otp_app \\ nil)

  def new(nil, _otp_app),
    do: {:error, "mix.exs has no :ctl key in its project config (see Macaw.Host.Ctl.Description)"}

  def new(description, otp_app) when is_list(description) or is_map(description) do
    given = Map.new(description)

    with :ok <- known_keys(given),
         :ok <- required_keys(given),
         :ok <- check_required(given) do
      fill(given, otp_app)
    end
  end

  def new(other, _otp_app), do: {:error, ":ctl must be a keyword list, not #{inspect(other)}"}

  @doc "As `new/2`, raising `ArgumentError` with the message."
  @spec new!(keyword() | map(), atom() | String.t() | nil) :: t()
  def new!(description, otp_app \\ nil) do
    case new(description, otp_app) do
      {:ok, checked} -> checked
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp known_keys(given) do
    case Map.keys(given) -- (@required ++ @optional) do
      [] -> :ok
      unknown -> {:error, ":ctl has unknown keys: #{Enum.map_join(unknown, ", ", &inspect/1)}"}
    end
  end

  defp required_keys(given) do
    case Enum.reject(@required, &Map.has_key?(given, &1)) do
      [] -> :ok
      missing -> {:error, ":ctl is missing #{Enum.map_join(missing, ", ", &inspect/1)}"}
    end
  end

  defp check_required(given) do
    check_all([
      {:name, given.name, &name?/1, "a lower-case name: letters, digits, - and _"},
      {:image, given.image, &nonempty?/1, "the image without a tag, as a string"},
      {:env_prefix, given.env_prefix, &prefix?/1, "upper-case letters, digits and _"},
      {:release, given.release, &module_name?/1,
       "a module name as a string, like \"MyApp.Release\""},
      {:uid, given.uid, &ids?/1, "\"uid:gid\", both numbers"},
      {:port, given.port, &port?/1, "a port number, 1–65535"}
    ])
  end

  defp fill(given, otp_app) do
    name = given.name
    otp_app = to_string(Map.get(given, :otp_app) || otp_app || String.replace(name, "-", "_"))
    title = Map.get(given, :title, String.capitalize(name))

    d =
      Map.merge(
        %{
          title: title,
          otp_app: otp_app,
          release_bin: "/app/bin/#{otp_app}",
          tag: "latest",
          network: "bridge",
          bind: "127.0.0.1",
          container_data: "/data",
          docker_run_args: "--restart unless-stopped",
          stop_timeout: 30,
          data_home: "/srv/#{name}",
          seeds: [],
          migrate_keys: [],
          settings: [],
          host_network: true,
          app_keys: [],
          update_note: nil,
          app_commands: "ctl/app_commands.ex",
          output: "container/#{name}-ctl"
        },
        given
      )

    with :ok <- check_optional(d),
         :ok <- check_bind(d),
         :ok <- check_settings(d.settings),
         :ok <- check_app_keys(d.app_keys, core_settings(d) ++ d.settings) do
      [uid, gid] = d.uid |> String.split(":") |> Enum.map(&String.to_integer/1)

      {:ok,
       Map.merge(d, %{
         otp_app: otp_app,
         script: name <> "-ctl",
         ids: {uid, gid},
         seeds: Enum.map(d.seeds, fn {key, value} -> {to_string(key), value} end),
         settings: core_settings(d) ++ d.settings
       })}
    end
  end

  defp check_optional(d) do
    check_all([
      {:title, d.title, &nonempty?/1, "a string"},
      {:otp_app, d.otp_app, &nonempty?/1, "an atom or a string"},
      {:release_bin, d.release_bin, &absolute?/1, "an absolute path"},
      {:tag, d.tag, &nonempty?/1, "a string"},
      {:network, d.network, &nonempty?/1, "\"host\" or a docker network's name"},
      {:bind, d.bind, &ip?/1, "an IP address as a string, like \"127.0.0.1\" or \"0.0.0.0\""},
      {:container_data, d.container_data, &absolute?/1, "an absolute path"},
      {:docker_run_args, d.docker_run_args, &is_binary/1, "a string"},
      {:stop_timeout, d.stop_timeout, &(is_integer(&1) and &1 >= 0), "seconds, an integer"},
      {:data_home, d.data_home, &absolute?/1, "an absolute path"},
      {:seeds, d.seeds, &seeds?/1, "a list of {config key, :hostname | :timezone | value}"},
      {:migrate_keys, d.migrate_keys, &migrate_keys?/1,
       "a list of {\"OLD_KEY\", \"config_key\", nil | :hostname | :timezone | \"default\"}"},
      {:settings, d.settings, &is_list/1, "a list of {\"KEY\", \"default\", \"help\"}"},
      {:host_network, d.host_network, &is_boolean/1, "true or false"},
      {:app_keys, d.app_keys, &app_keys?/1, "a list of {\"KEY\", \"config_key\"}"},
      {:update_note, d.update_note, &(&1 == nil or (is_binary(&1) and String.trim(&1) != "")),
       "a non-empty string, or nil"},
      {:app_commands, d.app_commands, &(&1 == false or nonempty?(&1)), "a path, or false"},
      {:output, d.output, &nonempty?/1, "a path"}
    ])
  end

  defp check_settings(settings) do
    Enum.reduce_while(settings, :ok, fn
      {key, default, help}, :ok when is_binary(default) and is_binary(help) ->
        cond do
          not (is_binary(key) and Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, key)) ->
            {:halt, {:error, ":ctl :settings key #{inspect(key)} must be an upper-case name"}}

          key in @core_settings ->
            {:halt, {:error, ":ctl :settings cannot redefine #{key}, which every script has"}}

          true ->
            {:cont, :ok}
        end

      other, :ok ->
        {:halt,
         {:error,
          ":ctl :settings entry #{inspect(other)} must be {\"KEY\", \"default\", \"help\"}"}}
    end)
  end

  defp check_all(checks) do
    Enum.find_value(checks, :ok, fn {key, value, valid?, expected} ->
      unless valid?.(value),
        do: {:error, ":ctl #{inspect(key)} must be #{expected}, not #{inspect(value)}"}
    end)
  end

  # On the host's network nothing is published: the app listens on the
  # host's own interfaces, and a script whose default BIND is any other
  # address would refuse its own defaults.
  defp check_bind(%{network: "host", bind: bind}) when bind != "0.0.0.0",
    do:
      {:error,
       ":ctl :bind must be \"0.0.0.0\" with network: \"host\", which publishes no port, not #{inspect(bind)}"}

  defp check_bind(_d), do: :ok

  # The seven settings every script has, each with the sentence that explains
  # it in `<name>.conf`.
  defp core_settings(d) do
    [
      {"PORT", Integer.to_string(d.port),
       "The web port. Reach #{d.title} at http://<this host>:PORT"},
      {"NETWORK", d.network,
       "host shares the host's network: #{d.title} listens on PORT directly. Any other value\n" <>
         "is a docker network to join, with PORT published to the container's #{d.port}."},
      {"BIND", d.bind,
       "The address PORT is published on. 127.0.0.1 keeps #{d.title} on this host (a proxy\n" <>
         "on the same host reaches it); 0.0.0.0 publishes it on every interface."},
      {"IMAGE", d.image, "The image, its tag, and the container's name."},
      {"TAG", d.tag, ""},
      {"NAME", d.name, ""},
      {"DOCKER_RUN_ARGS", d.docker_run_args, "Extra arguments for `docker run`."}
    ]
  end

  defp name?(v), do: is_binary(v) and Regex.match?(~r/^[a-z][a-z0-9_-]*$/, v)

  defp nonempty?(v),
    do: (is_binary(v) and v != "") or (is_atom(v) and v not in [nil, true, false])

  defp prefix?(v), do: is_binary(v) and Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, v)

  defp module_name?(v),
    do: is_binary(v) and Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, v)

  defp ids?(v), do: is_binary(v) and Regex.match?(~r/^\d+:\d+$/, v)
  defp port?(v), do: is_integer(v) and v in 1..65_535

  defp ip?(v),
    do: is_binary(v) and match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(v)))

  defp absolute?(v), do: is_binary(v) and String.starts_with?(v, "/")

  defp app_keys?(keys) do
    is_list(keys) and
      Enum.all?(keys, fn
        {key, config_key} when is_binary(key) and is_binary(config_key) ->
          Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, key) and
            Regex.match?(~r/^[a-z][a-z0-9_]*$/, config_key)

        _ ->
          false
      end)
  end

  # A name refused by `env set` can't also be a host setting it edits.
  defp check_app_keys(app_keys, settings) do
    host = Enum.map(settings, &elem(&1, 0))

    case Enum.find(app_keys, fn {key, _} -> key in host end) do
      nil -> :ok
      {key, _} -> {:error, ":ctl :app_keys names #{key}, which is a host setting"}
    end
  end

  defp seeds?(seeds) do
    is_list(seeds) and
      Enum.all?(seeds, fn
        {key, value} ->
          (is_atom(key) or is_binary(key)) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, to_string(key)) and
            (is_binary(value) or is_integer(value) or is_atom(value))

        _ ->
          false
      end)
  end

  defp migrate_keys?(keys) do
    is_list(keys) and
      Enum.all?(keys, fn
        {old, key, default} when is_binary(old) and is_binary(key) ->
          default in [nil, :hostname, :timezone] or is_binary(default)

        _ ->
          false
      end)
  end
end
