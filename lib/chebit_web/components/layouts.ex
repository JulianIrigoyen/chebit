defmodule ChebitWeb.Layouts do
  @moduledoc """
  The layouts of the browser pages. Only the dev dashboard uses them.

  `root/1` is the HTML shell with the CSRF meta tag and the scripts. `app/1` wraps the
  page and shows the flash messages.
  """
  use ChebitWeb, :html

  embed_templates "layouts/*"
end
