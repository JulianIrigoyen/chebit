// Connects the LiveView socket. phoenix.min.js and phoenix_live_view.min.js
// load before this file and define the globals Phoenix and LiveView.
const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content")

const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: {_csrf_token: csrfToken},
})

liveSocket.connect()
window.liveSocket = liveSocket
