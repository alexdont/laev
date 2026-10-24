defmodule Laev.MixProject do
  use Mix.Project

  def project do
    [
      app: :laev,
      version: "0.1.44",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Laev.CLI, path: "laev"],
      releases: releases(),
      deps: deps(),
      description: description(),
      package: package(),
      name: "laev",
      source_url: "https://github.com/alexdont/laev",
      docs: docs()
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

  defp description do
    "A terminal cinema: search, stream and track films, shows and anime through " <>
      "a debrid provider, with TMDB and MyAnimeList behind it. Usable as a library — " <>
      "the watchlist, stats, source resolution, settings and playback are all " <>
      "callable, per user, from anything that wants them."
  end

  # What goes in the package, and nothing else: the curated franchise data and
  # the player scripts are needed at runtime, while the release artifacts, the
  # build tooling and 200MB of binaries are not.
  defp package do
    [
      name: "laev",
      licenses: ["MIT"],
      maintainers: ["alexdont"],
      links: %{
        "GitHub" => "https://github.com/alexdont/laev",
        "Releases" => "https://github.com/alexdont/laev/releases"
      },
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "What you are watching": [Laev.Shelf, Laev.Stats, Laev.Position, Laev.Resume, Laev.Watchlist, Laev.Holds],
        "Finding and playing": [Laev.Sources, Laev.Providers, Laev.Playback, Laev.Player, Laev.Remux],
        "Metadata": [Laev.Tmdb, Laev.MAL, Laev.Anime, Laev.AnimeMap, Laev.Franchises, Laev.Kitsu],
        "Per user": [Laev.Scope, Laev.Settings, Laev.Config, Laev.Sync]
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      # Only ever used to wrap the standalone CLI binaries and to ask, at boot,
      # whether we are running as one. Optional so that anything depending on
      # laev as a library does not drag a binary-packaging tool along with it.
      {:burrito, "~> 1.0", optional: true},
      # Documentation only, and only when building it.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
