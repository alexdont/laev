defmodule Laev.MixProject do
  use Mix.Project

  def project do
    [
      app: :laev_app,
      version: "0.1.37",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Laev.CLI, path: "laev"],
      releases: releases(),
      deps: deps()
    ]
  end

  # `MIX_ENV=prod mix release laev` → burrito_out/laev_linux_x86_64:
  # a single self-contained binary (BEAM bundled, no Erlang needed on the
  # user's machine) — the artifact package managers ship.
  defp releases do
    [
      laev: [
        steps: [:assemble, &clean_stale_erts/1, &Burrito.wrap/1, &clean_stale_erts/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Burrito unpacks ERTS bundles into /tmp/unpacked_erts_* and keeps its working
  # copies in /tmp/burrito_build_* (~96MB each), and never deletes either — half
  # a dozen releases fill a tmpfs, and then the build dies with "disk quota
  # exceeded" and takes the shell that ran it down with it. Swept both before and
  # after wrapping: before covers a build that died halfway, after covers this
  # one, which is the leftover the next build would trip over.
  defp clean_stale_erts(release) do
    for pattern <- ["unpacked_erts_*", "burrito_build_*"],
        leftover <- Path.wildcard(Path.join(System.tmp_dir!(), pattern)) do
      File.rm_rf(leftover)
    end

    release
  end

  def application do
    [
      mod: {Laev.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:burrito, "~> 1.0"}
    ]
  end
end
