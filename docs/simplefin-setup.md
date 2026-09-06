---
title: SimpleFin Setup Guide
---

# How to Set Up SimpleFin Bridge

FinApp uses **SimpleFin Bridge** to fetch your bank data. SimpleFin Bridge is an
independent service (not operated by FinApp) that connects to your banks on your
behalf and exposes a **read-only** feed of your accounts and transactions. You
never enter your bank credentials in FinApp — banks are linked on SimpleFin's
site, and FinApp only reads the resulting data. Everything synced is stored
privately on your device.

## Cost

SimpleFin Bridge is a paid service:

- **$1.50 + tax per month**, or
- **$15.00 + tax per year**

One subscription covers up to **25 financial institutions** and **25 connected
apps**. See current pricing at
[bridge.simplefin.org](https://beta-bridge.simplefin.org/).

## Setup steps

1. **Create a SimpleFin Bridge account** at
   [beta-bridge.simplefin.org](https://beta-bridge.simplefin.org/) and choose a
   subscription.
2. **Connect your banks** on the SimpleFin site. Search for each institution and
   sign in through SimpleFin's secure flow.
3. **Generate a setup token** — on SimpleFin Bridge, create a new app connection
   and copy the setup token it gives you.
4. **Paste the token into FinApp** — open the **Settings** tab, paste the token
   into the *Paste SimpleFin setup token* field, and tap **Connect**.
5. FinApp claims the token, runs its first sync, and your accounts and
   transactions appear. After that, syncing happens automatically.

> **Note:** a setup token is **one-time use**. Once FinApp claims it, that token
> cannot be used again — if you ever need to reconnect, generate a fresh token
> on SimpleFin Bridge.

## Muting SimpleFin emails (Gmail)

SimpleFin Bridge emails you when it syncs or when a bank connection needs
attention. If those pile up, a Gmail filter can route them out of the inbox
without losing them.

This has to be done in a desktop browser at
[mail.google.com](https://mail.google.com) — the mobile app can't create filters.

1. Open one of the SimpleFin messages.
2. Click the **More** icon (three vertical dots) at the top right, next to
   **Reply**, and choose **Filter messages like this**.
3. The filter criteria screen is fine as-is — click **Create filter**.
4. Tick **Skip the Inbox (Archive it)** and **Apply the label**, then pick (or
   create) a *SimpleFin* label.
5. Click **Create filter** again.

From then on SimpleFin messages go straight to that label. The Gmail app only
notifies for mail that lands in the inbox, so these stop buzzing your phone —
and they're still there under the label whenever you want to check them.

## Troubleshooting

**My token doesn't work.**
Setup tokens are single-use. If the token was already claimed — even by a failed
connection attempt — it is spent. Generate a new setup token on SimpleFin Bridge
and try again.

**A bank is missing, or shows a connection error.**
Bank links live on SimpleFin's side, not in FinApp. Sign in at
[beta-bridge.simplefin.org](https://beta-bridge.simplefin.org/), fix or re-link
the institution there, then pull to refresh in FinApp.

**New transactions aren't appearing.**
Syncs are throttled to avoid hammering the service, and banks can take a day or
so to post transactions to SimpleFin. Pull to refresh, and check the last-sync
time on the Settings screen.

## FAQ

**Is it safe?**
The connection is read-only — nothing in FinApp can move money or change
anything at your bank. Your bank login is entered only on SimpleFin's site,
never in FinApp. The SimpleFin credential is stored in the iOS Keychain, and all
synced data stays on your device.

**Do I need SimpleFin to use FinApp?**
No. You can add **manual accounts** and track balances yourself without any
SimpleFin subscription.

**How do I disconnect?**
Open **Settings** and tap **Disconnect**. This deletes the SimpleFin credential
from your device. Already-synced accounts and transactions remain in the app; to
reconnect later, generate a new setup token.

**Which banks are supported?**
Thousands of institutions. Use the search on
[beta-bridge.simplefin.org](https://beta-bridge.simplefin.org/) to check yours
before subscribing.

---

Questions? Email [normanhoang@gmail.com](mailto:normanhoang@gmail.com).
