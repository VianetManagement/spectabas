import Config

config :appsignal, :config,
  otp_app: :spectabas,
  name: "Spectabas",
  env: config_env(),
  enable_host_metrics: true,
  instrument_oban: true
