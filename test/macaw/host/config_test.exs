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
    @tag verifies: "literal-reads"
    test "reads maps, lists, tuples of any size, negative numbers, atoms and strings" do
      text = ~S'%{a: 1, b: -2.5, c: [1, "x", :closed], d: {1, 2, 3}, e: %{f: {:open, nil}}}'

      assert Literal.parse(text) ==
               {:ok, %{a: 1, b: -2.5, c: [1, "x", :closed], d: {1, 2, 3}, e: %{f: {:open, nil}}}}
    end

    @tag verifies: "literal-faults"
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

    @tag verifies: "literal-no-atom"
    test "makes no atom: an unknown name is a fault" do
      name = "macaw_host_never_an_atom_#{System.unique_integer([:positive])}"
      assert {:error, [fault]} = Literal.parse("%{#{name}: 1}")
      assert fault =~ "unsafe atom"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    @tag verifies: "literal-not-map"
    test "something other than a map is refused" do
      assert {:error, ["config.exs must contain a single literal map"]} = Literal.parse("[a: 1]")
    end

    @tag verifies: "literal-missing"
    test "a missing file is an empty map", %{tmp_dir: dir} do
      assert Literal.read!(Path.join(dir, "none.exs")) == %{}
    end

    @tag verifies: "literal-write"
    test "writes atomically, 0600, and reads back what it wrote", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      map = %{port: 4001, hosts: ["a", "b"], mode: :open, offset: -3, t: {1, 2, 3}}
      Literal.write!(path, map, "a header\nsecond line")

      assert Literal.read!(path) == map
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      refute File.exists?(path <> ".tmp")
      assert File.read!(path) =~ "# a header\n# second line\n"
    end

    @tag verifies: "literal-round-trip"
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
    @tag verifies: "config-order"
    test "env var > file > default, with the source of each" do
      env = %{"APP_PORT" => "8080"}
      file = %{port: 9090, public_host: "example.com"}

      assert {:ok, r} = Config.resolve(@specs, env, file, "APP")
      assert r.port == %{value: 8080, source: :env}
      assert r.public_host == %{value: "example.com", source: :file}
      assert r.debug == %{value: false, source: :default}
    end

    @tag verifies: "config-all-faults"
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

    @tag verifies: "types-env"
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

    @tag verifies: "config-load"
    test "load!, get and source", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Literal.write!(path, %{smtp_password: "hunter2-long-secret"})

      Config.load!(:config_test_app, @specs,
        path: path,
        env_prefix: "APP",
        env: %{"APP_PORT" => "81"}
      )

      assert Config.get(:config_test_app, :port) == 81
      assert Config.source(:config_test_app, :port) == :env

      assert_raise ArgumentError, ~r/declares no setting :nope/, fn ->
        Config.get(:config_test_app, :nope)
      end
    end

    @tag verifies: "config-show-masks"
    test "show masks secrets", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Literal.write!(path, %{smtp_password: "hunter2-long-secret"})

      Config.load!(:config_show_test_app, @specs, path: path, env_prefix: "APP", env: %{})

      shown = Config.show(:config_show_test_app)
      assert {:smtp_password, "set (…cret)", :file} in shown
      refute Enum.any?(shown, fn {_, v, _} -> v =~ "hunter2" end)
    end

    @tag verifies: "config-mask"
    test "mask shows a secret's last four only from 16 characters" do
      assert Config.mask(:secret, nil) == "unset"
      assert Config.mask(:secret, "") == "unset"
      assert Config.mask(:secret, "abcde") == "set"
      assert Config.mask(:secret, String.duplicate("x", 15)) == "set"
      assert Config.mask(:secret, String.duplicate("x", 12) <> "1234") == "set (…1234)"
      assert Config.mask(:port, 4000) == "4000"
    end

    @tag verifies: "config-load-faults"
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
    @tag verifies: "config-put"
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

    @tag verifies: "config-put-bare-word"
    test "put! names what a bare word should have been, and leaves the file untouched",
         %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      assert {:ok, 8443} = Config.put!(path, @specs, "port", "8443")
      before = File.read!(path)

      # `ok` is an atom the VM knows; the second word is spelled for this test alone, so
      # it is no atom: the two answers read alike.
      for word <- ["ok", "nasbox_put_bare_word_q7v"] do
        assert {:error, why} = Config.put!(path, @specs, "public_host", word)
        assert why =~ "not a literal: #{word}"
        assert why =~ ~s(a string is quoted: config set public_host '"#{word}"')
        refute why =~ "unsafe atom"
      end

      assert {:error, why} = Config.put!(path, @specs, "offset", "ok")
      assert why =~ "not a literal: ok"
      refute why =~ "quoted"

      assert {:error, why} = Config.put!(path, @specs, "smtp_password", "hunter2xq")
      assert why =~ ~s(a string is quoted: config set smtp_password '"…"')
      assert why =~ "not a literal: …"
      refute why =~ "hunter2xq"

      assert File.read!(path) == before
    end

    @tag verifies: "config-delete"
    test "delete! removes a key", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Config.put!(path, @specs, "port", "8443")
      assert :ok = Config.delete!(path, @specs, "port")
      assert Literal.read!(path) == %{}
    end
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 01" do
    @tag verifies: "host-config"
    test "config.exs is a literal map, read and never evaluated; each setting resolves env var > file > default",
         %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      File.write!(path, ~S|%{port: 9090, public_host: "example.com", debug: System.halt(1)}|)

      error =
        assert_raise ArgumentError, fn ->
          Config.load!(:host_config_app, @specs, path: path, env_prefix: "APP", env: %{})
        end

      assert error.message =~ "not a literal: System.halt(1)"

      File.write!(path, ~s(%{port: 9090, public_host: "example.com"}))

      Config.load!(:host_config_app, @specs,
        path: path,
        env_prefix: "APP",
        env: %{"APP_PORT" => "8080"}
      )

      assert {Config.get(:host_config_app, :port), Config.source(:host_config_app, :port)} ==
               {8080, :env}

      assert {Config.get(:host_config_app, :public_host),
              Config.source(:host_config_app, :public_host)} == {"example.com", :file}

      assert {Config.get(:host_config_app, :mode), Config.source(:host_config_app, :mode)} ==
               {:closed, :default}
    end

    @tag verifies: "host-config-literal"
    test "a literal is an atom, a string, a number, a list, a map or a tuple of any size, nested; anything else is a fault",
         %{tmp_dir: dir} do
      text =
        ~S'%{a: nil, b: true, c: false, d: "s", e: -1, f: 2.5, g: [:x, {1}], h: %{"k" => {1, 2, 3, 4}}}'

      map = %{
        a: nil,
        b: true,
        c: false,
        d: "s",
        e: -1,
        f: 2.5,
        g: [:x, {1}],
        h: %{"k" => {1, 2, 3, 4}}
      }

      assert Literal.parse(text) == {:ok, map}

      # It writes the file as well as reading it.
      path = Path.join(dir, "config.exs")
      Literal.write!(path, map)
      assert Literal.read!(path) == map

      assert {:error, ["config.exs:1: not a literal: self()"]} = Literal.parse("%{a: self()}")
    end

    @tag verifies: "host-config-parse"
    test "parse/2 names its file, refuses sigils, reports in source order, and stops at a syntax error" do
      assert {:error, faults} = Literal.parse("%{\n  a: x,\n  b: ~w(a b),\n  c: y\n}", "app.exs")

      assert faults == [
               "app.exs:2: not a literal: x",
               "app.exs:3: not a literal: ~w(a b)",
               "app.exs:4: not a literal: y"
             ]

      assert {:ok, %{offset: -5, t: {1, 2, 3}}} = Literal.parse("%{offset: -5, t: {1, 2, 3}}")

      assert {:error, ["config.exs must contain a single literal map"]} =
               Literal.parse("%{a: 1}\n%{b: 2}")

      # A syntax error is the one fault: nothing after it is reported.
      assert {:error, [fault]} = Literal.parse("%{\n  a: x,\n  b: [\n}")
      assert fault =~ ~r/^config.exs:\d+: /
      refute fault =~ "not a literal"
    end

    @tag verifies: "host-config-atoms"
    test "an atom that doesn't exist is the one fault, named with its line, and none is made" do
      name = "macaw_host_never_a_value_#{System.unique_integer([:positive])}"

      assert {:error, [fault]} = Literal.parse("%{\n  a: x,\n  b: :#{name}\n}")
      assert fault == "config.exs:3: unsafe atom does not exist: #{name}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    @tag verifies: "host-config-read"
    test "read!, read, parse! and parse_value", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      File.write!(path, "%{\n  a: x,\n  b: y\n}")

      error = assert_raise ArgumentError, fn -> Literal.read!(path) end
      assert [_, _] = String.split(error.message, "\n")
      assert_raise File.Error, fn -> Literal.read!(dir) end

      assert {:ok, %{}} = Literal.read(Path.join(dir, "none.exs"))
      assert {:error, [_, _]} = Literal.read(path)
      assert {:error, ["cannot read " <> _]} = Literal.read(dir)

      error = assert_raise ArgumentError, fn -> Literal.parse!("%{a: x, b: y}") end
      assert [_, _] = String.split(error.message, "\n")
      assert Literal.parse!("%{a: 1}") == %{a: 1}

      assert Literal.parse_value("[1, {:open, \"x\"}]") == {:ok, [1, {:open, "x"}]}
      assert Literal.parse_value("x") == {:error, ["value:1: not a literal: x"]}
      assert Literal.parse_value("x", "port") == {:error, ["port:1: not a literal: x"]}
    end

    @tag verifies: "host-config-write"
    test "write! creates the directory and writes a header, then sorted keys, lists as lists",
         %{tmp_dir: dir} do
      path = Path.join([dir, "new", "config.exs"])
      Literal.write!(path, %{b: [1, 2, 3], a: "x"}, "first\nsecond")

      assert File.read!(path) ==
               "# first\n# second\n%{\n  :a => \"x\",\n  :b => [1, 2, 3]\n}\n"

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      refute File.exists?(path <> ".tmp")

      long = String.duplicate("y", 5_000)
      Literal.write!(path, %{long: long, codes: ~c"abc"})
      assert Literal.read!(path) == %{long: long, codes: [97, 98, 99]}
      refute File.read!(path) =~ "~c"
    end

    @tag verifies: "host-config-types"
    test "each type is checked from the file and cast from an env var, its faults worded as the table says" do
      alias Macaw.Host.Config.Types

      checked = [
        {:string, "a", {:ok, "a"}},
        {:secret, "a", {:ok, "a"}},
        {:optional_string, nil, {:ok, nil}},
        {:boolean, false, {:ok, false}},
        {:integer, -3, {:ok, -3}},
        {:pos_integer, 0, {:error, "must be a positive integer"}},
        {:port, 65_536, {:error, "must be a port number (1–65535)"}},
        {{:enum, [:open, :closed]}, :ajar, {:error, "must be one of [:open, :closed]"}},
        {{:enum, [:open, :closed]}, "open", {:error, "must be one of [:open, :closed]"}},
        {:string_list, ["a", 1], {:error, "must be a list of strings"}},
        {:string, 1, {:error, "must be a string"}}
      ]

      for {type, value, answer} <- checked,
          do: assert(Types.check(type, value) == answer, inspect({type, value}))

      cast = [
        {:string, " a ", {:ok, " a "}},
        {:optional_string, "", {:ok, nil}},
        {:boolean, " TRUE ", {:ok, true}},
        {:boolean, "0", {:ok, false}},
        {:boolean, "yes", {:error, "must be true or false"}},
        {:integer, " +7 ", {:ok, 7}},
        {:pos_integer, "0", {:error, "must be a positive integer"}},
        {:port, " 8443 ", {:ok, 8443}},
        {:port, "eighty", {:error, "must be a port number (1–65535)"}},
        {{:enum, [:open, :closed]}, " closed ", {:ok, :closed}},
        {{:enum, [:open, :closed]}, "ajar", {:error, "must be one of open, closed"}},
        {:string_list, " a ,, b ", {:ok, ["a", "b"]}}
      ]

      for {type, text, answer} <- cast,
          do: assert(Types.cast(type, text) == answer, inspect({type, text}))

      custom = {:custom, {__MODULE__, :even}}
      assert Types.check(custom, 2) == {:ok, 2}
      assert Types.cast(custom, "3") == {:error, "must be even"}

      assert Types.describe(:port) == "a port number (1–65535)"
      assert Types.describe({:enum, [:open, :closed]}) == "one of [:open, :closed]"

      # An enum name from an env var is compared as a string: no atom is made.
      name = "macaw_host_never_an_enum_#{System.unique_integer([:positive])}"
      assert {:error, _} = Types.cast({:enum, [:open]}, name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    @tag verifies: "host-config-resolve"
    test "resolve/4: an env var wins even empty, a file key is an atom or a string, a default is unchecked, unknown keys come first" do
      assert Config.env_var("APP", :public_host) == "APP_PUBLIC_HOST"

      specs = [{:public_host, :string, "localhost"}, {:port, :port, :not_a_port}]

      assert {:ok, r} =
               Config.resolve(specs, %{"APP_PUBLIC_HOST" => ""}, %{"port" => 9090}, "APP")

      assert r == %{
               public_host: %{value: "", source: :env},
               port: %{value: 9090, source: :file}
             }

      assert {:ok, %{port: %{value: :not_a_port, source: :default}}} =
               Config.resolve(specs, %{}, %{}, "APP")

      assert {:error, faults} =
               Config.resolve(specs, %{"APP_PORT" => "x"}, %{{:a, 1} => 1, :typo => 1}, "APP")

      # Every unknown key first (a map's keys have no order of their own),
      # then the invalid values.
      assert [first, second, "APP_PORT: must be a port number (1–65535)"] = faults

      assert Enum.sort([first, second]) == [
               "config.exs: unknown setting :typo",
               "config.exs: unknown setting {:a, 1}"
             ]

      assert Config.resolve_setting({:port, :port, 1}, %{"APP_PORT" => "x"}, %{}, "APP") ==
               {:error,
                %{raw: "x", source: :env, fault: "APP_PORT: must be a port number (1–65535)"}}

      assert Config.resolve_setting({:port, :port, 1}, %{}, %{port: 0}, "APP") ==
               {:error,
                %{
                  raw: 0,
                  source: :file,
                  fault: "config.exs port: must be a port number (1–65535)"
                }}
    end

    @tag verifies: "host-config-load"
    test "load! reads the file and the environment, keeps the result, and raises on any fault",
         %{tmp_dir: dir} do
      missing = Path.join(dir, "none.exs")
      Config.load!(:host_load_app, @specs, path: missing, env_prefix: "APP", env: %{})
      assert Config.source(:host_load_app, :port) == :default
      assert Config.keys(@specs) == Enum.map(@specs, &elem(&1, 0))

      assert %{values: %{port: %{value: 4000}}, specs: @specs} =
               :persistent_term.get({Config, :host_load_app})

      assert_raise File.Error, fn ->
        Config.load!(:host_load_app, @specs, path: dir, env_prefix: "APP", env: %{})
      end

      error =
        assert_raise ArgumentError, fn ->
          Config.load!(:host_load_app, @specs,
            path: missing,
            env_prefix: "APP",
            env: %{"APP_PORT" => "0", "APP_DEBUG" => "x"}
          )
        end

      assert error.message ==
               "invalid configuration:\n  APP_PORT: must be a port number (1–65535)\n" <>
                 "  APP_DEBUG: must be true or false"

      assert_raise ArgumentError, ":host_load_app declares no setting :nope", fn ->
        Config.source(:host_load_app, :nope)
      end
    end

    @tag verifies: "host-config-show"
    test "show/1 is every setting in declared order; mask/2 inspects anything but a secret",
         %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      Literal.write!(path, %{mode: :open, smtp_password: "short"})
      Config.load!(:host_show_app, @specs, path: path, env_prefix: "APP", env: %{})

      assert Config.show(:host_show_app) == [
               {:public_host, ~s("localhost"), :default},
               {:port, "4000", :default},
               {:debug, "false", :default},
               {:mode, ":open", :file},
               {:hosts, "[]", :default},
               {:smtp_password, "set", :file},
               {:offset, "0", :default}
             ]

      assert Config.mask({:enum, [:open]}, :open) == ":open"
      assert Config.mask(:string, "hunter2") == ~s("hunter2")
    end

    @tag verifies: "host-config-mask"
    test "the masking rule counts characters: unset, set, or set with the last four from 16" do
      for mask <- [&Config.mask(:secret, &1), &Ctl.Secret.mask/1] do
        assert mask.(nil) == "unset"
        assert mask.("") == "unset"
        assert mask.(String.duplicate("é", 15)) == "set"
        assert mask.(String.duplicate("é", 12) <> "wxyz") == "set (…wxyz)"
        assert mask.(String.duplicate("x", 40) <> "1234") == "set (…1234)"
      end
    end

    @tag verifies: "host-config-edit"
    test "put! and delete! match names as typed, take an enum by name, write a header, and replace a string key",
         %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      File.write!(path, ~s(%{"mode" => :closed, "port" => 1}))

      assert {:ok, :open} = Config.put!(path, @specs, "mode", "open")
      assert Literal.read!(path) == %{"port" => 1, mode: :open}
      assert {:error, "must be one of open, closed"} = Config.put!(path, @specs, "mode", ":ajar")
      assert {:error, "no setting named nope"} = Config.put!(path, @specs, "nope", "1")

      text = File.read!(path)
      assert text =~ "# App configuration: a literal map"
      assert text =~ "config set"
      assert text =~ "an env var still wins"

      assert :ok = Config.delete!(path, @specs, "port")
      assert Literal.read!(path) == %{mode: :open}
      assert {:error, "no setting named nope"} = Config.delete!(path, @specs, "nope")

      File.write!(path, "%{\n  a: x,\n  b: y\n}")

      assert Config.read_file(path) ==
               {:error, "#{path}:2: not a literal: x; #{path}:3: not a literal: y"}

      assert {:error, _} = Config.put!(path, @specs, "port", "1")
      assert {:error, _} = Config.delete!(path, @specs, "port")
      assert File.read!(path) == "%{\n  a: x,\n  b: y\n}"
    end
  end

  describe "custom types (macaw_host#1)" do
    @block {:custom, Macaw.Host.Test.SignInBlock}

    @tag verifies: "types-custom-module"
    test "a {:custom, module} type checks, casts and describes through its module" do
      assert Config.Types.check(@block, %{password: "x"}) == {:ok, %{password: "x"}}
      assert Config.Types.check(@block, 3) == {:error, "must be a sign-in block"}

      assert Config.Types.cast(@block, "anything") ==
               {:error, "is set in config.exs, not an env var"}

      assert Config.Types.describe(@block) == "a sign-in block"
    end

    @tag verifies: "config-mask-custom"
    test "a custom value is shown by its show/1, a secret inside masked, even one that didn't check" do
      block = %{host: "nas", password: "correct-horse-battery-staple"}
      shown = Config.mask(@block, block)
      assert shown =~ ~s(host: "nas")
      assert shown =~ "set (…aple)"
      refute shown =~ "correct-horse"

      assert Config.mask(@block, :not_a_block) == "(not a sign-in block)"
    end

    @tag verifies: "config-put-stores-typed"
    test "put!/4 stores the literal as typed, never the check's normalized result", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "config.exs")
      var = "MACAW_HOST_TEST_PW_#{System.unique_integer([:positive])}"
      System.put_env(var, "the-resolved-secret")
      on_exit(fn -> System.delete_env(var) end)
      specs = [{:auth, @block, nil}, {:even, {:custom, {__MODULE__, :halve}}, 0}]

      # The check resolves the reference; the file keeps the reference.
      assert {:ok, %{password: "the-resolved-secret"}} =
               Config.put!(path, specs, "auth", ~s(%{host: "nas", password: {:env, "#{var}"}}))

      assert Literal.read!(path) == %{auth: %{host: "nas", password: {:env, var}}}
      refute File.read!(path) =~ "the-resolved-secret"

      # An {m, f} check that normalizes is stored as typed too.
      assert {:ok, 4} = Config.put!(path, specs, "even", "8")
      assert Literal.read!(path).even == 8
    end
  end

  def even(v) when is_integer(v) and rem(v, 2) == 0, do: {:ok, v}
  def even(_), do: {:error, "must be even"}

  # A check that normalizes: the value the app uses is half what is stored.
  def halve(v) when is_integer(v) and rem(v, 2) == 0, do: {:ok, div(v, 2)}
  def halve(_), do: {:error, "must be even"}
end
