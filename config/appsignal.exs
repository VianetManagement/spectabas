import Config

config :appsignal, :config,
  otp_app: :spectabas,
  name: "Spectabas",
  push_api_key: System.get_env("APPSIGNAL_PUSH_API_KEY") || "",
  env: config_env(),
  active: config_env() == :prod,
  enable_host_metrics: true,
  instrument_oban: true
