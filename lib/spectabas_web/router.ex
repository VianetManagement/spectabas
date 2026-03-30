defmodule SpectabasWeb.Router do
  use SpectabasWeb, :router

  import SpectabasWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SpectabasWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug SpectabasWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug SpectabasWeb.Plugs.ApiRateLimit
    plug SpectabasWeb.Plugs.ApiAuth
  end

  pipeline :collect do
    plug :accepts, ["json"]
    plug SpectabasWeb.Plugs.AllowCors
    plug SpectabasWeb.Plugs.CollectRateLimit
  end

  pipeline :require_admin do
    plug SpectabasWeb.Plugs.RequireAdmin
  end

  # Health check — public (just returns ok/error)
  scope "/", SpectabasWeb do
    get "/health", HealthController, :show
  end

  # Diagnostic endpoints — admin only
  scope "/health", SpectabasWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    get "/diag", HealthController, :diag
    get "/backfill-geo", HealthController, :backfill_geo
    get "/dashboard-test", HealthController, :test_dashboard
    get "/audit-test", HealthController, :test_audit
  end

  # Collect endpoint — CORS, rate-limited, no CSRF
  scope "/c", SpectabasWeb do
    pipe_through :collect

    post "/e", CollectController, :create
    get "/p", CollectController, :pixel
    post "/i", CollectController, :identify
    post "/x", CollectController, :cross_domain
    post "/o", CollectController, :optout
    options "/e", CollectController, :options
  end

  # Script serving
  scope "/", SpectabasWeb do
    get "/assets/v1.js", ScriptController, :show
  end

  # Public pages
  scope "/", SpectabasWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/pricing", PageController, :pricing
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/email-reports/unsubscribe/:token", EmailReportController, :unsubscribe
  end

  # Invitation acceptance (public)
  scope "/invitations", SpectabasWeb do
    pipe_through :browser

    get "/:token", InvitationController, :accept
    post "/:token", InvitationController, :register
  end

  # Shared dashboard (public, token-protected)
  scope "/share", SpectabasWeb do
    pipe_through :browser

    live_session :shared_dashboard do
      live "/:token", SharedDashboardLive, :show
    end
  end

  # Auth routes
  scope "/", SpectabasWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{SpectabasWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/docs", DocsLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", SpectabasWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{SpectabasWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # 2FA routes
  scope "/auth/2fa", SpectabasWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :totp,
      on_mount: [{SpectabasWeb.UserAuth, :require_authenticated}] do
      live "/setup", Auth.TOTPSetupLive, :new
      live "/verify", Auth.TOTPVerifyLive, :new
    end
  end

  # Dashboard routes (authenticated)
  scope "/dashboard", SpectabasWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :dashboard,
      on_mount: [{SpectabasWeb.UserAuth, :require_authenticated}] do
      live "/", Dashboard.IndexLive, :index
      live "/sites/:site_id", Dashboard.SiteLive, :show
      live "/sites/:site_id/realtime", Dashboard.RealtimeLive, :show
      live "/sites/:site_id/pages", Dashboard.PagesLive, :index
      live "/sites/:site_id/channels", Dashboard.ChannelsLive, :index
      live "/sites/:site_id/bot-traffic", Dashboard.BotTrafficLive, :index
      live "/sites/:site_id/sources", Dashboard.SourcesLive, :index
      live "/sites/:site_id/geo", Dashboard.GeoLive, :index
      live "/sites/:site_id/entry-exit", Dashboard.EntryExitLive, :index
      live "/sites/:site_id/map", Dashboard.MapLive, :index
      live "/sites/:site_id/visitor-log", Dashboard.VisitorLogLive, :index
      live "/sites/:site_id/transitions", Dashboard.TransitionsLive, :index
      live "/sites/:site_id/attribution", Dashboard.AttributionLive, :index
      live "/sites/:site_id/search", Dashboard.SearchLive, :index
      live "/sites/:site_id/cohort", Dashboard.CohortLive, :index
      live "/sites/:site_id/insights", Dashboard.InsightsLive, :index
      live "/sites/:site_id/journeys", Dashboard.JourneysLive, :index
      live "/sites/:site_id/devices", Dashboard.DevicesLive, :index
      live "/sites/:site_id/network", Dashboard.NetworkLive, :index
      live "/sites/:site_id/campaigns", Dashboard.CampaignsLive, :index
      live "/sites/:site_id/visitors", Dashboard.VisitorsLive, :index
      live "/sites/:site_id/visitors/:visitor_id", Dashboard.VisitorLive, :show
      live "/sites/:site_id/goals", Dashboard.GoalsLive, :index
      live "/sites/:site_id/funnels", Dashboard.FunnelsLive, :index
      live "/sites/:site_id/ecommerce", Dashboard.EcommerceLive, :index
      live "/sites/:site_id/reports", Dashboard.ReportsLive, :index
      live "/sites/:site_id/performance", Dashboard.PerformanceLive, :index
      live "/sites/:site_id/outbound-links", Dashboard.OutboundLinksLive, :index
      live "/sites/:site_id/downloads", Dashboard.DownloadsLive, :index
      live "/sites/:site_id/events", Dashboard.EventsLive, :index
      live "/sites/:site_id/email-reports", Dashboard.EmailReportsLive, :index
      live "/sites/:site_id/exports", Dashboard.ExportLive, :index
      live "/sites/:site_id/settings", Dashboard.SettingsLive, :edit
    end
  end

  # Admin routes
  scope "/admin", SpectabasWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live_session :admin,
      on_mount: [{SpectabasWeb.UserAuth, :require_authenticated}] do
      live "/", Admin.DashboardLive, :index
      live "/users", Admin.UsersLive, :index
      live "/sites", Admin.SitesLive, :index
      live "/audit", Admin.AuditLive, :index
      live "/changelog", Admin.ChangelogLive, :index
      live "/competitive", Admin.CompetitiveLive, :index
    end
  end

  # API routes
  scope "/api/v1", SpectabasWeb.API do
    pipe_through :api

    get "/sites/:site_id/stats", StatsController, :overview
    get "/sites/:site_id/pages", StatsController, :pages
    get "/sites/:site_id/sources", StatsController, :sources
    get "/sites/:site_id/countries", StatsController, :countries
    get "/sites/:site_id/devices", StatsController, :devices
    get "/sites/:site_id/realtime", StatsController, :realtime
  end

  # Dev routes
  if Application.compile_env(:spectabas, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SpectabasWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
