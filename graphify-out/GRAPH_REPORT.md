# Graph Report - /Users/normanhoang/repos/fin_app  (2026-07-03)

## Corpus Check
- 80 files · ~175,773 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 813 nodes · 1695 edges · 30 communities (28 shown, 2 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 75 edges (avg confidence: 0.81)
- Token cost: 109,361 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_SimpleFin DTO Decoding|SimpleFin DTO Decoding]]
- [[_COMMUNITY_Categorization & Budgets|Categorization & Budgets]]
- [[_COMMUNITY_Recurring Bill Model|Recurring Bill Model]]
- [[_COMMUNITY_Credential Store & SimpleFin Client|Credential Store & SimpleFin Client]]
- [[_COMMUNITY_App Router & Tabs|App Router & Tabs]]
- [[_COMMUNITY_Analytics & Spending Metrics|Analytics & Spending Metrics]]
- [[_COMMUNITY_Certificate Pinning|Certificate Pinning]]
- [[_COMMUNITY_UI Tests|UI Tests]]
- [[_COMMUNITY_App Store & Privacy Docs|App Store & Privacy Docs]]
- [[_COMMUNITY_App Entry & App Lock|App Entry & App Lock]]
- [[_COMMUNITY_Accounts View|Accounts View]]
- [[_COMMUNITY_Dashboard View|Dashboard View]]
- [[_COMMUNITY_Net Worth Detail Chart|Net Worth Detail Chart]]
- [[_COMMUNITY_Design Components|Design Components]]
- [[_COMMUNITY_Recurring Schedule|Recurring Schedule]]
- [[_COMMUNITY_Test Suite Index|Test Suite Index]]
- [[_COMMUNITY_Recurring View|Recurring View]]
- [[_COMMUNITY_Root View & Tab Bar|Root View & Tab Bar]]
- [[_COMMUNITY_SwiftData Models|SwiftData Models]]
- [[_COMMUNITY_Category Seeding & Sample Data|Category Seeding & Sample Data]]
- [[_COMMUNITY_Auxiliary Views|Auxiliary Views]]
- [[_COMMUNITY_Sync Throttle|Sync Throttle]]
- [[_COMMUNITY_Net Worth Snapshot Service|Net Worth Snapshot Service]]
- [[_COMMUNITY_Add Account & Category Picker|Add Account & Category Picker]]
- [[_COMMUNITY_Transactions View|Transactions View]]
- [[_COMMUNITY_Schema Container Setup|Schema Container Setup]]
- [[_COMMUNITY_Transaction Filter Sheet|Transaction Filter Sheet]]
- [[_COMMUNITY_Seed & Schema Tests|Seed & Schema Tests]]
- [[_COMMUNITY_App Screenshots|App Screenshots]]
- [[_COMMUNITY_Brand Icons|Brand Icons]]

## God Nodes (most connected - your core abstractions)
1. `Transaction` - 44 edges
2. `FinAppUITests` - 37 edges
3. `SwiftData` - 33 edges
4. `Category` - 32 edges
5. `Foundation` - 27 edges
6. `TransactionFilterState` - 24 edges
7. `DashboardView` - 24 edges
8. `Account` - 23 edges
9. `RecurringBill` - 23 edges
10. `AnalyticsTests` - 22 edges

## Surprising Connections (you probably didn't know these)
- `FinApp Application Target` --conceptually_related_to--> `NSFileProtectionComplete Encryption at Rest`  [INFERRED]
  project.yml → AppStore/privacy-policy.md
- `FinApp Application Target` --conceptually_related_to--> `FinApp iOS App Architecture`  [INFERRED]
  project.yml → CLAUDE.md
- `RecurringDetectorTests` --references--> `Transaction`  [EXTRACTED]
  Tests/FinAppTests/RecurringDetectorTests.swift → Sources/FinApp/Models/Transaction.swift
- `CredentialStoreTests` --calls--> `CredentialStore`  [INFERRED]
  Tests/FinAppTests/CredentialStoreTests.swift → Sources/FinApp/SimpleFin/CredentialStore.swift
- `AppLock Biometric Gate` --implements--> `FinApp Privacy Policy`  [INFERRED]
  CLAUDE.md → AppStore/privacy-policy.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **SimpleFin Sync Pipeline** — claude_synccoordinator, claude_simplefinclient, claude_syncservice, claude_categorizationengine, claude_recurringdetector, claude_networthsnapshot [EXTRACTED 0.90]
