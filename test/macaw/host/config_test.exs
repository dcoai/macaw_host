defmodule Macaw.Host.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Host.Config
  alias Macaw.Host.Config.Literal

  @moduletag :tmp_dir

  @specs [
    {:public_host, :string, "localhost"},
    {:port, :port, 4000},
    {:debug, :boolean, false},
    {:mode, {:enum, [:open, :closed]}, :closed},
    {:hosts, :string_list, []},
    {:smtp_password, :secret, nil},
    {:offset, :integer, 0}
  ]

  describe "the literal reader" do
    test "reads maps, lists, tuples of any size, negative numbers, atoms and strings" do
      text = ~S'%{a: 1, b: -2.5, c: [1, "x", :closed], d: {1, 2, 3}, e: %{f: {:open, nil}}}'

      assert Literal.parse(text) ==
               {:ok, %{a: 1, b: -2.5, c: [1, "x", :closed], d: {1, 2, 3}, e: %{f: {:open, nil}}}}
    end

    test "never evaluates, and names every fault with its line" do
      text = ~S"""
      %{
        a: System.cmd("rm", ["-rf", "/"]),
        b: @doc,
        c: x,
        d: "#{1 + 1}"
      }
      """

      assert {:error, faults} = Literal.parse(text)
      assert length(faults) == 4
      assert Enum.any?(faults, &(&1 =~ ~r/config.exs:2: not a literal: System.cmd/))
      assert Enum.any?(faults, &(&1 =~ ~r/config.exs:3: not a literal: @doc/))
      assert Enum.any?(faults, &(&1 =~ ~r/config.exs:5: not a literal: "#\{1 \+ 1\}"/))
      assert Enum.any?(faults, &(&1 =~ ~r/config.exs:4: not a literal: x/))
    end

    test "makes no atom: an unknown name is a fault" do
      name = "macaw_host_never_an_atom_#{System.unique_integer([:positive])}"
      assert {:error, [fault]} = Literal.parse("%{#{name}: 1}")
      assert fault =~ "unsafe atom"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "something other than a map is refused" do
      assert {:error, ["config.exs must contain a single literal map"]} = Literal.parse("[a: 1]")
    end

    test "a missing file is an empty map", %{tmp_dir: dir} do
      assert Literal.read!(Path.join(dir, "none.exs")) == %{}
    end

    test "writes atomically, 0600, and reads back what it wrote", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      map = %{port: 4001, hosts: ["a", "b"], mode: :open, offset: -3, t: {1, 2, 3}}
      Literal.write!(path, map, "a header\nsecond line")

      assert Literal.read!(path) == map
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      refute File.exists?(path <> ".tmp")
      assert File.read!(path) =~ "# a header\n# second line\n"
    end

    property "write then read is the identity for literal maps", %{tmp_dir: dir} do
      check all(
              pairs <- list_of(tuple({member_of([:a, :b, :c, :port]), literal()}), max_length: 6),
              map = Map.new(pairs)
            ) do
        path = Path.join(dir, "prop.exs")
        Literal.write!(path, map)
        assert Literal.read!(path) == map
      end
    end
  end

  defp literal do
    leaf =
      one_of([
        integer(),
        float(),
        string(:printable),
        boolean(),
        constant(nil),
        member_of([:open, :closed])
      ])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 3), tuple({child, child, child})])
    end)
  end

  describe "resolution" do
    test "env var > file > default, with the source of each" do
      env = %{"APP_PORT" => "8080"}
      file = %{port: 9090, public_host: "example.com"}

      assert {:ok, r} = Config.resolve(@specs, env, file, "APP")
      assert r.port == %{value: 8080, source: :env}
      assert r.public_host == %{value: "example.com", source: :file}
      assert r.debug == %{value: false, source: :default}
    end

    test "every fault at once: bad env values, bad file values and unknown keys" do
      env = %{"APP_PORT" => "eighty", "APP_MODE" => "ajar"}
      file = %{debug: "yes", typo_key: 1, hosts: [1]}

      assert {:error, faults} = Config.resolve(@specs, env, file, "APP")
      assert "config.exs: unknown setting :typo_key" in faults
      assert "APP_PORT: must be a port number (1–65535)" in faults
      assert "APP_MODE: must be one of open, closed" in faults
      assert "config.exs debug: must be true or false" in faults
      assert "config.exs hosts: must be a list of strings" in faults
      assert length(faults) == 5
    end

    test "env values are typed" do
      env = %{
        "APP_DEBUG" => "1",
        "APP_HOSTS" => "a, b,,c",
        "APP_OFFSET" => "-5",
        "APP_MODE" => "open"
      }

      assert {:ok, r} = Config.resolve(@specs, env, %{}, "APP")

      assert {r.debug.value, r.hosts.value, r.offset.value, r.mode.value} ==
               {true, ["a", "b", "c"], -5, :open}
    end

    test "load!, get, source and show with secrets masked", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Literal.write!(path, %{smtp_password: "hunter2-long-secret"})

      Config.load!(:config_test_app, @specs,
        path: path,
        env_prefix: "APP",
        env: %{"APP_PORT" => "81"}
      )

      assert Config.get(:config_test_app, :port) == 81
      assert Config.source(:config_test_app, :port) == :env
      shown = Config.show(:config_test_app)
      assert {:smtp_password, "set (…cret)", :file} in shown
      refute Enum.any?(shown, fn {_, v, _} -> v =~ "hunter2" end)

      assert_raise ArgumentError, ~r/declares no setting :nope/, fn ->
        Config.get(:config_test_app, :nope)
      end
    end

    test "load! raises listing every fault", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      File.write!(path, "%{port: 0, mode: :open, debug: 3}")

      error =
        assert_raise ArgumentError, fn ->
          Config.load!(:bad_app, @specs, path: path, env_prefix: "APP", env: %{})
        end

      assert error.message =~ "config.exs port"
      assert error.message =~ "config.exs debug"
    end
  end

  describe "editing for the ctl" do
    test "put! checks the type, writes, and leaves the file untouched on error", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      assert {:ok, 8443} = Config.put!(path, @specs, "port", "8443")
      assert {:ok, :open} = Config.put!(path, @specs, "mode", ":open")
      before = File.read!(path)

      assert {:error, "must be a port number (1–65535)"} =
               Config.put!(path, @specs, "port", "70000")

      assert {:error, "no setting named prot"} = Config.put!(path, @specs, "prot", "1")
      assert {:error, why} = Config.put!(path, @specs, "public_host", "System.halt()")
      assert why =~ "not a literal"
      assert File.read!(path) == before
      assert Literal.read!(path) == %{port: 8443, mode: :open}
    end

    test "delete! removes a key", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Config.put!(path, @specs, "port", "8443")
      assert :ok = Config.delete!(path, @specs, "port")
      assert Literal.read!(path) == %{}
    end
  end
end
