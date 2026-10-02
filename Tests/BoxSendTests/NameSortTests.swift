import XCTest
@testable import BoxSendKit

final class NameSortTests: XCTestCase {
    func testDigitsFirst() {
        XCTAssertEqual(NameSort.sorted(["天空", "13City", "52MOVIE", "Blutopia"]),
                       ["13City", "52MOVIE", "Blutopia", "天空"])
    }

    func testDigitNamesAmongThemselves() {
        XCTAssertEqual(NameSort.sorted(["52PT", "1PT", "13City"]),
                       ["13City", "1PT", "52PT"])
    }

    func testPinyinOrder() {
        // cai hong dao < chun tian < mao < tian kong
        XCTAssertEqual(NameSort.sorted(["天空", "彩虹岛", "春天", "猫"]),
                       ["彩虹岛", "春天", "猫", "天空"])
    }

    func testLatinNamesMixedIntoLetterOrder() {
        // 北邮 (bei) / Blutopia (b) < 皇后 (huang) < 天空 (tian)
        XCTAssertEqual(NameSort.sorted(["天空", "Blutopia", "皇后", "北邮"]),
                       ["北邮", "Blutopia", "皇后", "天空"])
    }

    func testBuiltinCatalogOrderPreview() {
        let names = SiteRegistry.prioritySites.map { $0.name }
        let sorted = NameSort.sorted(names)
        print("ORDER: \(sorted.joined(separator: " | "))")
        // 数字组 = ASCII 数字开头的名称，必须整体位于最前（中文数字汉字如「百川」不进数字组）
        let isDigit = { (s: String) in s.first.map { $0.isASCII && $0.isNumber } == true }
        let digits = names.filter(isDigit)
        XCTAssertEqual(Array(sorted.prefix(digits.count)), digits.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertFalse(sorted.prefix(digits.count).contains("百川"))
    }

    func testSameInitialFallsBackToPinyin() {
        // 同为 m 开头：猫(mao) < 末日 < 莫妮卡（首字 末/莫 同音 mo，按编码顺序 末 < 莫）
        XCTAssertEqual(NameSort.sorted(["莫妮卡", "末日", "猫"]),
                       ["猫", "末日", "莫妮卡"])
    }
}
