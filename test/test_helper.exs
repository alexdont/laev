# Starting the app must not reach into anybody's Real-Debrid account: the
# launch sweep deletes torrents, and a test run is not a launch.
Application.put_env(:laev, :sweep_on_boot, false)

ExUnit.start()
