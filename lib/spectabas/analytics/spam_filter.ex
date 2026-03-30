defmodule Spectabas.Analytics.SpamFilter do
  @moduledoc "Filters known referrer spam domains from analytics queries."

  @spam_domains ~w(
    semalt.com buttons-for-website.com makemoneyonline.com
    best-seo-offer.com buy-cheap-online.info event-tracking.com
    free-share-buttons.com get-free-traffic-now.com
    hundredmb.com ilovevitaly.com trafficmonetize.org
    webmonetizer.net descargar-musica-gratis.me
    musclebuildfaster.com darodar.com hulfingtonpost.com
    priceg.com savetubevideo.com screentoolkit.com
    kambasoft.com econom.co socialmediascanner.com
  )

  @doc "Returns true if the given domain is a known referrer spam domain."
  def spam_domain?(domain) when is_binary(domain) do
    String.downcase(domain) in @spam_domains
  end

  def spam_domain?(_), do: false

  @doc "Returns the list of known spam domains."
  def spam_domains, do: @spam_domains
end
