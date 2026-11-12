import Testing
@testable import Oh_My_Code

struct OhMyCodeTests {
    @Test func sidebarItemsHaveTitles() {
        for item in SidebarItem.allCases {
            #expect(!item.title.isEmpty)
        }
    }
}
