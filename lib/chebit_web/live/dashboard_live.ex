defmodule ChebitWeb.DashboardLive do
  @moduledoc """
  A live dev dashboard. It exists only where `dev_routes` is on, because it shows the data
  of every merchant.

  Each browser tab gets one LiveView process: the header shows its pid. The page connects
  over a WebSocket. The process subscribes to the `"events"` topic. When the outbox
  publishes `{:chebit_event, event}`, the process adds the event to the feed, reads the
  counts and balances again, and LiveView sends only the changed parts of the page.
  """
  use ChebitWeb, :live_view

  alias Chebit.Ledger
  alias Chebit.Merchants
  alias Chebit.Outbox
  alias Chebit.Payments
  alias Chebit.Payments.StateMachine
  alias ChebitWeb.DashboardSimulation

  @feed_size 30
  @viewer_refresh_ms 2_000
  @dev_merchant "Dev Cafe"
  # A bulk run makes thousands of events a second. The page shows the first event at once,
  # then at most one update per `@flush_ms`: it holds the newest events in `:buffer` and
  # reads the totals once per flush, not once per event.
  @flush_ms 500
  @bulk_counts [100, 100_000, 1_000_000]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Chebit.PubSub, "events")
      Phoenix.PubSub.subscribe(Chebit.PubSub, DashboardSimulation.topic())
      {:ok, _owner} = Registry.register(ChebitWeb.DashboardRegistry, :viewers, nil)
      Process.send_after(self(), :refresh_viewers, @viewer_refresh_ms)
    end

    socket =
      socket
      |> assign(:pid, inspect(self()))
      |> assign(:viewers, viewer_count())
      # The flow diagram replays its animation when `:pulse` changes. `:pulse_from` says
      # which half lights up: the click path (steps 1-4) or the event path (steps 5-8).
      |> assign(:pulse, 0)
      |> assign(:pulse_from, nil)
      |> assign(:last_message, nil)
      |> assign(:buffer, [])
      |> assign(:flush_scheduled, false)
      # nil until the first flush. Monotonic time can be negative, so 0 is not "long ago".
      |> assign(:last_flush_ms, nil)
      |> assign(:events_seen, 0)
      |> assign(:run, nil)
      |> assign(:bulk_counts, @bulk_counts)
      |> stream(:events, Enum.reverse(Outbox.recent(@feed_size)), at: 0, limit: @feed_size)
      |> load_totals()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:chebit_event, event}, socket) do
    socket =
      socket
      |> assign(:buffer, Enum.take([event | socket.assigns.buffer], @feed_size))
      |> assign(:events_seen, socket.assigns.events_seen + 1)

    since =
      case socket.assigns.last_flush_ms do
        nil -> @flush_ms
        last -> now_ms() - last
      end

    cond do
      since >= @flush_ms -> {:noreply, flush(socket)}
      socket.assigns.flush_scheduled -> {:noreply, socket}
      true -> {:noreply, schedule_flush(socket, @flush_ms - since)}
    end
  end

  def handle_info(:flush, socket) do
    {:noreply, socket |> assign(:flush_scheduled, false) |> flush()}
  end

  def handle_info({:simulation, progress}, socket) do
    {:noreply, assign(socket, :run, progress)}
  end

  def handle_info({:simulation_cancelled}, socket) do
    run = socket.assigns.run && %{socket.assigns.run | status: :cancelled}
    {:noreply, assign(socket, :run, run)}
  end

  def handle_info(:refresh_viewers, socket) do
    Process.send_after(self(), :refresh_viewers, @viewer_refresh_ms)
    {:noreply, assign(socket, :viewers, viewer_count())}
  end

  @impl Phoenix.LiveView
  def handle_event("simulate", _params, socket) do
    socket = pulse(socket, :click)

    case simulate_payment() do
      :ok -> {:noreply, put_flash(socket, :info, "Payment simulated. Events follow.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("simulate_many", %{"count" => raw}, socket) do
    # Only the counts on the buttons. Anything else from the browser is refused.
    with {count, ""} <- Integer.parse(raw),
         true <- count in @bulk_counts,
         :ok <- DashboardSimulation.start(count) do
      {:noreply, socket |> pulse(:click) |> clear_flash()}
    else
      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "A run is already going. Cancel it first.")}

      _refused ->
        {:noreply, put_flash(socket, :error, "Unknown count.")}
    end
  end

  def handle_event("cancel_run", _params, socket) do
    :ok = DashboardSimulation.cancel()
    {:noreply, socket}
  end

  # The same path as the API: create (idempotent on the key), confirm, then the simulated
  # payer pays and its webhook goes through the signed webhook intake.
  defp simulate_payment do
    with {:ok, merchant} <- Merchants.get_or_create(@dev_merchant) do
      DashboardSimulation.run_one(merchant)
    end
  end

  defp flush(socket) do
    case socket.assigns.buffer do
      [] ->
        socket

      [newest | _older] = events ->
        socket =
          Enum.reduce(Enum.reverse(events), socket, fn event, acc ->
            stream_insert(acc, :events, event, at: 0, limit: @feed_size)
          end)

        socket
        |> assign(:buffer, [])
        |> assign(:last_flush_ms, now_ms())
        |> load_totals()
        |> pulse(:event)
        |> assign(:last_message, describe_message(newest))
    end
  end

  defp schedule_flush(socket, delay_ms) do
    Process.send_after(self(), :flush, delay_ms)
    assign(socket, :flush_scheduled, true)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp format_error(%Ecto.Changeset{} = changeset),
    do: "Simulation failed: invalid input #{inspect(changeset.errors)}"

  defp format_error(reason), do: "Simulation failed: #{inspect(reason)}"

  defp pulse(socket, from) do
    socket
    |> assign(:pulse, socket.assigns.pulse + 1)
    |> assign(:pulse_from, from)
  end

  # The message as this process received it, short enough to read.
  defp describe_message(event) do
    "{:chebit_event, %Event{id: #{event.id}, type: #{inspect(event.type)}, " <>
      "aggregate: #{event.aggregate_type} #{event.aggregate_id}}}"
  end

  defp viewer_count, do: ChebitWeb.DashboardRegistry |> Registry.count()

  # Cheap, and the page is dev only: read again on each event.
  defp load_totals(socket) do
    counts = Payments.count_by_status()

    socket
    |> assign(:status_counts, Enum.map(StateMachine.statuses(), &{&1, Map.get(counts, &1, 0)}))
    |> assign(:accounts, Ledger.list_accounts())
    |> assign(:backlog, Outbox.count_pending())
  end

  defp rate(%{done: done, elapsed_ms: elapsed}) do
    seconds = max(elapsed, 1) / 1000
    round(done / seconds)
  end

  defp eta(%{total: total, done: done} = run) do
    per_second = rate(run)
    if per_second > 0, do: format_seconds(div(total - done, per_second)), else: "…"
  end

  defp format_seconds(s) when s < 60, do: "#{s}s"
  defp format_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <header>
      <div>
        <h1>Chebit dashboard</h1>
        <p class="meta">
          LiveView process <span class="mono">{@pid}</span>
          &middot; {@viewers} connected dashboard {if @viewers == 1, do: "process", else: "processes"}
        </p>
      </div>
      <div class="actions">
        <button phx-click="simulate" phx-disable-with="Simulating...">Simulate payment</button>
        <button
          :for={n <- @bulk_counts}
          class="ghost"
          phx-click="simulate_many"
          phx-value-count={n}
          disabled={@run && @run.status == :running}
        >
          Simulate {number(n)}
        </button>
      </div>
    </header>

    <section :if={@run} class="explain run">
      <h2>
        Bulk run · {number(@run.total)} payments · {@run.status}
        <button :if={@run.status == :running} class="ghost small" phx-click="cancel_run">
          Cancel
        </button>
      </h2>
      <div class="bar">
        <div class="fill" style={"width: #{Float.round(@run.done * 100 / @run.total, 1)}%"}></div>
      </div>
      <p class="stats mono">
        {number(@run.done)} / {number(@run.total)} done · {number(@run.failed)} failed ·
        {number(rate(@run))} payments/s
        <span :if={@run.status == :running}>· about {eta(@run)} left</span>
      </p>
      <p class="stats mono">
        outbox backlog: {number(@backlog)} events not yet published ·
        this page received {number(@events_seen)} events
      </p>
      <p class="caption">
        The run is one background process (a Task) that runs 8 payments at a time:
        <code>Task.async_stream(max_concurrency: 8)</code>, under the Repo pool of 10, so this
        page can still read. Each payment writes ~4 outbox events. The outbox queue publishes
        <b>one event at a time</b> (Oban queue <code>outbox: 1</code>, to keep the order), so the
        backlog grows while the run is faster than the publisher: the feed falls behind and
        catches up after the run. This page does not redraw per event: it shows the first one at
        once, then at most one update every 500 ms (the newest 30 events and the totals).
      </p>
    </section>

    <section class="explain">
      <h2>1 · The path of one click (it lights up as it happens)</h2>
      <ol id={"flow-#{@pulse}"} class={["flow", @pulse_from && "from-#{@pulse_from}"]}>
        <li class="step click">
          <b>1 Browser</b> You click. <code>phx-click="simulate"</code>
        </li>
        <li class="step click">
          <b>2 WebSocket</b> The event goes up the open socket. No HTTP request.
        </li>
        <li class="step click">
          <b>3 This process</b> <code>handle_event("simulate")</code> runs here, in <span class="mono">{@pid}</span>.
        </li>
        <li class="step click">
          <b>4 Postgres, one transaction</b> The state change + its outbox row + an Oban job. All commit or none.
        </li>
        <li class="step event">
          <b>5 Oban PublishWorker</b> After the commit, it reads the outbox row.
        </li>
        <li class="step event">
          <b>6 PubSub "events"</b> One broadcast. Every subscribed process gets a copy.
        </li>
        <li class="step event">
          <b>7 Each dashboard process</b> <code>handle_info(&lbrace;:chebit_event, e&rbrace;)</code>: insert into the feed, read totals again.
        </li>
        <li class="step event">
          <b>8 Diff down the WebSocket</b> Only the changed parts. The browser patches the page.
        </li>
      </ol>
      <p class="caption">
        Steps 1–4 run because <em>you</em> clicked. Steps 5–8 run for <em>every</em> open tab,
        even one where nobody clicked. One click makes several events (created, confirmed,
        succeeded…), so 5–8 light up once per event.
      </p>
      <p class="lastmsg">
        <span class="label">Last message this process got:</span>
        <code :if={@last_message}>{@last_message}</code>
        <span :if={!@last_message} class="empty">none yet. Click "Simulate payment".</span>
      </p>
    </section>

    <section class="explain">
      <h2>2 · One process per tab</h2>
      <div class="procs">
        <div class="proc-col">
          <div :for={n <- 1..max(@viewers, 1)} class={["proc", n == 1 && "me"]}>
            <span class="box tab">Browser tab {if n == 1, do: "(this one)", else: n}</span>
            <span class="wire">⇄ WebSocket ⇄</span>
            <span class="box pid">
              LiveView process {if n == 1, do: @pid, else: "#PID<…>"}
            </span>
          </div>
        </div>
        <div class="fan">
          <span class="wire">◀ copy to each</span>
          <span class="box hub">PubSub topic <code>"events"</code></span>
          <span class="wire">◀</span>
          <span class="box src">Outbox PublishWorker</span>
        </div>
      </div>
      <p class="caption">
        {@viewers} {if @viewers == 1, do: "process is", else: "processes are"} connected now.
        Open this page in another tab: a new process starts and this count goes up.
        Close it: that process dies and the count drops within 2 seconds. Each process holds
        its own state (the feed, the totals) in memory on the server. The browser holds none.
      </p>
    </section>

    <div class="grid">
      <div>
        <section>
          <h2>Payment intents by status</h2>
          <table>
            <tbody>
              <tr :for={{status, count} <- @status_counts}>
                <td>{status}</td>
                <td class="num">{count}</td>
              </tr>
            </tbody>
          </table>
          <p class="caption">
            Each intent moves forward through a state machine and never back. A click takes
            one intent from <code>created</code> to <code>pending</code>, <code>paid</code>
            and <code>final</code>.
          </p>
        </section>

        <section>
          <h2>Ledger accounts</h2>
          <p class="caption">
            Double entry: every transaction adds debits and credits that sum to zero, so a
            merchant's balance going up means a provider account went the other way.
            <code>held_minor</code> is money reserved but not yet free to spend. Amounts are
            integers in cents (<code>_minor</code>), never floats.
          </p>
          <table>
            <thead>
              <tr>
                <th>owner</th>
                <th>kind</th>
                <th class="num">balance_minor</th>
                <th class="num">held_minor</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{balance: b, owner_type: owner} <- @accounts}>
                <td>{owner}</td>
                <td>{b.kind}</td>
                <td class="num mono">{b.balance_minor} {b.currency}</td>
                <td class="num mono">{b.held_minor} {b.currency}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@accounts == []} class="empty">No accounts yet.</p>
        </section>
      </div>

      <section>
        <h2>Outbox events (last 30)</h2>
        <p class="caption">
          Each row was written in the same transaction as the change it describes, then
          published after the commit. New rows arrive at the top without a reload: that is
          step 7 above. Only the new row travels down the WebSocket.
        </p>
        <ul id="events" class="feed" phx-update="stream">
          <li :for={{dom_id, event} <- @streams.events} id={dom_id}>
            <span class="id mono">#{event.id}</span>
            <span>
              <span class="type">{event.type}</span>
              <span class="agg mono">{event.aggregate_type} {event.aggregate_id}</span>
            </span>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
