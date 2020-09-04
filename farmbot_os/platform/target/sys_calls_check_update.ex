defmodule FarmbotOS.SysCalls.CheckUpdate do
  require FarmbotCore.Logger

  alias FarmbotCore.JSON
  alias FarmbotCore.Config

  @skip %{"image_url" => nil}
  @release_path "/api/releases?platform="
  @double_flash_error "A software update is already in progress. Please wait."
  @dl_path '/root/upgrade.fw'

  def check_update() do
    get_target()
    |> download_meta_data()
    |> Map.get("image_url", nil)
    |> install_update()

    FarmbotCore.Logger.debug(3, "Going down for reboot.")
    FarmbotCeleryScript.SysCalls.reboot()
    :ok
  end

  # Determines if there is an OTA update in progress.
  # Running two OTAs at the same time can have disasterous
  # side effects. We use @dl_path as a lock file to prevent
  # this. No lock file == no OTA in progress.
  defp in_progress?(path \\ to_string(@dl_path)) do
    File.exists?(path)
  end

  # Delete @dl_path so that the user can run an OTA again.
  # This also conserves SD card space.
  defp clean_up() do
    if in_progress?() do
      FarmbotCore.Logger.debug(3, "Cleaning up file artifacts.")
      File.rm!(to_string(@dl_path))
    end
  end

  # Flash the SD card parititon with the new *.fw file using
  # FWUP.
  defp do_flash_firmware() do
    msg = "Finished downloading upgrade. Begin installation."
    FarmbotCore.Logger.debug(3, msg)

    path_string = to_string(@dl_path)
    args = ["-a", "-i", path_string, "-d", "/dev/mmcblk0", "-t", "upgrade"]

    {_, 0} = System.cmd("fwup", args)
  end

  # Downloads an arbitrary URL to @dl_path
  defp download_update_image(url) do
    FarmbotCore.Logger.debug(3, "Downloading FBOS upgrade from #{url}")
    params = {to_charlist(url), []}

    {:ok, :saved_to_file} = :httpc.request(:get, params, [], stream: @dl_path)
  end

  # Crash the current process if there is already an OTA in
  # progress.
  defp prevent_double_installation!() do
    if in_progress?() do
      FarmbotCore.Logger.error(3, @double_flash_error)
      raise @double_flash_error
    end
  end

  # Bails out of an OTA early if no image URL is provided by
  # the server or if an error occurs.
  defp install_update(nil) do
    FarmbotCore.Logger.debug(3, "Not downloading update.")
  end

  # Upgrades the device to an arbitrary URL pointing to a
  # *.fw file.
  defp install_update(url) do
    try do
      prevent_double_installation!()
      download_update_image(url)
      do_flash_firmware()
    after
      clean_up()
    end
  end

  # :httpc callback when a JSON download succeeds (/api/releases?platform=foo)
  defp handle_http_response({:ok, {_status_line, _response_headers, body}}) do
    {:ok, map} = JSON.decode(body)
    map
  end

  # :httpc callback when a JSON download fails (/api/releases?platform=foo)
  defp handle_http_response(error) do
    e = "Error downloading update. Please try again. #{inspect(error)}"
    FarmbotCore.Logger.error(3, e)
    @skip
  end

  # Fetch a release object for a particular Nerves target.
  # Note that a release is a JSON objecting that contains a
  # URL to a *.fw. It is _not_ a *.fw, however.
  defp download_meta_data(target) do
    # TODO: Hard code this value to `my.farm.bot` so that self-hosters can stay
    #       up-to-date without managing releases.
    server = Config.get_config_value(:string, "authorization", "server")
    url = to_charlist(server <> @release_path <> target)
    FarmbotCore.Logger.debug(3, "Downloading meta data from #{url}")
    http_resp = :httpc.request(:get, {to_charlist(url), []}, [], [])
    handle_http_response(http_resp)
  end

  # Heuristic to determine the current Nerves target.
  # TODO: Is there a better way to do this?
  defp get_target() do
    # Read value set by
    try do
      apply(Nerves.Runtime.KV, :get_active, ["nerves_fw_platform"])
    rescue
      error ->
        e = inspect(error)
        FarmbotCore.Logger.error(3, "Error getting target meta data: #{e}")
        "none"
    end
  end
end
