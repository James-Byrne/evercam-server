defmodule EvercamMedia.Snapshot.WorkerSupervisor do
  @moduledoc """
  This supervisor creates EvercamMedia.Snapshot.Worker using the strategy
  :simple_one_for_one and can only handle one child type of children.

  Since we want to dynamically create/kill EvercamMedia.Snapshot.Worker for the cameras,
  other types of strategies in supervisor are not suitable.

  When creating a new worker, the supervisor passes on a list of @event_handlers.
  @event_handlers are the handlers that wants to react to the events generated by
  EvercamMedia.Snapshot.Worker. These handlers are automatically added to the
  event manager for every created worker.
  """

  use Supervisor
  require Logger

  @event_handlers [
    EvercamMedia.Snapshot.BroadcastHandler,
    EvercamMedia.Snapshot.CacheHandler,
    EvercamMedia.Snapshot.DBHandler,
    EvercamMedia.Snapshot.PollHandler,
    EvercamMedia.Snapshot.S3UploadHandler,
    # EvercamMedia.Snapshot.StatsHandler
    EvercamMedia.MotionDetection.ComparatorHandler
  ]

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    unless Application.get_env(:evercam_media, :skip_camera_workers) do
      Task.start_link(&EvercamMedia.Snapshot.WorkerSupervisor.initiate_workers/0)
    end
    children = [worker(EvercamMedia.Snapshot.Worker, [], restart: :transient)]
    supervise(children, strategy: :simple_one_for_one)
  end

  @doc """
  Start
  """
  def start_worker(camera) do
    case get_config(camera) do
      {:ok, settings} ->
        Logger.info "Starting worker for #{settings.config.camera_exid}"
        Supervisor.start_child(__MODULE__, [settings])
      {:error, message, url} ->
        Logger.error "Skipping camera worker as the host is invalid: #{camera.exid}: #{url}"
    end
  end

  @doc """
  Start a workers for each camera in the database.

  This function is intended to be called after the EvercamMedia.Snapshot.WorkerSupervisor
  is initiated.
  """
  def initiate_workers do
    Camera
    |> EvercamMedia.Repo.all([timeout: 15000])
    |> Enum.map(&(start_worker &1))
  end


  @doc """
  Given a camera, it returns a map of values required for starting a camera worker.
  """
  def get_config(camera) do
    url = "#{Camera.external_url(camera)}#{Camera.res_url(camera, "jpg")}"
    parsed_uri = URI.parse url

    if parsed_uri.host != nil && parsed_uri.port > 0 && parsed_uri.port < 65535 do
        #TODO: There seems to be more db queries than necessary. Cut it down.
        camera = EvercamMedia.Repo.preload camera, :cloud_recordings
        {:ok, %{
            event_handlers: @event_handlers,
            name: camera.exid |> String.to_atom,
            config: %{
              camera_id: camera.id,
              camera_exid: camera.exid,
              vendor_exid: Camera.get_vendor_exid_by_camera_exid(camera.exid),
              schedule: Camera.schedule(camera),
              timezone: camera.timezone,
              url: url,
              auth: Camera.auth(camera),
              sleep: Camera.sleep(camera),
              initial_sleep: Camera.initial_sleep(camera)
            }
          }
        }
    else
        {:error, "Invalid url for camera", url}
    end
  end

end
