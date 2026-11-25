defmodule ChebitWeb.DashboardLiveTest do
  use ChebitWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Chebit.Outbox.Event

  describe "mount/3" do
    test "renders the header, the counts and the empty feed", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Chebit dashboard"
      assert html =~ "Payment intents by status"

      pid_html =
        view.pid |> inspect() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      assert render(view) =~ pid_html
      assert render(view) =~ "1 connected dashboard process"
    end
  end

  describe "handle_info/2 for a published event" do
    test "adds the event to the feed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      event = %Event{
        id: 987_654,
        type: "payment_intent.created",
        aggregate_type: "payment_intent",
        aggregate_id: "pi_demo_1",
        payload: %{}
      }

      Phoenix.PubSub.broadcast(Chebit.PubSub, "events", {:chebit_event, event})

      html = render(view)
      assert html =~ "payment_intent.created"
      assert html =~ "pi_demo_1"
      assert has_element?(view, "#events-987654")
    end
  end

  describe "handle_info/2 for a burst of events" do
    test "shows the first event at once and holds the next until the flush",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      first = demo_event(111_001, "pi_burst_1")
      second = demo_event(111_002, "pi_burst_2")
      send(view.pid, {:chebit_event, first})
      send(view.pid, {:chebit_event, second})

      assert has_element?(view, "#events-111001")
      refute has_element?(view, "#events-111002")

      send(view.pid, :flush)
      assert has_element?(view, "#events-111002")
      assert render(view) =~ "pi_burst_2"
    end
  end

  describe "handle_info/2 for run progress" do
    test "renders the bar, the counts and the backlog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      started = System.monotonic_time(:millisecond) - 1_000

      progress = %{
        total: 100_000,
        done: 2_500,
        failed: 3,
        started_ms: started,
        elapsed_ms: 1_000,
        status: :running
      }

      send(view.pid, {:simulation, progress})

      html = render(view)
      assert html =~ "2,500 / 100,000 done"
      assert html =~ "3 failed"
      assert html =~ "outbox backlog"

      send(view.pid, {:simulation_cancelled})
      assert render(view) =~ "cancelled"
    end
  end

  describe "handle_event/3 simulate_many, rejected input" do
    test "refuses a count that is not on a button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      assert render_click(view, "simulate_many", %{"count" => "7"}) =~ "Unknown count."
      assert render_click(view, "simulate_many", %{"count" => "1e9"}) =~ "Unknown count."
    end
  end

  describe "the simulate button" do
    test "creates a payment and a new event row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      view |> element("button", "Simulate payment") |> render_click()
      assert render(view) =~ "Payment simulated"

      # Tests run the outbox job by hand. The test sink replaces PubSub, so the test
      # forwards the published event the way the real sink does.
      Oban.drain_queue(queue: :outbox)
      assert_receive {:outbox_published, %Event{type: type} = event}
      Phoenix.PubSub.broadcast(Chebit.PubSub, "events", {:chebit_event, event})

      assert render(view) =~ type
      assert has_element?(view, "#events-#{event.id}")
    end
  end

  defp demo_event(id, aggregate_id) do
    %Event{
      id: id,
      type: "payment_intent.created",
      aggregate_type: "payment_intent",
      aggregate_id: aggregate_id,
      payload: %{}
    }
  end
end
