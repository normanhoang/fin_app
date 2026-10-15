# FinanceKit Entitlement Request

How to request Apple's FinanceKit managed entitlement for FinApp, so the app can read
Apple Card / Apple Cash / Apple Savings data on-device. Design:
`docs/superpowers/specs/2026-10-15-financekit-design.md`.

_Verified against Apple's docs on 2026-10-15._

## Before you submit — check eligibility

Apple's criteria ([developer.apple.com/financekit](https://developer.apple.com/financekit/)):

- [x] Listed in the **Finance** category in App Store Connect
      (`LSApplicationCategoryType = public.app-category.finance` in `project.yml`).
- [x] Distributed through the App Store for iPhone in the **United States**.
- [x] Provides financial-management tools (net worth, spending trends, budgeting).
- [ ] Request submitted by the **Account Holder** of the developer team (`DZRPJF9JB6`).
- [ ] **Organization-level account — possible blocker.** The FinanceKit framework docs
      ([developer.apple.com/documentation/financekit](https://developer.apple.com/documentation/financekit))
      say you must "hold an organization-level Apple Developer account". The marketing page
      above does not repeat this. If the team is enrolled as an **Individual**, the request
      may be rejected. Check at developer.apple.com → Account → Membership details
      ("Entity type"). If Individual, either submit anyway and see, or convert the
      membership to an organization (requires a D-U-N-S number and a legal entity).

The entitlement is granted **per bundle ID**: `com.normanhoang.finapp`.

## Submit the request

1. Sign in as the Account Holder at
   [developer.apple.com/contact/request/financekit](https://developer.apple.com/contact/request/financekit/).
2. Select the app / bundle ID `com.normanhoang.finapp`.
3. Fill in the form. Suggested answers below — adjust to the form's actual fields.

### App description

> FinApp is a privacy-first personal-finance app for iPhone, listed in the Finance
> category on the US App Store. It gives people a single view of their net worth,
> spending by category, monthly trends, budgets, and recurring bills. All financial data
> is stored only on the device in an encrypted local database (NSFileProtectionComplete).
> The app has no developer-operated server, no analytics, no advertising, and no
> third-party SDKs.

### How the app will use FinanceKit data

> FinApp will read Apple Card, Apple Cash, and Apple Savings accounts, balances, and
> transactions that the user chooses to share through the FinanceKit authorization
> sheet. The data is used only to show those accounts alongside the user's other
> accounts — in their net-worth total, spending categories, budgets, and
> recurring-bill detection. Data is read on-device, stored only on-device, and is never
> transmitted off the device or shared with anyone, including the developer.
>
> Today users can only include Apple Card through a third-party aggregator that
> requires frequent re-authentication with two-factor codes. FinanceKit lets them
> include their Apple accounts reliably and with clear, user-controlled consent.

### Data retention / user control

> Users choose which accounts and what date range to share in the system authorization
> sheet and can revoke access at any time in iOS Settings. When access is revoked,
> FinApp stops importing. Users can delete any imported account and its transactions
> from within the app, and deleting the app removes all data.

## After approval

Apple adds FinanceKit as a managed capability on the team. Then:

1. In `project.yml`, turn on the `FINANCEKIT` build flag. This adds the
   `com.apple.developer.financekit` entitlement and compiles the FinanceKit client.
2. Confirm `INFOPLIST_KEY_NSFinancialDataUsageDescription` is set in `project.yml`
   (required, or the authorization request fails).
3. `xcodegen generate`, then build to a physical iPhone with
   `-allowProvisioningUpdates` so automatic signing picks up the new capability.
   FinanceKit does not work in the Simulator.
4. Run the device checklist in the design spec.
5. Update `AppStore/privacy-policy.md` (and `docs/privacy.md`) to mention Apple Wallet
   data alongside SimpleFin — still on-device only, not collected. The App Store
   privacy label stays "Data Not Collected", since nothing leaves the device.

## If rejected

FinApp keeps working unchanged; the feature stays behind the off-by-default flag. Apple
Card can continue to sync through SimpleFin Bridge.
