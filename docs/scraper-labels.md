# Scraper Labels

Append-only log of human and machine judgments about whether a visitor is a
scraper. Captures the visitor's signal vector at the moment of the decision so
we can later train a logistic-regression model that replaces the hand-picked
weights in `Spectabas.ScraperDetector`.

**Labels do not change current detection behavior.** This is a logging table.
The model is a downstream payoff once labels exist.

## Why

The current scraper-detection scorer is a hand-tuned weighted sum of 15
signals (datacenter ASN, spoofed UA, low-page sessions, etc.). The weights
came from intuition and observation. Once we have enough labeled examples,
we can fit logistic regression on the same signals to learn optimal weights
and calibrated tier thresholds. Same model shape, less guesswork.

The lift is the labels — not the model. This table exists so the labels
accumulate naturally as the team uses the manual-flag and whitelist UI.

## Schema (`scraper_labels`)

| column          | type       | notes                                                                  |
|-----------------|------------|------------------------------------------------------------------------|
| `id`            | bigint PK  |                                                                        |
| `site_id`       | bigint     | FK → sites, ON DELETE CASCADE                                          |
| `visitor_id`    | uuid       | NO foreign key — survives visitor cleanup                              |
| `label`         | string(20) | `"scraper"` or `"not_scraper"`                                         |
| `source`        | string(40) | how the label was generated (see below)                                |
| `source_weight` | numeric    | confidence weight at training time (0.0–1.0)                           |
| `score`         | int        | scraper score at the moment of the click (0–100)                       |
| `tier`          | string(20) | `watching` / `suspicious` / `certain` at the moment of the click       |
| `signals`       | jsonb      | `{"datacenter_asn": true, "spoofed_ua": true, ...}` — the signal vector |
| `email`         | string     | visitor's email if identified, for cross-device joining                |
| `user_id`       | bigint     | FK → users, ON DELETE NILIFY — which dashboard user clicked            |
| `notes`         | text       | optional context                                                       |
| `labeled_at`    | timestamp  | when the click happened                                                |
| `inserted_at`   | timestamp  | when the row was written                                               |

`signals` is stored as a map (`{signal_name => true}`) rather than an array
so that future training queries can filter by signal directly:

```sql
SELECT label, count(*) FROM scraper_labels
WHERE signals ? 'datacenter_asn'
GROUP BY label;
```

## Sources and weights

| source                | label          | weight | meaning                                                             |
|-----------------------|----------------|--------|---------------------------------------------------------------------|
| `manual_flag`         | `scraper`      | 1.0    | "Mark as Scraper" or manual `send_webhook` from a dashboard user    |
| `manual_whitelist`    | `not_scraper`  | 1.0    | "Whitelist" click — strongest negative                              |
| `manual_unflag`       | `not_scraper`  | 0.5    | "Unflag" click; weaker because user may unflag without conviction   |
| `manual_unwhitelist`  | (reserved)     | 0.4    | reserved — currently not written                                    |
| `webhook_auto_flag`   | `scraper`      | 0.3    | auto-fired by `ScraperWebhookScan` worker — circular signal         |
| `webhook_downgrade`   | `not_scraper`  | 0.3    | auto-deactivated by the worker when score dropped                   |
| `goal_conversion`     | `not_scraper`  | 0.7    | reserved — write when a flagged visitor completes a goal            |
| `ecommerce_purchase`  | `not_scraper`  | 0.9    | reserved — write when a flagged visitor makes a purchase            |

The weight is **not** a probability; it's a confidence multiplier applied
at training time so human clicks dominate auto-fired events. Weights live
in `Spectabas.ScraperLabels.@source_weights` — adjust there.

### Why webhook sources are downweighted

Auto-fired flags are produced by the very rules we want to learn from.
If we trained on them at full weight, the model would learn to reproduce
the current weights exactly. They're kept for context (we still want
density of examples) but at low weight so human disagreements (whitelist
clicks on auto-fired flags) dominate.

## Where rows are written

The `Spectabas.ScraperLabels.record/1` call is best-effort — failure is
logged and swallowed so the user-facing action (mark / whitelist / unflag)
never fails because of label logging.

| call site                                                                 | source                |
|---------------------------------------------------------------------------|-----------------------|
| `VisitorLive.handle_event("mark_scraper", ...)`                           | `manual_flag`         |
| `VisitorLive.handle_event("whitelist_scraper", ...)`                      | `manual_whitelist`    |
| `VisitorLive.handle_event("unflag_scraper", ...)`                         | `manual_unflag`       |
| `ScrapersLive.handle_event("send_webhook", ...)`                          | `manual_flag`         |
| `ScrapersLive.handle_event("deactivate_webhook", ...)`                    | `manual_unflag`       |
| `Workers.ScraperWebhookScan.send_and_record/5`                            | `webhook_auto_flag`   |
| `Workers.ScraperWebhookScan.send_deactivation/2`                          | `webhook_downgrade`   |

## Training plan (future, not yet implemented)

1. **Wait** at least 4–8 weeks after deploy for labels to accumulate. Skipping
   this is the most likely failure mode — fitting a model on 30 rows will be
   worse than the hand-picked weights.

2. **Backtest before activating.** Train on the first N weeks, score the last
   week's labels, compare AUC against the current hand-picked weights. If
   the learned weights aren't strictly better on held-out data, do not ship.

3. **Shadow mode** for a week: compute both scores, log diffs, but only act
   on the rule-based score. Verify distributions look sane before flipping.

4. **Per-site or global?** Start global with `site_id` as a categorical
   feature. Per-site fine-tuning is a follow-up once a site has ≥ 200 labels.

5. **Calibration.** Raw logistic regression gives a probability that's
   monotonic in the linear sum but not necessarily well-calibrated against
   the 40/70/85 tier thresholds. Apply Platt scaling or isotonic regression
   on a held-out set to make the probability reflect true scraper rate.

6. **Storage** of learned weights goes in a future `scraper_model_weights`
   table (versioned). `ScraperDetector` reads weights from `:persistent_term`,
   default falling back to the hand-picked values if no learned model is
   active. **Off switch is the table** — flip the active version back to the
   hand-picked baseline.

## Auditing usage now

`ScraperLabels.list_for_site(site_id)` and
`ScraperLabels.counts_by_source(site_id)` are available right now without
any model in place. They're useful on their own — e.g. spot Whitelist
clicks on score-85 visitors (high-confidence false positives).

## Maintenance

- **Backfill from existing flags is not done.** The signal vector at the
  time of an existing manual flag can't be reconstructed accurately, so we
  start fresh from the deploy date.
- **Pruning**: no retention policy currently. Each label is small (~500 B).
  Revisit if rows exceed a few million.
- **Label quality check**: the rate of `manual_whitelist` rows on visitors
  who currently have `scraper_webhook_score >= 85` is a useful drift signal.
  If it spikes, the rule weights are getting worse.
