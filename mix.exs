defmodule Laev.MixProject do
  use Mix.Project

  def project do
    [
      app: :laev,
      version: "0.1.52",
      elixir: "~> 1.19",
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

  @beam_machine "https://beam-machine-universal.b-cdn.net"
  # The CDN asks for this, and burrito sends it on every fetch of its own.
  @be_kind "?please-respect-my-bandwidth-costs=thank-you"

  # `MIX_ENV=prod mix release laev` → burrito_out/laev_linux_x86_64:
  # a single self-contained binary (BEAM bundled, no Erlang needed on the
  # user's machine) — the artifact package managers ship.
  #
  # Build it with the Erlang the CDN has a build of, or `check_runtime!/1`
  # below will stop and say so:
  #
  #     MIX_ENV=prod mise exec erlang@29.0.6 zig@0.16.0 -- mix release laev --overwrite
  defp releases do
    [
      laev: [
        steps: [
          :assemble,
          &check_runtime!/1,
          &clean_stale_erts/1,
          &Burrito.wrap/1,
          &clean_stale_erts/1
        ],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # The runtime each binary bundles has to be *the same OTP version* the release
  # is compiled with, and nothing enforces that on its own.
  #
  # Burrito assembles the release out of the local Erlang, then replaces the NIF
  # libraries in it with the target platform's — matching them by path,
  # `lib/<app>-<version>/priv/lib/<name>.so`. So a bundle one patch release
  # apart is worse than useless: OTP 29.1.1 ships `asn1-5.5.2` and 29.1 ships
  # `asn1-5.5.1`, the macOS library lands in a directory the release does not
  # have, and the Linux `.so` stays where the release *does* look. Nothing fails
  # at build time. It fails at boot, on the user's machine, with
  #
  #     dlopen(...asn1-5.5.2/priv/lib/asn1rt_nif.so): slice is not valid mach-o file
  #
  # and the VM goes down with it. v0.1.50 shipped exactly that to macOS.
  #
  # Burrito asks the CDN for the version it is building with, which is right,
  # and 404s three screens deep when the CDN hasn't got it, which is how that
  # release came to be pinned to a near-miss. So the version is nothing to keep
  # here and update — it is whatever Erlang is building — and the only thing
  # asked of the CDN is that it has it. When it doesn't, the build stops here.
  defp check_runtime!(release) do
    version = otp_version()

    missing =
      for {os, url} <- [
            linux: "#{@beam_machine}/OTP-#{version}/linux/x86_64/any/otp_#{version}_linux_any_x86_64.tar.gz#{@be_kind}",
            macos: "#{@beam_machine}/OTP-#{version}/macos/universal/otp_#{version}_macos_universal.tar.gz#{@be_kind}"
          ],
          not served?(url),
          do: os

    if missing != [] do
      Mix.raise("""
      No prebuilt OTP #{version} for #{Enum.join(missing, " or ")} on the BEAM Machine CDN.

      The binaries bundle the OTP they are compiled with, so build this release
      with an Erlang the CDN carries — 29.0.6 is installed here and is what
      0.1.49 shipped:

          MIX_ENV=prod mise exec erlang@29.0.6 zig@0.16.0 -- mix release laev --overwrite

      Building it anyway produces a macOS binary that crashes at boot.
      """)
    end

    release
  end

  defp otp_version do
    [:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  # An answer of any kind is enough; a CDN that cannot be reached is not a
  # reason to stop a build, since burrito's own fetch would say so next.
  defp served?(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.head(url, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: status}} -> status < 400
      _ -> true
    end
  rescue
    _ -> true
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
