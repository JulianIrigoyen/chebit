[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view, :oban, :stream_data],
  subdirectories: ["priv/*/migrations"],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]
