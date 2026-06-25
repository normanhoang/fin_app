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

    // 3b. The Filter button opens the category popup and filters the list.
    func testFilterButtonFiltersTransactions() {
        let app = launch(tab: 1)
        let filter = app.buttons["filterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8), "Filter button missing")
        filter.tap()

        let housing = app.buttons["Housing"].firstMatch
        XCTAssertTrue(housing.waitForExistence(timeout: 5), "Category popup did not open")
        housing.tap()

        XCTAssertTrue(app.staticTexts["Filtered: Housing"].waitForExistence(timeout: 5),
                      "Filter not applied from the popup")
        snap(app, "filter-from-button")
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
        // A confirmed bill lands under the "Upcoming" section; the empty state
        // ("No Recurring Bills") must be gone.
        let upcoming = app.staticTexts["Upcoming"].waitForExistence(timeout: 5)
        snap(app, "recurring-after-set")
        XCTAssertTrue(upcoming, "Upcoming section not shown after Set as Recurring")
        XCTAssertFalse(app.staticTexts["No Recurring Bills"].exists, "Recurring tab still empty")
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

    // 9. Tapping a transaction inside an account opens it in the Transactions tab.
    func testAccountTransactionOpensInTransactions() {
        let app = launch(tab: 0)
        let account = app.descendants(matching: .any).matching(identifier: "accountRow-s-card").firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 8), "Account row not found")
        account.tap()

        let txn = app.descendants(matching: .any).matching(identifier: "acctTxnRow-s-tx-1").firstMatch
        XCTAssertTrue(txn.waitForExistence(timeout: 5), "No account transactions")
        txn.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "categoryMenu").firstMatch
            .waitForExistence(timeout: 5), "Transaction detail did not open in the Transactions tab")
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