- **On-Device Privacy Guarantees** — appstore_privacy_policy_local_only_storage, appstore_privacy_policy_no_data_collection, appstore_privacy_policy_nsfileprotectioncomplete, appstore_privacy_policy_ios_keychain_credential [EXTRACTED 0.85]
- **xcodegen-Generated Build Targets** — claude_xcodegen_generation, project_finapp_target, project_finapptests_target, project_finappuitests_target [EXTRACTED 0.85]
- **App Bottom Tab Navigation** — appstore_screenshots_00_accounts_accounts_screen, appstore_screenshots_01_transactions_transactions_screen, appstore_screenshots_02_dashboard_dashboard_screen, appstore_screenshots_03_recurring_recurring_screen [EXTRACTED 1.00]

## Communities (30 total, 2 thin omitted)

### Community 0 - "SimpleFin DTO Decoding"
Cohesion: 0.07
Nodes (39): CodingKey, Decodable, Decoder, KeyedDecodingContainer, AccountDTO, CodingKeys, amount, availableBalance (+31 more)

### Community 1 - "Categorization & Budgets"
Cohesion: 0.07
Nodes (31): IndexSet, CategorizationEngine, ModelContext, String, AddBudgetView, BudgetRow, BudgetsView, Bool (+23 more)

### Community 2 - "Recurring Bill Model"
Cohesion: 0.06
Nodes (35): Codable, Cadence, biweekly, monthly, quarterly, weekly, yearly, RecurringBill (+27 more)

### Community 3 - "Credential Store & SimpleFin Client"
Cohesion: 0.07
Nodes (27): Error, LocalizedError, OSStatus, CredentialStore, KeychainError, Bool, String, URL (+19 more)

### Community 4 - "App Router & Tabs"
Cohesion: 0.07
Nodes (37): Equatable, Int, Observation, AppRouter, AppTab, accounts, dashboard, recurring (+29 more)

### Community 5 - "Analytics & Spending Metrics"
Cohesion: 0.11
Nodes (22): Identifiable, Analytics, CategoryTotal, MonthPoint, Calendar, Date, Decimal, Double (+14 more)

### Community 6 - "Certificate Pinning"
Cohesion: 0.07
Nodes (26): Any, CFString, CryptoKit, NSObject, SecCertificate, SecTrust, CertificatePinner, Bool (+18 more)

### Community 7 - "UI Tests"
Cohesion: 0.13
Nodes (5): FinAppUITests, Int, String, XCUIApplication, XCUIElement

### Community 8 - "App Store & Privacy Docs"
Cohesion: 0.06
Nodes (38): Clear All Local Data, FinApp Privacy Policy, SimpleFin Credential in iOS Keychain, Local-Only Data Storage, No Data Collection or Tracking, NSFileProtectionComplete Encryption at Rest, SimpleFin Bridge, Automatic Categories (+30 more)

### Community 9 - "App Entry & App Lock"
Cohesion: 0.07
Nodes (25): App, CaseIterable, ColorScheme, LocalAuthentication, Scene, FinAppApp, ModelContainer, AppLock (+17 more)

### Community 10 - "Accounts View"
Cohesion: 0.10
Nodes (24): AccountDetailView, AccountsView, balanceColor(), Bool, Color, Date, Decimal, Set (+16 more)

### Community 11 - "Dashboard View"
Cohesion: 0.12
Nodes (17): CGPoint, CGRect, ChartProxy, GeometryProxy, Hashable, DashboardView, NetWorthRoute, Bool (+9 more)

### Community 12 - "Net Worth Detail Chart"
Cohesion: 0.09
Nodes (20): Charts, ClosedRange, Sendable, NetWorthDetailView, NWRange, all, oneMonth, oneYear (+12 more)

### Community 13 - "Design Components"
Cohesion: 0.14
Nodes (20): Content, EnvironmentKey, Font, BottomBarInsetKey, BrandMark, CardStyle, Chip, EnvironmentValues (+12 more)

### Community 14 - "Recurring Schedule"
Cohesion: 0.24
Nodes (8): RecurringSchedule, Calendar, Date, DateInterval, RecurringScheduleTests, Date, DateInterval, Int

