import XCTest

/// End-to-end UI tests driving the real app via accessibility identifiers, so
/// List `NavigationLink`s and `Menu`s fire deterministically (synthetic cursor
/// clicks don't). Launches with FINAPP_UITEST=1 → clean in-memory store seeded
/// with sample data.
final class FinAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(tab: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FINAPP_UITEST"] = "1"
        app.launchEnvironment["FINAPP_TAB"] = String(tab)
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func firstTxnRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'txnRow-'"))
            .firstMatch
    }

    /// Find a row in the filter sheet: expand the medium-detent sheet to full
    /// height via its grabber, then scroll the sheet's own List (the last
    /// collection view — the paging RootView contributes several others) until
    /// the row exists. Lazy rows scrolled off-screen are absent from the tree.
    private func filterSheetRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.buttons[id].firstMatch
        if row.waitForExistence(timeout: 5) { return row }
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.exists { grabber.swipeUp() }
        var swipes = 0
        while !row.waitForExistence(timeout: 1) && swipes < 5 {
            let lists = app.collectionViews
            lists.element(boundBy: lists.count - 1).swipeUp()
            swipes += 1
        }
        return row
    }

    // 1. Tapping the Net Worth card opens the graph screen (empty "Building
    //    History" state with sample data, since snapshots only record on sync).
    func testNetWorthCardOpensGraph() {
        let app = launch(tab: 2)
        let card = app.descendants(matching: .any).matching(identifier: "netWorthCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Net Worth card not found")
        card.tap()

        let onDetail = app.navigationBars["Net Worth"].waitForExistence(timeout: 5)
            || app.staticTexts["Building History"].waitForExistence(timeout: 5)
        XCTAssertTrue(onDetail, "Net Worth detail did not open")
        snap(app, "net-worth-detail")
    }

    // 1b. Switching tabs resets a pushed subpage: open Net Worth, leave, come back
    //     to the Dashboard root (not the Net Worth detail).
    func testTabSwitchResetsToRoot() {
        let app = launch(tab: 2)
        let card = app.descendants(matching: .any).matching(identifier: "netWorthCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout: 5),
                      "Net Worth detail did not open")

        app.buttons["tab-Accounts"].tap()
        app.buttons["tab-Dashboard"].tap()

        XCTAssertFalse(app.navigationBars["Net Worth"].waitForExistence(timeout: 2),
                       "Dashboard should return to its root, not the Net Worth subpage")
    }

    // 2. Transaction detail shows the top category Menu and the Recurring controls.
    func testTransactionDetailHasCategoryMenuAndRecurring() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No transaction rows")
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Category menu missing")
        XCTAssertTrue(app.buttons["Set as Recurring"].waitForExistence(timeout: 5), "Set as Recurring missing")
        snap(app, "transaction-detail")
    }

    // 3. The top category Menu opens and changing it sticks.
    func testCategoryMenuChangesCategory() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        let menu = app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()

        let diningItem = app.buttons["Dining"].firstMatch
        XCTAssertTrue(diningItem.waitForExistence(timeout: 5), "Menu did not open with category items")
        snap(app, "category-menu-open")
        diningItem.tap()

        XCTAssertTrue(app.staticTexts["Dining"].waitForExistence(timeout: 5), "Category did not change to Dining")
        snap(app, "category-changed")
    }

    // 3c. The filter sheet offers an "Uncategorized" option that filters the list.
    func testUncategorizedFilterOption() {
        let app = launch(tab: 1)
        let filter = app.buttons["filterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button missing")
        filter.tap()

        let uncategorized = filterSheetRow(app, "txnCatToggle-Uncategorized")
        XCTAssertTrue(uncategorized.exists, "Uncategorized option missing from filter sheet")
        uncategorized.tap()
        app.buttons["filterDone"].tap()

        XCTAssertTrue(app.staticTexts["Filtered: Uncategorized"].waitForExistence(timeout: 5),
                      "Uncategorized filter not applied")
        snap(app, "filter-uncategorized")
    }

    // 3b. The Filter button opens the filter sheet and filters the list.
    func testFilterButtonFiltersTransactions() {
        let app = launch(tab: 1)
        let filter = app.buttons["filterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button missing")
        filter.tap()

        let housing = filterSheetRow(app, "txnCatToggle-Housing")
        XCTAssertTrue(housing.exists, "Filter sheet did not open")
        housing.tap()
        app.buttons["filterDone"].tap()

        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5),
                      "Filter not applied from the sheet")
        snap(app, "filter-from-button")
    }

    // 3e. Month stepper only visits months that have entries: forward is dead
    // at "All time", back walks to the oldest month with data then disables.
    func testMonthStepperBoundedByData() {
        let app = launch(tab: 1)
        let filter = app.buttons["filterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button missing")
        filter.tap()

        let back = app.buttons["filterMonthBack"]
        let forward = app.buttons["filterMonthForward"]
        let label = app.staticTexts["filterMonthLabel"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Month row missing")
        XCTAssertEqual(label.label, "All time")
        XCTAssertFalse(forward.isEnabled, "Forward should be disabled at All time")

        back.tap()
        XCTAssertNotEqual(label.label, "All time", "Back from All time should enter the newest month")

        var steps = 0
        while back.isEnabled && steps < 24 { back.tap(); steps += 1 }
        XCTAssertFalse(back.isEnabled, "Back should disable at the oldest month with entries")
        XCTAssertTrue(forward.isEnabled, "Forward should re-enable once off the newest month")
    }

    // 3d. Multiple categories can be selected; the chip summarizes the count,
    // and Clear All removes the filter without dismissing the sheet.
    func testMultiSelectAndClearAllFilters() {
        let app = launch(tab: 1)
        let filter = app.buttons["filterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button missing")
        filter.tap()

        let housing = filterSheetRow(app, "txnCatToggle-Housing")
        XCTAssertTrue(housing.exists, "Filter sheet did not open")
        housing.tap()
        filterSheetRow(app, "txnCatToggle-Dining").tap()
        app.buttons["filterDone"].tap()

        XCTAssertTrue(app.staticTexts["Filtered: 2 categories"].waitForExistence(timeout: 5),
                      "Multi-select chip not shown")

        filter.tap()
        let clearAll = app.buttons["filterClearAll"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 5))
        clearAll.tap()
        app.buttons["filterDone"].tap()

        XCTAssertFalse(app.staticTexts["Filtered: 2 categories"].waitForExistence(timeout: 2),
                       "Clear All did not remove the filter")
    }

    // 4. "Set as Recurring" creates a bill that shows on the Recurring tab.
    func testSetAsRecurringCreatesBill() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        let setBtn = app.buttons["Set as Recurring"]
        XCTAssertTrue(setBtn.waitForExistence(timeout: 5))
        setBtn.tap()

        app.buttons["tab-Recurring"].tap()
        // The tab defaults to the calendar; switch to the list, where a
        // confirmed bill lands under the "Upcoming" section; the empty state
        // ("No Recurring Bills") must be gone.
        let toggle = app.buttons["recurringModeToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Mode toggle not shown")
        toggle.tap()
        let upcoming = app.staticTexts["Upcoming"].waitForExistence(timeout: 5)
        snap(app, "recurring-after-set")
        XCTAssertTrue(upcoming, "Upcoming section not shown after Set as Recurring")
        XCTAssertFalse(app.staticTexts["No Recurring Bills"].exists, "Recurring tab still empty")
        toggle.tap() // restore the default calendar mode (it persists via AppStorage)
    }

    // A confirmed bill shows up under its due day on the Recurring calendar.
    func testRecurringCalendarShowsBillOnDueDay() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let setBtn = app.buttons["Set as Recurring"]
        XCTAssertTrue(setBtn.waitForExistence(timeout: 5))
        setBtn.tap()

        app.buttons["tab-Recurring"].tap()
        // Force calendar mode (a previous test may have persisted list mode).
        if !app.buttons["calNextMonth"].waitForExistence(timeout: 3) {
            app.buttons["recurringModeToggle"].tap()
        }

        // setRecurring projects nextDue = today + 30 days (monthly default).
        let cal = Calendar.current
        let due = cal.date(byAdding: .day, value: 30, to: .now)!
        if !cal.isDate(due, equalTo: .now, toGranularity: .month) {
            app.buttons["calNextMonth"].tap()
        }
        let dayBtn = app.buttons["calDay-\(cal.component(.day, from: due))"]
        XCTAssertTrue(dayBtn.waitForExistence(timeout: 5), "Due day cell not found")
        dayBtn.tap()

        XCTAssertTrue(app.staticTexts[due.formatted(.dateTime.weekday(.wide).month().day())]
            .waitForExistence(timeout: 5), "Selected-day header not shown")
        XCTAssertFalse(app.staticTexts["Nothing due this day."].exists,
                       "Confirmed bill not listed on its due day")
        snap(app, "recurring-calendar-due-day")
    }

    // 5. Tapping a Dashboard category drills into a filtered Transactions list.
    func testDashboardCategoryFiltersTransactions() {
        let app = launch(tab: 2)
        let housing = app.buttons["category-Housing"]
        XCTAssertTrue(housing.waitForExistence(timeout: 8), "Housing category row not found")
        housing.tap()

        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5),
                      "Filter chip not shown on Transactions")
        snap(app, "filtered-housing")
    }

    // 5b. Swiping back to Transactions clears a leftover filter (tab tap too).
    func testSwipingToTransactionsClearsFilter() {
        let app = launch(tab: 2)
        app.buttons["category-Housing"].tap()
        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5))

        app.swipeRight()   // to Accounts
        XCTAssertTrue(app.staticTexts["Assets"].waitForExistence(timeout: 5))
        app.swipeLeft()    // back to Transactions

        XCTAssertFalse(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 2),
                       "Swiping to Transactions should clear the filter")
    }

    // 6. Renaming an account updates the list (and persists via customName).
    func testRenameAccountUpdatesList() {
        let app = launch(tab: 0)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'accountRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No account rows")
        row.tap()

        let field = app.textFields["accountNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Name field missing")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        let newName = "My Renamed Account"
        field.typeText(newName)
        snap(app, "account-rename")

        app.navigationBars.buttons.element(boundBy: 0).tap() // back to list
        XCTAssertTrue(app.staticTexts[newName].waitForExistence(timeout: 5),
                      "Renamed account not shown in list")
    }

    // 6b. Tapping the Transactions tab clears an active filter from the Dashboard.
    func testTransactionsTabClearsFilter() {
        let app = launch(tab: 2)
        let housing = app.buttons["category-Housing"]
        XCTAssertTrue(housing.waitForExistence(timeout: 8))
        housing.tap()
        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5))

        app.buttons["tab-Transactions"].tap()
        XCTAssertFalse(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 2),
                       "Filter chip should clear when tapping the Transactions tab")
        snap(app, "filter-cleared")
    }

    // 8. Re-filtering from the Dashboard pops any open transaction back to the
    //    filtered list (not stuck on the single detail).
    func testReFilterPopsOpenTransaction() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Detail did not open")

        app.buttons["tab-Dashboard"].tap()
        app.buttons["category-Housing"].tap()

        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch.exists,
                       "Should show the filtered list, not the previously opened transaction")
        snap(app, "refilter-pops-detail")
    }

    // 9. Tapping a transaction inside an account pushes the detail onto the
    //    Accounts stack, and going back returns to the account subpage.
    func testAccountTransactionPushesDetailAndBackReturns() {
        let app = launch(tab: 0)
        let account = app.descendants(matching: .any).matching(identifier: "accountRow-s-card").firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 8), "Account row not found")
        account.tap()

        // The row may sit below the fold (List rows are created lazily), so
        // scroll until it exists and is hittable.
        let txn = app.descendants(matching: .any).matching(identifier: "acctTxnRow-s-tx-1").firstMatch
        for _ in 0..<6 where !(txn.exists && txn.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(txn.waitForExistence(timeout: 5), "No account transactions")
        txn.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Transaction detail did not open")

        // The back-swipe (interactive pop) must return to the account subpage,
        // not to the Transactions tab. Assert on the nav bar — the name field
        // is a lazy List row that sits above the fold after the scroll above.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.navigationBars["Rewards Card"].waitForExistence(timeout: 5),
                      "Back-swipe did not return to the account subpage")
    }

    // 7. Swiping across the app must not crash (regression for the page-style
    //    TabView + NavigationStack UINavigationBar layout assertion).
    func testSwipingChangesPageAndDoesNotCrash() {
        let app = launch(tab: 0) // Accounts
        XCTAssertTrue(app.staticTexts["Assets"].waitForExistence(timeout: 8))

        // Swiping left pages from Accounts to Transactions (its search field).
        app.swipeLeft()
        XCTAssertTrue(app.textFields["txnSearchField"].waitForExistence(timeout: 5),
                      "Swipe did not page to the Transactions tab")

        for _ in 0..<6 {
            app.swipeLeft()
            app.swipeRight()
        }
        // App still alive and responsive if the tab bar is still queryable.
        XCTAssertTrue(app.buttons["tab-Dashboard"].exists, "App crashed during swiping")
    }

    // 10. Tapping a trend bar shows the value popup; scrolling the page dismisses it.
    func testTrendPopupOpensAndScrollDismisses() {
        let app = launch(tab: 2)
        let chart = app.descendants(matching: .any).matching(identifier: "trendChart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 8), "Trend chart not found")
        // The trend card is below the fold — scroll it into view before tapping.
        while !chart.isHittable { app.swipeUp() }
        // Tap a bar to open the popup.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let popup = app.descendants(matching: .any).matching(identifier: "trendPopup").firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Trend popup did not open")
        snap(app, "trend-popup-open")

        app.swipeUp()   // scrolling the page should close the popup
        XCTAssertFalse(popup.waitForExistence(timeout: 2), "Scrolling should dismiss the trend popup")
    }

    // 10b. Scrubbing the Net Worth chart left must NOT page to the next tab — the
    //      horizontal drag belongs to the chart while a scrub selection is active.
    func testNetWorthScrubDoesNotPage() {
        let app = launch(tab: 2)
        let card = app.descendants(matching: .any).matching(identifier: "netWorthCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Net Worth card not found")
        card.tap()
        XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout: 5),
                      "Net Worth detail did not open")

        let chart = app.descendants(matching: .any).matching(identifier: "netWorthChart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "Net Worth chart not found")
        // A leftward scrub across the chart — the exact motion that used to trigger
        // the left-swipe-to-next-tab pager.
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)

        XCTAssertTrue(app.navigationBars["Net Worth"].exists,
                      "Scrubbing the chart paged away instead of staying on the detail")
        snap(app, "net-worth-scrub")
    }

    // 12. Leaving and returning to a tab scrolls it back to the top.
    func testTabChangeScrollsToTop() {
        let app = launch(tab: 2)
        let card = app.descendants(matching: .any).matching(identifier: "netWorthCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))

        // Scroll the dashboard down so the net-worth card leaves the top.
        app.swipeUp(); app.swipeUp()
        XCTAssertFalse(card.isHittable, "Card should be scrolled off after swiping up")

        // Leave to another tab and come back.
        app.buttons["tab-Accounts"].tap()
        app.buttons["tab-Dashboard"].tap()

        XCTAssertTrue(card.isHittable, "Returning to the tab should scroll back to the top")
    }

    // 11. A manual account can be created, edited, and deleted.
    func testManualAccountCreateEditDelete() {
        let app = launch(tab: 0)
        XCTAssertTrue(app.buttons["addAccountButton"].waitForExistence(timeout: 8))
        app.buttons["addAccountButton"].tap()

        let name = "Test Manual"
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Add Account form missing")
        nameField.tap(); nameField.typeText(name)
        let balanceField = app.textFields["0.00"]
        balanceField.tap(); balanceField.typeText("1234.56")
        app.buttons["Save"].tap()

        // The new account shows in the list; open it.
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5), "Manual account not added")
        app.staticTexts[name].tap()

        // Detail exposes an editable balance and a delete button (manual only).
        XCTAssertTrue(app.textFields["accountBalanceField"].waitForExistence(timeout: 5),
                      "Manual balance not editable")
        let deleteBtn = app.buttons["deleteAccountButton"]
        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 5), "Delete button missing")
        deleteBtn.tap()

        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 3), "Account not deleted")
    }

    // 13. After switching tabs, the large navigation title keeps its proper leading
    //     inset (regression: it used to render flush-left until a manual scroll).
    func testLargeTitleInsetAfterTabSwitch() {
        let app = launch(tab: 2) // Dashboard (production default landing tab)
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 8))

        for title in ["Recurring", "Settings", "Accounts", "Transactions"] {
            app.buttons["tab-\(title)"].tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "\(title) nav bar missing")
            let titleText = bar.staticTexts[title]
            XCTAssertTrue(titleText.waitForExistence(timeout: 3), "\(title) large title missing")
            snap(app, "title-inset-\(title)")
            // A correct large title sits ~16pt from the screen edge; the bug
            // collapses the leading inset toward 0.
            XCTAssertGreaterThan(titleText.frame.minX, 12,
                                 "\(title) large title is flush-left (inset collapsed)")
        }
    }

    // 14. The Spending Categories filter hides a category from the Dashboard list.
    func testHideCategoryFromDashboard() {
        let app = launch(tab: 2)
        let groceries = app.buttons["category-Groceries"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 8), "Groceries row not found")

        let filter = app.buttons["categoryFilterButton"]
        while !filter.isHittable { app.swipeUp() }
        filter.tap()

        let toggle = app.buttons["catToggle-Groceries"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Category filter popup did not open")
        toggle.tap()
        // Tap away (outside the popover) to dismiss it.
        app.navigationBars["Dashboard"].tap()

        XCTAssertFalse(app.buttons["category-Groceries"].waitForExistence(timeout: 3),
                       "Hidden category should be removed from the Spending Categories list")
        snap(app, "category-hidden")
    }

    // 14b. Filter checkbox is half-filled for a hidden category that still has
    //      current-month spend, empty for a hidden category with none. (Fresh
    //      sample dates the recurring Netflix/Spotify charges to today →
    //      Subscriptions has this-month spend; Bars has none.) The first tap
    //      also disables Auto and seeds the flags from Auto's view, so Bars
    //      (no spend) lands hidden/"empty" without being touched.
    func testFilterCheckboxReflectsSpend() {
        let app = launch(tab: 2)
        let filter = app.buttons["categoryFilterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button not found")
        while !filter.isHittable { app.swipeUp() }
        filter.tap()

        let subs = app.buttons["catToggle-Subscriptions"]
        XCTAssertTrue(subs.waitForExistence(timeout: 5), "Filter popup did not open")
        XCTAssertEqual(subs.value as? String, "shown")
        subs.tap()
        XCTAssertEqual(subs.value as? String, "half",
                       "Hidden category with current-month spend should be half-filled")

        let bars = app.buttons["catToggle-Bars"]
        XCTAssertEqual(bars.value as? String, "empty",
                       "Seeding on leaving Auto should hide zero-spend categories")
        bars.tap()
        XCTAssertEqual(bars.value as? String, "shown")
        snap(app, "filter-checkbox-states")
    }

    // 14d. Auto (default ON) hides zero-spend categories; toggling it off
    //      reveals the dormant manual state (fresh store: everything visible).
    //      Auto lives inside the filter popup, above Uncategorized.
    func testAutoToggleShowsZeroSpendCategories() {
        let app = launch(tab: 2)
        XCTAssertTrue(app.buttons["category-Housing"].waitForExistence(timeout: 8),
                      "Housing (has spend) should show under Auto")
        XCTAssertFalse(app.buttons["category-Bars"].exists,
                       "Auto should hide categories with no spend this month")

        let filter = app.buttons["categoryFilterButton"]
        while !filter.isHittable { app.swipeUp() }
        filter.tap()

        let auto = app.buttons["catAutoToggle"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not open")
        XCTAssertEqual(auto.value as? String, "on")
        auto.tap()
        app.navigationBars["Dashboard"].tap() // dismiss the popover
        XCTAssertTrue(app.buttons["category-Bars"].waitForExistence(timeout: 3),
                      "Manual state (all visible) should take over when Auto is off")

        filter.tap()
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not reopen")
        auto.tap()
        app.navigationBars["Dashboard"].tap()
        XCTAssertFalse(app.buttons["category-Bars"].waitForExistence(timeout: 2),
                       "Re-enabling Auto should re-derive from spend")
    }

    // 14e. Tapping a popup toggle disables Auto and seeds the manual flags from
    //      Auto's view — the visible set only changes by the tapped row.
    func testPopupTapDisablesAutoAndSeeds() {
        let app = launch(tab: 2)
        let filter = app.buttons["categoryFilterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button not found")
        while !filter.isHittable { app.swipeUp() }
        filter.tap()

        let groceries = app.buttons["catToggle-Groceries"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 5), "Filter popup did not open")
        groceries.tap()
        app.navigationBars["Dashboard"].tap() // dismiss the popover

        XCTAssertFalse(app.buttons["category-Groceries"].exists,
                       "Tapped category should now be hidden")
        XCTAssertFalse(app.buttons["category-Bars"].exists,
                       "Seeding must keep zero-spend categories hidden")
        XCTAssertTrue(app.buttons["category-Housing"].exists,
                      "Untouched spent categories must stay visible")

        // Auto now lives in the popup — reopen it to check the toggle state.
        filter.tap()
        let auto = app.buttons["catAutoToggle"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not reopen")
        XCTAssertEqual(auto.value as? String, "off", "Popup tap should disable Auto")
    }

    // 14c. Hiding every category must not make the whole card (and its filter
    //      button) disappear — otherwise there's no way to re-show categories.
    func testCategoryCardSurvivesAllHidden() {
        let app = launch(tab: 2)
        let filter = app.buttons["categoryFilterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button not found")
        while !filter.isHittable { app.swipeUp() }
        filter.tap()

        let anyToggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'catToggle-'"))
        XCTAssertTrue(anyToggle.firstMatch.waitForExistence(timeout: 5), "Filter popup did not open")
        // Hide every category + Uncategorized. Re-query the first still-"shown"
        // toggle each pass (XCUITest auto-scrolls to it) until none remain — robust
        // to the popover scrolling, unlike a fixed index loop.
        var guardCount = 0
        while guardCount < 50 {
            let shown = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'catToggle-' AND value == %@", "shown"))
                .firstMatch
            if !shown.waitForExistence(timeout: 1) { break }
            shown.tap()
            guardCount += 1
        }
        app.navigationBars["Dashboard"].tap() // dismiss the popover

        XCTAssertTrue(app.buttons["categoryFilterButton"].waitForExistence(timeout: 3),
                      "Filter button vanished when all categories hidden")
        XCTAssertTrue(app.staticTexts["All categories hidden — tap the filter to show some."].exists,
                      "Card body missing when all categories hidden")
        snap(app, "categories-all-hidden")
    }

    // 8b. Collapse-all/expand-all toolbar button hides and restores account rows,
    //     and keeps working across repeated taps (regression: strict set equality
    //     made the first tap a visual no-op when collapsedTypes held stale types).
    func testCollapseAllToggleHidesAndRestoresRows() {
        let app = launch(tab: 0) // Accounts
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'accountRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No account rows")

        let toggle = app.buttons["accountCollapseAllToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Collapse-all button not found")

        for i in 1...3 {
            toggle.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 3),
                          "Rows still visible after collapse-all (round \(i))")
            toggle.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 3),
                          "Rows did not return after expand-all (round \(i))")
        }
        snap(app, "collapse-all-expanded")
    }

    // 8c. Rapid taps on the sort and collapse-all toolbar buttons must each
    //     register (repro: taps landing mid-animation/rebuild were dropped, so
    //     an even number of fast taps could leave the button in the toggled
    //     state). Parity check via each button's accessibilityLabel.
    func testRapidToolbarTapsAllRegister() {
        let app = launch(tab: 0) // Accounts
        XCTAssertTrue(app.buttons["accountSortToggle"].waitForExistence(timeout: 8),
                      "Sort toggle not found")

        // Sort: starts "Sorted alphabetically". 8 fast taps → back to start.
        let sort = app.buttons["accountSortToggle"]
        let sortCoord = sort.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<8 { sortCoord.tap() }
        XCTAssertTrue(app.buttons["accountSortToggle"]
            .label == "Sorted alphabetically",
            "Sort button lost a rapid tap (label: \(app.buttons["accountSortToggle"].label))")

        // Collapse-all: starts "Collapse all" (expanded). 8 fast taps → back.
        let collapse = app.buttons["accountCollapseAllToggle"]
        let colCoord = collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<8 { colCoord.tap() }
        XCTAssertTrue(app.buttons["accountCollapseAllToggle"]
            .label == "Collapse all",
            "Collapse-all lost a rapid tap (label: \(app.buttons["accountCollapseAllToggle"].label))")
    }

    // 8. A Recurring row opens a detail page listing that merchant's past charges.
    func testRecurringRowOpensDetail() {
        let app = launch(tab: 3) // Recurring
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recurringRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No recurring rows")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recurringCategoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Recurring detail did not open")
        snap(app, "recurring-detail")
    }
}
