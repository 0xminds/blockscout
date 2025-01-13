defmodule Explorer.Migrator.HeavyDbIndexOperation do
  @moduledoc """
  Provides a template for making heavy DB operations such as creation/deletion of new indexes in the large tables
  with tracking status of those migrations.
  """

  @doc """
  This callback returns the name of the migration. The name is used to track the operation's status in
  `Explorer.Migrator.MigrationStatus`.
  """
  @callback migration_name :: String.t()

  @doc """
  This callback returns the string with a psql query to initialize DB operation like creation or deletion of the index.
  """
  @callback db_index_operation :: :ok | :error

  @doc """
  This callback checks DB index operation (creation or deletion) status.
  """
  @callback check_db_index_operation_progress() ::
              :finished_or_not_started | :finished | :unknown | {:in_progress, String.t()}

  @doc """
  This callback checks existence of DB index and its validity.
  """
  @callback db_index_exists_and_valid?() ::
              %{
                :exists? => boolean(),
                :valid? => boolean() | nil
              }
              | :unknown

  @doc """
  This callback completes initial index operation.
  """
  @callback complete_db_index_operation() :: :ok | :error

  @doc """
    This callback updates the migration completion status in the cache.

    The callback is invoked in two scenarios:
    - When the migration is already marked as completed during process initialization
    - When the migration finishes processing all entities

    The implementation updates the in-memory cache that tracks migration completion
    status, which is used during application startup and by performance-critical
    operations to quickly determine if specific data migrations have been completed.
    Some migrations may not require cache updates if their completion status does not
    affect system operations.

    ## Returns
    N/A
  """
  @callback update_cache :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour Explorer.Migrator.HeavyDbIndexOperation

      use GenServer, restart: :transient

      import Ecto.Query

      alias Ecto.Adapters.SQL
      alias Explorer.Migrator.MigrationStatus
      alias Explorer.Repo

      def start_link(_) do
        GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      end

      @spec migration_finished? :: boolean()
      def migration_finished? do
        MigrationStatus.get_status(migration_name()) == "completed"
      end

      @impl true
      def init(_) do
        {:ok, %{}, {:continue, :ok}}
      end

      @impl true
      def handle_continue(:ok, state) do
        Process.send(self(), :initiate_index_operation, [])
        {:noreply, state}
      end

      @impl true
      def handle_info(:check_db_index_operation_progress, state) do
        with {:index_operation_progress, status} when status in [:finished_or_not_started, :finished] <-
               {:index_operation_progress, check_db_index_operation_progress()},
             {:db_index_exists_and_valid?, %{exists?: false, valid?: nil}} <-
               {:db_index_exists_and_valid?, db_index_exists_and_valid?()} do
          MigrationStatus.set_status(migration_name(), "started")
          db_index_operation()
          schedule_next_db_operation_status_check()
          {:noreply, state}
        else
          {:index_operation_progress, _status} ->
            schedule_next_db_operation_status_check()
            {:noreply, state}

          {:db_index_exists_and_valid?, %{exists?: true, valid?: false}} ->
            Process.send(self(), :index_drop, [])
            {:noreply, state}

          {:db_index_exists_and_valid?, %{exists?: true, valid?: true}} ->
            MigrationStatus.set_status(migration_name(), "completed")
            {:stop, :normal, state}
        end
      end

      @impl true
      def handle_info(:initiate_index_operation, state) do
        case MigrationStatus.fetch(migration_name()) do
          %{status: "completed"} ->
            update_cache()
            {:stop, :normal, state}

          migration_status ->
            Process.send(self(), :check_db_index_operation_progress, [])
            {:noreply, state}
        end
      end

      @impl true
      def handle_info(:index_drop, state) do
        case complete_db_index_operation() do
          :ok ->
            Process.send(self(), :initiate_index_operation, [])
            {:noreply, state}

          :error ->
            schedule_next_index_drop()
        end
      end

      defp schedule_next_db_operation_status_check(timeout \\ nil) do
        Process.send_after(
          self(),
          :check_db_index_operation_progress,
          timeout || Application.get_env(:explorer, __MODULE__)[:check_interval] || :timer.minutes(10)
        )
      end

      defp schedule_next_index_drop(timeout \\ nil) do
        Process.send_after(
          self(),
          :index_drop,
          timeout || :timer.seconds(10)
        )
      end
    end
  end
end