### Community 16 - "Recurring View"
Cohesion: 0.23
Nodes (11): CalendarMonthCard, RecurringDetailView, RecurringRow, RecurringView, Date, DateInterval, Int, Set (+3 more)

### Community 17 - "Root View & Tab Bar"
Cohesion: 0.21
Nodes (9): Binding, PreferenceKey, BarHeightKey, CustomTabBar, RootView, CGFloat, Int, String (+1 more)

### Community 18 - "SwiftData Models"
Cohesion: 0.26
Nodes (3): Foundation, Security, SwiftData

### Community 19 - "Category Seeding & Sample Data"
Cohesion: 0.26
Nodes (7): CategorySeed, Seed, Bool, ModelContext, String, SampleData, ModelContext

### Community 20 - "Auxiliary Views"
Cohesion: 0.15
Nodes (7): LockScreen, SettingsView, SplashView, CategoryPickerHost, Color, TransactionRow, SwiftUI

### Community 21 - "Sync Throttle"
Cohesion: 0.23
Nodes (6): Bool, Date, TimeInterval, SyncThrottle, TimeInterval, SyncThrottleTests

### Community 22 - "Net Worth Snapshot Service"
Cohesion: 0.22
Nodes (8): NetWorthSnapshotService, Calendar, Date, Decimal, ModelContext, NetWorthSnapshot, Date, Decimal

### Community 23 - "Add Account & Category Picker"
Cohesion: 0.24
Nodes (7): AddAccountView, Decimal, CategoryPickerPopup, Bool, Color, String, Void

### Community 24 - "Transactions View"
Cohesion: 0.22
Nodes (5): Bool, Date, String, TransactionDetailView, TransactionsView

### Community 25 - "Schema Container Setup"
Cohesion: 0.22
Nodes (3): PersistentModel, AppSchema, ModelContainer

### Community 26 - "Transaction Filter Sheet"
Cohesion: 0.29
Nodes (6): Bool, Color, Date, Int, String, TransactionFilterSheet

### Community 27 - "Seed & Schema Tests"
Cohesion: 0.22
Nodes (5): CategorySeedTests, ModelContainer, ModelContext, SchemaTests, XCTestCase

### Community 28 - "App Screenshots"
Cohesion: 0.83
Nodes (4): Accounts Screen, Transactions Screen, Dashboard Screen, Recurring Screen

## Knowledge Gaps
- **65 isolated node(s):** `accounts`, `transactions`, `dashboard`, `settings`, `all` (+60 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Foundation` connect `SwiftData Models` to `SimpleFin DTO Decoding`, `Categorization & Budgets`, `Recurring Bill Model`, `Credential Store & SimpleFin Client`, `App Router & Tabs`, `Analytics & Spending Metrics`, `Certificate Pinning`, `App Entry & App Lock`, `Accounts View`, `Net Worth Detail Chart`, `Recurring Schedule`, `Sync Throttle`?**
  _High betweenness centrality (0.152) - this node is a cross-community bridge._
- **Why does `Transaction` connect `Analytics & Spending Metrics` to `SimpleFin DTO Decoding`, `Categorization & Budgets`, `Recurring Bill Model`, `App Router & Tabs`, `Accounts View`, `Dashboard View`, `Recurring View`, `SwiftData Models`, `Category Seeding & Sample Data`, `Auxiliary Views`, `Transactions View`?**
  _High betweenness centrality (0.144) - this node is a cross-community bridge._
- **Why does `SwiftUI` connect `Auxiliary Views` to `Categorization & Budgets`, `Certificate Pinning`, `App Entry & App Lock`, `Accounts View`, `Dashboard View`, `Net Worth Detail Chart`, `Design Components`, `Recurring View`, `Root View & Tab Bar`, `Add Account & Category Picker`, `Transactions View`?**
  _High betweenness centrality (0.105) - this node is a cross-community bridge._
- **Are the 8 inferred relationships involving `Transaction` (e.g. with `.openPendingTransaction()` and `.inject()`) actually correct?**
  _`Transaction` has 8 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `Category` (e.g. with `.insert()` and `.testEnsureMissingAddsNewSeedWithoutDuplicating()`) actually correct?**
  _`Category` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `accounts`, `transactions`, `dashboard` to the rest of the system?**
  _66 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SimpleFin DTO Decoding` be split into smaller, more focused modules?**
  _Cohesion score 0.06696428571428571 - nodes in this community are weakly interconnected._