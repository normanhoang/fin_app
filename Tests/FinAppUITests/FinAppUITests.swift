import XCTest

/// End-to-end UI tests driving the real app via accessibility identifiers, so
/// List `NavigationLink`s and `Menu`s fire deterministically (synthetic cursor
/// clicks don't). Launches with FINAPP_UITEST=1 → clean in-memory store seeded
/// with sample data.
@MainActor
final class FinAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Page order (== AppTab rawValues): Accounts 0 · Transactions 1 · Dashboard 2 ·
    /// Recurring 3 · Settings 4. Must move with any app page reorder.
    private static let tabTitles = ["Accounts", "Transactions", "Dashboard", "Recurring", "Settings"]

    private func launch(tab: Int = 0, lockOnBackground: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FINAPP_UITEST"] = "1"
        app.launchEnvironment["FINAPP_TAB"] = String(tab)
        if lockOnBackground {
            app.launchEnvironment["FINAPP_UI_LOCK_ON_BACKGROUND"] = "1"
        }
        app.launch()
        // The pager builds all pages up-front, so `exists` is true even for
        // elements on off-screen pages (their frames sit a page-width off to the
        // side) — assert the landing page's nav bar is actually on screen, or a
        // stale tab index hangs isHittable loops instead of failing.
        let bar = app.navigationBars[Self.tabTitles[tab]]
        XCTAssertTrue(bar.waitForExistence(timeout: 8),
                      "\(Self.tabTitles[tab]) nav bar missing after launch")
        let mid = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(mid),
                      "Launch did not land on \(Self.tabTitles[tab]) (tab \(tab)); nav bar off-screen at \(bar.frame)")
        return app
    }

    /// Scrolls until `element` is hittable, bounded so a wrong page or missing
    /// element fails fast instead of swiping forever. "Hittable" alone is not
    /// enough: an element whose frame pokes into the floating tab-bar band
    /// reports hittable, but the tap lands on the bar and is swallowed — so
    /// also require the element to sit clear of the bottom band.
    private func swipeUpUntilHittable(_ app: XCUIApplication, _ element: XCUIElement,
                                      maxSwipes: Int = 6) {
        let clearOfTabBar = app.windows.firstMatch.frame.maxY - 120
        func ready() -> Bool { element.isHittable && element.frame.maxY < clearOfTabBar }
        var swipes = 0
        while !ready() && swipes < maxSwipes { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(ready(), "\(element) not hittable clear of the tab bar after \(maxSwipes) swipes")
    }

    /// The visible Spending Categories filter button.
    private func categoryFilterHeader(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "categoryFilterButton").firstMatch
    }

    private func openCategoryFilter(_ app: XCUIApplication) {
        let header = categoryFilterHeader(app)
        swipeUpUntilHittable(app, header)
        header.tap()
    }

    /// Find a category toggle in the filter sheet, which is a medium-detent List:
    /// expand it via its grabber, then scroll the sheet's own collection view (the
    /// paging RootView contributes several others) until the row exists. Lazy rows
    /// scrolled off-screen are absent from the tree.
    @discardableResult
    private func filterSheetRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.buttons[id].firstMatch
        if row.waitForExistence(timeout: 3) { return row }
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.exists { grabber.swipeUp() }
        var swipes = 0
        let window = app.windows.firstMatch.frame
        while !row.waitForExistence(timeout: 1) && swipes < 6 {
            let onScreen = app.collectionViews.allElementsBoundByIndex
                .filter { $0.frame.minX >= 0 && $0.frame.minX < window.width && !$0.frame.isEmpty }
            onScreen.last?.swipeUp()
            swipes += 1
        }
        return row
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

    // 1c. With no budgets, the Dashboard shows an empty-state card whose Add
    //     button opens the New Budget form (so budgets stay reachable).
    func testEmptyBudgetsCardAddsBudget() {
        let app = XCUIApplication()
        app.launchEnvironment["FINAPP_UITEST"] = "1"
        app.launchEnvironment["FINAPP_TAB"] = "2"
        app.launchEnvironment["FINAPP_NO_BUDGETS"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 8))

        let add = app.buttons["addBudgetButton"]
        for _ in 0..<6 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable, "Empty budgets card / Add button missing")
        add.tap()

        XCTAssertTrue(app.navigationBars["New Budget"].waitForExistence(timeout: 5),
                      "Add Budget form did not open from the empty card")
    }

    // 1d. Tapping a budget row opens the edit sheet for its monthly limit.
    func testBudgetRowOpensEdit() {
        let app = launch(tab: 2)
        let edit = app.buttons["budgetsEditButton"]
        for _ in 0..<6 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "Budgets card Edit button missing")

        // Tapping Edit occasionally doesn't register the sheet under load; retry
        // while we're still on the Dashboard (the Edit button is still present).
        let budgetsNav = app.navigationBars["Budgets"]
        for _ in 0..<3 {
            if edit.isHittable { edit.tap() }   // only tap while still on the Dashboard
            if budgetsNav.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(budgetsNav.exists, "Budgets manager did not open")
        let row = app.buttons["budgetRow-Dining"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Budget row missing")

        let editNav = app.navigationBars["Edit Budget"]
        for _ in 0..<3 {
            if row.isHittable { row.tap() }
            if editNav.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(editNav.exists, "Edit Budget sheet did not open")
        XCTAssertTrue(app.textFields["editBudgetLimitField"].exists, "Limit field missing")
    }

    // 1e. Over-budget budgets show a dismissible alert on the Dashboard card.
    func testOverBudgetAlertDismiss() {
        let app = launch(tab: 2)
        // Sample data: Dining is over its $30 budget on every calendar day —
        // its month-pinned rows alone total $35.75. (Groceries is only over
        // mid-month, when the day-ago rows land inside the current month.)
        let alert = app.buttons["dismissOverBudget-Dining"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "Over-budget alert missing")
        swipeUpUntilHittable(app, alert)
        alert.tap()
        XCTAssertFalse(app.buttons["dismissOverBudget-Dining"].waitForExistence(timeout: 3),
                       "Dismissing should hide the over-budget alert")
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

    // 3c. The filter popup's "Uncategorized" option filters the list — the
    // categorized Whole Foods row drops out.
    func testUncategorizedFilterOption() {
        let app = launch(tab: 1)
        // Netflix's newest recurring charge posts "today", so this row is at the
        // top of the list on every calendar date (day-ago seed rows can fall
        // into the previous month and scroll off-screen on the 1st).
        let categorized = app.buttons["txnRow-s-rec-Netflix-0"] // Netflix · Subscriptions
        XCTAssertTrue(categorized.waitForExistence(timeout: 8), "Seed rows missing")

        app.buttons["filterButton"].tap()
        let uncategorized = app.buttons["txnCatToggle-Uncategorized"].firstMatch
        XCTAssertTrue(uncategorized.waitForExistence(timeout: 5), "Filter popup did not open")
        uncategorized.tap()
        app.buttons["filterDone"].tap()

        XCTAssertFalse(categorized.waitForExistence(timeout: 3),
                       "Categorized row should be filtered out by Uncategorized")
        snap(app, "filter-uncategorized")
    }

    // 3b. The single filter button opens the combined popup and applies a
    // category filter (month subtotals surface once a facet is active).
    func testFilterButtonFiltersTransactions() {
        let app = launch(tab: 1)
        app.buttons["filterButton"].tap()

        let housing = filterSheetRow(app, "txnCatToggle-Housing")
        XCTAssertTrue(housing.exists, "Filter popup did not open / Housing missing")
        housing.tap()
        app.buttons["filterDone"].tap()

        // The active facet surfaces as a removable chip under the search bar.
        let chip = app.buttons["facetChip-Housing"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Active-filter chip not shown under search")
        snap(app, "filter-from-button")
        chip.tap()
        XCTAssertFalse(app.buttons["facetChip-Housing"].waitForExistence(timeout: 2),
                       "Tapping the chip should remove the facet")
    }

    // 3e. Month stepper only visits months that have entries: forward is dead
    // at "All time", back walks to the oldest month with data then disables.
    func testMonthStepperBoundedByData() {
        let app = launch(tab: 1)
        app.buttons["filterButton"].tap()

        let back = app.buttons["filterMonthBack"]
        let forward = app.buttons["filterMonthForward"]
        let label = app.staticTexts["filterMonthLabel"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Filter popup missing")
        XCTAssertEqual(label.label, "All time")
        XCTAssertFalse(forward.isEnabled, "Forward should be disabled at All time")

        back.tap()
        XCTAssertNotEqual(label.label, "All time", "Back from All time should enter the newest month")

        var steps = 0
        while back.isEnabled && steps < 24 { back.tap(); steps += 1 }
        XCTAssertFalse(back.isEnabled, "Back should disable at the oldest month with entries")
        XCTAssertTrue(forward.isEnabled, "Forward should re-enable once off the newest month")
    }

    // 3f. Month subtotals appear only when a facet filter narrows the list, and
    // are absent during plain browsing.
    func testMonthSubtotalsShownWhenFiltered() {
        let app = launch(tab: 1)
        let subtotal = app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
        XCTAssertFalse(subtotal.waitForExistence(timeout: 3), "Subtotal should be hidden when unfiltered")

        app.buttons["filterButton"].tap()
        let housing = filterSheetRow(app, "txnCatToggle-Housing")
        XCTAssertTrue(housing.exists, "Filter popup did not open / Housing missing")
        housing.tap()
        app.buttons["filterDone"].tap()

        XCTAssertTrue(subtotal.waitForExistence(timeout: 5),
                      "Subtotal missing with a category filter active")
        snap(app, "month-subtotals")
    }

    // 3g. The Type segmented control applies a flow filter from the combined popup.
    func testTypeFilterRoundTrip() {
        let app = launch(tab: 1)
        app.buttons["filterButton"].tap()

        let picker = app.segmentedControls["typeFilterPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Type picker missing")
        picker.buttons["Expenses"].tap()
        app.buttons["filterDone"].tap()

        let subtotal = app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
        XCTAssertTrue(subtotal.waitForExistence(timeout: 5), "Type filter not applied")

        // Clear All from the popup removes it. It sits below the category rows,
        // which can push it under the medium sheet's fold — scroll the sheet.
        app.buttons["filterButton"].tap()
        filterSheetRow(app, "filterClearAll").tap()
        app.buttons["filterDone"].tap()
        XCTAssertFalse(subtotal.waitForExistence(timeout: 3), "Clear All did not remove the type filter")
    }

    // 3d. Multiple categories can be selected in the popup, and Clear All resets
    // every facet.
    func testMultiSelectAndClearAllFilters() {
        let app = launch(tab: 1)
        app.buttons["filterButton"].tap()

        let housing = filterSheetRow(app, "txnCatToggle-Housing")
        XCTAssertTrue(housing.exists, "Filter popup did not open / Housing missing")
        housing.tap()
        filterSheetRow(app, "txnCatToggle-Dining").tap()
        app.buttons["filterDone"].tap()

        let subtotal = app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
        XCTAssertTrue(subtotal.waitForExistence(timeout: 5), "Multi-select filter not applied")

        app.buttons["filterButton"].tap()
        filterSheetRow(app, "filterClearAll").tap()
        app.buttons["filterDone"].tap()
        XCTAssertFalse(subtotal.waitForExistence(timeout: 3), "Clear All did not remove the filter")
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
        // confirmed bill lands under the "Due Soon" section; the empty state
        // ("No Recurring Bills") must be gone.
        let listSeg = app.buttons["recurringSeg-List"]
        XCTAssertTrue(listSeg.waitForExistence(timeout: 5), "Mode control not shown")
        listSeg.tap()
        let dueSoon = app.staticTexts["Due Soon"].waitForExistence(timeout: 5)
        snap(app, "recurring-after-set")
        XCTAssertTrue(dueSoon, "Due Soon section not shown after Set as Recurring")
        XCTAssertFalse(app.staticTexts["No Recurring Bills"].exists, "Recurring tab still empty")
        // Restore the default calendar mode (it persists via AppStorage).
        app.buttons["recurringSeg-Calendar"].tap()
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
            app.buttons["recurringSeg-Calendar"].tap()
        }

        // The tapped row's newest charge posts "today", and setRecurring projects
        // monthly bills with a calendar month step (+1 month, not +30 days — the
        // two differ in 31-day months).
        let cal = Calendar.current
        let due = cal.date(byAdding: .month, value: 1, to: .now)!
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

        XCTAssertTrue(app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
            .waitForExistence(timeout: 5), "Filter not active on Transactions after drill-in")
        snap(app, "filtered-housing")
    }

    // 5b. Swiping back to Transactions clears a leftover filter (tab tap too).
    func testSwipingToTransactionsClearsFilter() {
        let app = launch(tab: 2)
        app.buttons["category-Housing"].tap()
        let subtotal = app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
        XCTAssertTrue(subtotal.waitForExistence(timeout: 5))

        app.swipeRight()   // to Accounts
        XCTAssertTrue(app.staticTexts["Assets"].waitForExistence(timeout: 5))
        app.swipeLeft()    // back to Transactions

        XCTAssertFalse(subtotal.waitForExistence(timeout: 2),
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

    // 6c. Adding a note in the transaction detail persists across a back-navigate
    //     and re-open (stored on the model, not view state).
    func testTransactionNotePersists() {
        let app = launch(tab: 1)
        let row = firstTxnRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No transaction rows")
        row.tap()

        let field = app.descendants(matching: .any).matching(identifier: "txnNoteField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Note field missing")
        field.tap()
        let note = "split with roommate"
        field.typeText(note)

        // The pager ignores the keyboard safe area, so the detail view restores
        // its own avoidance (keyboardAvoiding + KeyboardReveal) — the focused
        // field must sit fully above the keyboard while typing.
        let keyboard = app.keyboards.element
        if keyboard.waitForExistence(timeout: 2) {
            sleep(1) // let the reveal scroll settle
            XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY,
                                     "Note field hidden behind keyboard")
        }
        snap(app, "transaction-note")

        app.navigationBars.buttons.element(boundBy: 0).tap() // back to list
        XCTAssertTrue(firstTxnRow(app).waitForExistence(timeout: 5))
        firstTxnRow(app).tap()

        let reopened = app.descendants(matching: .any).matching(identifier: "txnNoteField").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), "Note field missing after re-open")
        XCTAssertEqual(reopened.value as? String, note, "Note did not persist")

        // Back to the list: the row shows the note icon, and search matches note text.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let noteIcon = app.images["note.text"].firstMatch
        XCTAssertTrue(noteIcon.waitForExistence(timeout: 5), "Note icon missing from row")
        let searchField = app.textFields["txnSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("roommate")
        XCTAssertTrue(firstTxnRow(app).waitForExistence(timeout: 5),
                      "Search should match the transaction by its note")
        snap(app, "note-search-match")
    }

    // 6b. Tapping the Transactions tab clears an active filter from the Dashboard.
    func testTransactionsTabClearsFilter() {
        let app = launch(tab: 2)
        let housing = app.buttons["category-Housing"]
        XCTAssertTrue(housing.waitForExistence(timeout: 8))
        housing.tap()
        let subtotal = app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
        XCTAssertTrue(subtotal.waitForExistence(timeout: 5))

        app.buttons["tab-Transactions"].tap()
        XCTAssertFalse(subtotal.waitForExistence(timeout: 2),
                       "Filter should clear when tapping the Transactions tab")
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

        XCTAssertTrue(app.staticTexts.matching(identifier: "monthSubtotal").firstMatch
            .waitForExistence(timeout: 5), "Filter not active after re-filter")
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

        // Land the row in the safe band between the nav bar and the floating tab
        // bar (which overlays the bottom of the list) before tapping: a row resting
        // under the tab bar taps the bar instead of pushing the detail. Position
        // with a single tap afterward — retrying taps after a navigation would just
        // scroll the pushed detail.
        // Netflix's newest recurring charge posts "today", so this row sits near
        // the top of the card's list on every calendar date (day-ago seed rows
        // can fall into the previous month and end up far down the list).
        let txn = app.descendants(matching: .any).matching(identifier: "acctTxnRow-s-rec-Netflix-0").firstMatch
        for _ in 0..<12 {
            guard txn.exists else { app.swipeDown(); continue }
            let midY = txn.frame.midY
            if txn.isHittable && midY > 200 && midY < 680 { break }
            if midY < 200 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(txn.isHittable, "Account transaction row not positioned")
        // Tap the payee text, not the row container: a container tap can resolve to
        // the row's nested category-icon button (opening the picker) instead of the
        // NavigationLink. The static text has no gesture of its own, so it bubbles
        // to the link.
        txn.staticTexts["Netflix"].tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
            .waitForExistence(timeout: 10), "Transaction detail did not open")

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

    func testPresentedSheetIsCoveredAfterBackgroundLock() {
        let app = launch(tab: 0, lockOnBackground: true)
        let addButton = app.buttons["addAccountButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        addButton.tap()
        let nameField = app.textFields["accountNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Add Account sheet did not open")

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["FinApp is locked"].waitForExistence(timeout: 8))
        XCTAssertFalse(nameField.isHittable, "Presented sheet remained interactive above App Lock")
    }

    // 10. Tapping a trend bar shows the value popup; scrolling the page dismisses it.
    func testTrendPopupOpensAndScrollDismisses() {
        let app = launch(tab: 2)
        let chart = app.descendants(matching: .any).matching(identifier: "trendChart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 8), "Trend chart not found")
        // The trend card is below the fold — scroll it into view before tapping.
        swipeUpUntilHittable(app, chart)
        // Tap a bar to open the popup. Under load a tap can miss (landing during a
        // scroll settle / on the floating tab bar), so retry across DIFFERENT bars
        // — re-tapping the same bar would toggle the popup back off.
        let popup = app.descendants(matching: .any).matching(identifier: "trendPopup").firstMatch
        var opened = false
        for x in [0.5, 0.66, 0.34, 0.5] {
            chart.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.35)).tap()
            if popup.waitForExistence(timeout: 3) { opened = true; break }
        }
        XCTAssertTrue(opened, "Trend popup did not open")
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
        let nameField = app.textFields["accountNameField"]
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
        swipeUpUntilHittable(app, deleteBtn)
        deleteBtn.tap()

        // The confirmation renders as a popover anchored to the button: there is
        // no Cancel button — tapping outside dismisses it.
        let confirm = app.buttons["Confirm Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Delete confirmation missing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(confirm.waitForExistence(timeout: 3),
                       "Tapping outside should dismiss the confirmation")
        XCTAssertTrue(app.navigationBars[name].exists, "Cancelling deletion should keep the account")

        deleteBtn.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Destructive confirmation missing")
        confirm.tap()

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

        openCategoryFilter(app)

        let toggle = app.buttons["catToggle-Groceries"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Category filter popup did not open")
        toggle.tap()
        // Tap away (outside the popover) to dismiss it.
        app.navigationBars["Dashboard"].tap()

        XCTAssertFalse(app.buttons["category-Groceries"].waitForExistence(timeout: 3),
                       "Hidden category should be removed from the Spending Categories list")
        snap(app, "category-hidden")
    }

    // 14a. Income categories are absent from the filter popup — the Spending
    //      Categories list excludes them either way, so a toggle would do nothing.
    func testFilterPopupOmitsIncomeCategories() {
        let app = launch(tab: 2)
        XCTAssertTrue(categoryFilterHeader(app).waitForExistence(timeout: 8), "Category header not found")
        openCategoryFilter(app)

        XCTAssertTrue(app.buttons["catToggle-Groceries"].waitForExistence(timeout: 5),
                      "Category filter popup did not open")
        XCTAssertFalse(app.buttons["catToggle-Income"].exists,
                       "Income should not be listed in the filter popup")
    }

    // 14b. Filter checkbox is half-filled for a hidden category that still has
    //      current-month spend, empty for a hidden category with none. (Fresh
    //      sample dates the recurring Netflix/Spotify charges to today →
    //      Subscriptions has this-month spend; Bars has none.) The first tap
    //      also disables Auto and seeds the flags from Auto's view, so Bars
    //      (no spend) lands hidden/"empty" without being touched.
    func testFilterCheckboxReflectsSpend() {
        let app = launch(tab: 2)
        XCTAssertTrue(categoryFilterHeader(app).waitForExistence(timeout: 8), "Category header not found")
        openCategoryFilter(app)

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
        // The filter button tints green under Auto; colour isn't queryable, so
        // assert the a11y value that rides along with it.
        XCTAssertEqual(categoryFilterHeader(app).value as? String, "Auto")

        openCategoryFilter(app)

        let auto = app.buttons["catAutoToggle"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not open")
        XCTAssertEqual(auto.value as? String, "on")
        auto.tap()
        app.navigationBars["Dashboard"].tap() // dismiss the popover
        XCTAssertTrue(app.buttons["category-Bars"].waitForExistence(timeout: 3),
                      "Manual state (all visible) should take over when Auto is off")
        XCTAssertEqual(categoryFilterHeader(app).value as? String, "Custom",
                       "Filter button should drop its Auto tint when Auto is off")

        openCategoryFilter(app)
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not reopen")
        auto.tap()
        app.navigationBars["Dashboard"].tap()
        XCTAssertFalse(app.buttons["category-Bars"].waitForExistence(timeout: 2),
                       "Re-enabling Auto should re-derive from spend")
        XCTAssertEqual(categoryFilterHeader(app).value as? String, "Auto")
    }

    // 14e. Tapping a popup toggle disables Auto and seeds the manual flags from
    //      Auto's view — the visible set only changes by the tapped row.
    func testPopupTapDisablesAutoAndSeeds() {
        let app = launch(tab: 2)
        XCTAssertTrue(categoryFilterHeader(app).waitForExistence(timeout: 8), "Category header not found")
        openCategoryFilter(app)

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
        openCategoryFilter(app)
        let auto = app.buttons["catAutoToggle"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Filter popup did not reopen")
        XCTAssertEqual(auto.value as? String, "off", "Popup tap should disable Auto")
    }

    // 14c. Hiding every category must not make the whole card (and its filter
    //      button) disappear — otherwise there's no way to re-show categories.
    func testCategoryCardSurvivesAllHidden() {
        let app = launch(tab: 2)
        XCTAssertTrue(categoryFilterHeader(app).waitForExistence(timeout: 8), "Category header not found")
        openCategoryFilter(app)

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

        XCTAssertTrue(categoryFilterHeader(app).waitForExistence(timeout: 3),
                      "Category header vanished when all categories hidden")
        XCTAssertTrue(app.staticTexts["All categories hidden — tap the filter to show some."].exists,
                      "Card body missing when all categories hidden")
        snap(app, "categories-all-hidden")
    }

    // 8b. Collapse All / Expand All (inside the sort menu) hides and restores
    //     account rows, and keeps working across repeated rounds (regression:
    //     strict set equality made the first collapse a visual no-op when
    //     collapsedTypes held stale types).
    func testCollapseAllToggleHidesAndRestoresRows() {
        let app = launch(tab: 0) // Accounts
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'accountRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No account rows")

        let menu = app.buttons["accountSortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "Sort menu not found")

        for i in 1...3 {
            menu.tap()
            XCTAssertTrue(app.buttons["Collapse All"].waitForExistence(timeout: 3),
                          "Collapse All item missing (round \(i))")
            app.buttons["Collapse All"].tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 3),
                          "Rows still visible after collapse-all (round \(i))")
            menu.tap()
            XCTAssertTrue(app.buttons["Expand All"].waitForExistence(timeout: 3),
                          "Expand All item missing (round \(i))")
            app.buttons["Expand All"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 3),
                          "Rows did not return after expand-all (round \(i))")
        }
        snap(app, "collapse-all-expanded")
    }

    // 8c. Picking a sort mode from the menu registers and is reflected in the
    //     menu's label (replaces the old two-state toggle parity check).
    func testSortMenuSelectionRegisters() {
        let app = launch(tab: 0) // Accounts
        let menu = app.buttons["accountSortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "Sort menu not found")

        menu.tap()
        XCTAssertTrue(app.buttons["Name"].firstMatch.waitForExistence(timeout: 3), "Name option missing")
        app.buttons["Name"].firstMatch.tap()
        XCTAssertTrue(app.buttons["accountSortMenu"].label.contains("Name"),
                      "Sort selection did not register (label: \(app.buttons["accountSortMenu"].label))")

        // Restore the default: @AppStorage persists across launches on this sim.
        menu.tap()
        XCTAssertTrue(app.buttons["Balance"].firstMatch.waitForExistence(timeout: 3), "Balance option missing")
        app.buttons["Balance"].firstMatch.tap()
        XCTAssertTrue(app.buttons["accountSortMenu"].label.contains("Balance"),
                      "Sort did not restore to Balance (label: \(app.buttons["accountSortMenu"].label))")
    }

    // 8. A Recurring row opens a detail page listing that merchant's past charges.
    func testRecurringRowOpensDetail() {
        let app = launch(tab: 3) // Recurring
        // Rows live under Due Soon in list mode; in calendar mode they sit
        // below the fold and lazy List rows off-screen are absent from the
        // element tree.
        let listSeg = app.buttons["recurringSeg-List"]
        XCTAssertTrue(listSeg.waitForExistence(timeout: 8), "Mode control missing")
        listSeg.tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recurringRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No recurring rows")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recurringCategoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Recurring detail did not open")
        snap(app, "recurring-detail")
    }
}
