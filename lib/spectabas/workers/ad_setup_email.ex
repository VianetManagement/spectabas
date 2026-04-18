defmodule Spectabas.Workers.AdSetupEmail do
  @moduledoc "One-shot: sends ad platform setup instructions email. Self-deletes after first run."

  use Oban.Worker, queue: :mailer, max_attempts: 1

  import Swoosh.Email
  alias Spectabas.Mailer

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(_job) do
    html = ad_setup_html()
    text = ad_setup_text()

    email =
      new()
      |> to({"Jeff", "jeff@vianet.us"})
      |> from({"Spectabas", "noreply@spectabas.com"})
      |> subject("Spectabas Ad Platform Setup — UTM Configuration Guide")
      |> html_body(html)
      |> text_body(text)

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ad_setup_html do
    """
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 680px; margin: 0 auto; color: #1f2937; line-height: 1.6;">
      <div style="background: #4f46e5; padding: 24px 32px; border-radius: 8px 8px 0 0;">
        <h1 style="color: white; margin: 0; font-size: 22px;">Ad Platform Setup Guide</h1>
        <p style="color: #c7d2fe; margin: 4px 0 0; font-size: 14px;">Maximize Spectabas ad tracking for roommates.com</p>
      </div>

      <div style="padding: 32px; border: 1px solid #e5e7eb; border-top: 0; border-radius: 0 0 8px 8px;">

        <p style="font-size: 15px;">Here's exactly what to configure in each ad platform to get the most out of Spectabas's ad effectiveness tracking. There are two layers: <strong>click IDs</strong> (automatic, verifies the click) and <strong>UTM parameters</strong> (tells us which specific campaign/ad group drove the visit).</p>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- GOOGLE ADS -->
        <h2 style="color: #1d4ed8; font-size: 18px; margin-bottom: 8px;">🔵 Google Ads</h2>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 1: Verify Auto-Tagging is ON</h3>
        <p style="font-size: 14px;">This enables <code style="background: #f3f4f6; padding: 2px 6px; border-radius: 4px;">gclid</code> — Spectabas captures this automatically for platform-level ROAS.</p>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Go to <strong>Google Ads → Settings → Account Settings</strong></li>
          <li>Find <strong>"Auto-tagging"</strong></li>
          <li>Ensure <strong>"Tag the URL that people click through from my ad"</strong> is checked</li>
        </ol>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 2: Set Up Account-Level URL Tracking Template</h3>
        <p style="font-size: 14px;">This adds UTM parameters to ALL your ad URLs automatically. Do this at the <strong>account level</strong> so every campaign inherits it.</p>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Go to <strong>Google Ads → Settings → Account Settings</strong></li>
          <li>Scroll to <strong>"Tracking"</strong></li>
          <li>In <strong>"Tracking template"</strong>, paste this exactly:</li>
        </ol>
        <div style="background: #1e293b; color: #e2e8f0; padding: 12px 16px; border-radius: 6px; font-family: monospace; font-size: 13px; overflow-x: auto; margin: 12px 0;">
          {lpurl}?utm_source=google&amp;utm_medium=cpc&amp;utm_campaign={campaignname}&amp;utm_term={keyword}&amp;utm_content={creative}
        </div>
        <p style="font-size: 13px; color: #6b7280;"><strong>What the ValueTrack parameters do:</strong></p>
        <table style="width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0;">
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{campaignname}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Your campaign name → enables campaign-level ROAS in Spectabas</td>
          </tr>
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{keyword}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Search keyword that triggered the ad → shows in UTM Term tab</td>
          </tr>
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{creative}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Ad creative ID → shows in UTM Content tab</td>
          </tr>
        </table>

        <div style="background: #fefce8; border-left: 4px solid #eab308; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Important:</strong> After saving, click <strong>"Test"</strong> to verify the template works. Google will show the expanded URL — confirm UTM parameters appear correctly.
        </div>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 3: Verify in Spectabas</h3>
        <p style="font-size: 14px;">After a day of ad traffic:</p>
        <ul style="font-size: 14px; padding-left: 20px;">
          <li><strong>/admin/ingest</strong> → Click ID Attribution section should show Google Ads events</li>
          <li><strong>Revenue Attribution → Campaign tab</strong> → should show your campaign names with ROAS</li>
          <li><strong>Visitor Quality</strong> → should show Google Ads scores</li>
        </ul>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- BING ADS -->
        <h2 style="color: #0891b2; font-size: 18px; margin-bottom: 8px;">🟦 Microsoft / Bing Ads</h2>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 1: Verify Auto-Tagging (msclkid)</h3>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Go to <strong>Microsoft Advertising → Settings → Account-level options</strong></li>
          <li>Under <strong>"Microsoft click ID"</strong>, ensure auto-tagging is <strong>enabled</strong></li>
        </ol>
        <p style="font-size: 13px; color: #6b7280;">This is on by default in most accounts. Spectabas captures <code style="background: #f3f4f6; padding: 2px 6px; border-radius: 4px;">msclkid</code> automatically.</p>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 2: Set Up Account-Level Tracking Template</h3>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Go to <strong>Microsoft Advertising → Settings → Account-level options</strong></li>
          <li>Find <strong>"Tracking template"</strong></li>
          <li>Paste this:</li>
        </ol>
        <div style="background: #1e293b; color: #e2e8f0; padding: 12px 16px; border-radius: 6px; font-family: monospace; font-size: 13px; overflow-x: auto; margin: 12px 0;">
          {lpurl}?utm_source=bing&amp;utm_medium=cpc&amp;utm_campaign={CampaignName}&amp;utm_term={keyword}&amp;utm_content={AdId}
        </div>
        <p style="font-size: 13px; color: #6b7280;"><strong>Note:</strong> Bing uses <code>{CampaignName}</code> (PascalCase) not <code>{campaignname}</code> (lowercase). The parameter names are case-sensitive.</p>

        <table style="width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0;">
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{CampaignName}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Campaign name → campaign-level ROAS</td>
          </tr>
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{keyword}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Search keyword → UTM Term tab</td>
          </tr>
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{AdId}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Ad ID → UTM Content tab</td>
          </tr>
        </table>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- META ADS -->
        <h2 style="color: #6366f1; font-size: 18px; margin-bottom: 8px;">🟣 Meta / Facebook Ads</h2>

        <p style="font-size: 14px;"><strong>fbclid</strong> is appended automatically — Spectabas captures this for platform-level attribution. But Meta does NOT support account-level tracking templates, so UTM parameters must be set per campaign.</p>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 1: Add URL Parameters to Each Campaign</h3>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>Open a campaign in <strong>Ads Manager</strong></li>
          <li>Go to the <strong>Ad</strong> level (not campaign or ad set)</li>
          <li>Scroll to <strong>"Tracking"</strong> section</li>
          <li>In <strong>"URL parameters"</strong>, paste:</li>
        </ol>
        <div style="background: #1e293b; color: #e2e8f0; padding: 12px 16px; border-radius: 6px; font-family: monospace; font-size: 13px; overflow-x: auto; margin: 12px 0;">
          utm_source=facebook&amp;utm_medium=paid_social&amp;utm_campaign={{campaign.name}}&amp;utm_content={{ad.name}}
        </div>

        <table style="width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0;">
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{{campaign.name}}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Campaign name → campaign-level ROAS. Note the double curly braces.</td>
          </tr>
          <tr style="border-bottom: 1px solid #e5e7eb;">
            <td style="padding: 6px 8px;"><code>{{ad.name}}</code></td>
            <td style="padding: 6px 8px; color: #4b5563;">Ad creative name → UTM Content tab</td>
          </tr>
        </table>

        <div style="background: #fefce8; border-left: 4px solid #eab308; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Important:</strong> You must add URL parameters at the <strong>ad level</strong>, not campaign level. If you create ads via bulk tools, use the <strong>URL Parameters</strong> column in your spreadsheet. For new campaigns, consider creating a campaign template with UTM parameters pre-filled.
        </div>

        <h3 style="font-size: 15px; margin-top: 20px;">Step 2 (Optional): Use Bulk Edit for Existing Campaigns</h3>
        <ol style="font-size: 14px; padding-left: 20px;">
          <li>In Ads Manager, select all active ads</li>
          <li>Click <strong>"Edit"</strong> in the toolbar</li>
          <li>Scroll to <strong>Tracking → URL Parameters</strong></li>
          <li>Paste the URL parameters string above</li>
          <li>Click <strong>"Publish"</strong></li>
        </ol>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- CAMPAIGN NAMING -->
        <h2 style="font-size: 18px; margin-bottom: 8px;">📋 Campaign Naming Best Practices</h2>

        <p style="font-size: 14px;">For maximum utility across all 5 Ad Effectiveness pages, use consistent campaign names:</p>

        <ul style="font-size: 14px; padding-left: 20px;">
          <li><strong>Use lowercase with hyphens</strong> — <code>spring-promo-2026</code> not <code>Spring Promo 2026</code></li>
          <li><strong>Include the goal</strong> — <code>roommates-brand-awareness</code>, <code>roommates-signups</code>, <code>roommates-retargeting</code></li>
          <li><strong>Include the audience</strong> — <code>roommates-landlords-us</code>, <code>roommates-renters-nyc</code></li>
          <li><strong>Keep names consistent across platforms</strong> — if you run the same campaign on Google and Meta, use the same name so Spectabas can compare them side-by-side</li>
        </ul>

        <div style="background: #f0fdf4; border-left: 4px solid #22c55e; padding: 12px 16px; margin: 16px 0; font-size: 13px;">
          <strong>Example naming convention:</strong><br>
          <code>[platform]-[goal]-[audience]-[variant]</code><br>
          <code>google-signups-landlords-us-v1</code><br>
          <code>meta-retargeting-renters-nyc-carousel</code>
        </div>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- WHAT THIS UNLOCKS -->
        <h2 style="font-size: 18px; margin-bottom: 8px;">🎯 What This Unlocks in Spectabas</h2>

        <p style="font-size: 14px;">Once UTM parameters are flowing alongside click IDs:</p>

        <table style="width: 100%; border-collapse: collapse; font-size: 14px; margin: 12px 0;">
          <thead>
            <tr style="border-bottom: 2px solid #e5e7eb; text-align: left;">
              <th style="padding: 8px;">Page</th>
              <th style="padding: 8px;">What You Get</th>
            </tr>
          </thead>
          <tbody>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Revenue Attribution</td>
              <td style="padding: 8px;">Campaign-level ROAS with verified ad clicks (click ID + utm_campaign)</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Visitor Quality</td>
              <td style="padding: 8px;">Per-campaign quality scores — see which campaigns bring engaged visitors</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Time to Convert</td>
              <td style="padding: 8px;">Per-campaign conversion speed — which campaigns bring ready-to-buy visitors</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Ad Visitor Paths</td>
              <td style="padding: 8px;">Page sequences by campaign — which landing pages work for which campaigns</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Ad-to-Churn</td>
              <td style="padding: 8px;">Per-campaign churn rates — which campaigns bring customers who stick</td>
            </tr>
            <tr style="border-bottom: 1px solid #f3f4f6;">
              <td style="padding: 8px; font-weight: 600;">Organic Lift</td>
              <td style="padding: 8px;">Halo effect measurement — do ads drive more organic discovery</td>
            </tr>
          </tbody>
        </table>

        <hr style="border: 0; border-top: 2px solid #e5e7eb; margin: 24px 0;">

        <!-- VERIFICATION CHECKLIST -->
        <h2 style="font-size: 18px; margin-bottom: 8px;">✅ Verification Checklist</h2>

        <p style="font-size: 14px;">After configuring each platform, verify within 24 hours:</p>

        <table style="width: 100%; border-collapse: collapse; font-size: 14px; margin: 12px 0;">
          <tbody>
            <tr style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 8px; width: 24px;">☐</td>
              <td style="padding: 8px;"><strong>/admin/ingest</strong> — Click ID Attribution shows events for each connected platform</td>
            </tr>
            <tr style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 8px;">☐</td>
              <td style="padding: 8px;"><strong>Visitor profile</strong> — click a realtime visitor who arrived from an ad, verify you see the platform pill + UTM tags</td>
            </tr>
            <tr style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 8px;">☐</td>
              <td style="padding: 8px;"><strong>Revenue Attribution → Campaign tab</strong> — verify your campaign names appear (not "(none)")</td>
            </tr>
            <tr style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 8px;">☐</td>
              <td style="padding: 8px;"><strong>Revenue Attribution → Source tab</strong> — verify "google", "bing", "facebook" appear as sources (from utm_source)</td>
            </tr>
            <tr style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 8px;">☐</td>
              <td style="padding: 8px;"><strong>Visitor Quality</strong> → "By Campaign" toggle shows campaign names with scores</td>
            </tr>
          </tbody>
        </table>

        <p style="font-size: 14px; margin-top: 24px; color: #6b7280;">
          Questions? Reply to this email or check the docs at <strong>spectabas.com/docs/conversions</strong>.
        </p>
      </div>
    </div>
    """
  end

  defp ad_setup_text do
    """
    SPECTABAS AD PLATFORM SETUP GUIDE
    ===================================

    GOOGLE ADS
    ----------
    1. Verify Auto-Tagging is ON: Google Ads → Settings → Account Settings → Auto-tagging → Check "Tag the URL"
    2. Set Account-Level Tracking Template: Settings → Tracking → Tracking template:
       {lpurl}?utm_source=google&utm_medium=cpc&utm_campaign={campaignname}&utm_term={keyword}&utm_content={creative}
    3. Click "Test" to verify

    MICROSOFT / BING ADS
    --------------------
    1. Verify msclkid auto-tagging: Settings → Account-level options → Microsoft click ID → Enabled
    2. Set Tracking Template:
       {lpurl}?utm_source=bing&utm_medium=cpc&utm_campaign={CampaignName}&utm_term={keyword}&utm_content={AdId}
    Note: Bing uses {CampaignName} (PascalCase), not {campaignname}

    META / FACEBOOK ADS
    -------------------
    1. fbclid is automatic
    2. For EACH ad, go to Tracking → URL Parameters and paste:
       utm_source=facebook&utm_medium=paid_social&utm_campaign={{campaign.name}}&utm_content={{ad.name}}
    Note: Must be set at the AD level. Double curly braces for Meta dynamic params.

    CAMPAIGN NAMING
    ---------------
    - Use lowercase with hyphens: spring-promo-2026
    - Include goal: roommates-signups, roommates-retargeting
    - Keep names consistent across platforms for side-by-side comparison

    VERIFICATION (after 24 hours)
    - /admin/ingest → Click ID Attribution shows events
    - Visitor profiles show platform pill + UTM tags
    - Revenue Attribution → Campaign tab shows campaign names
    - Visitor Quality → By Campaign toggle shows scores
    """
  end
end
