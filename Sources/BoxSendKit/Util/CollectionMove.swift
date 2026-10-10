import Foundation

extension Array {
    /// 与 SwiftUI 的 `move(fromOffsets:toOffset:)` 等价的核心库版本：
    /// 把 source 处的元素整体搬到 destination 之前（destination 按原数组下标计，
    /// 落在被移动元素之后时自动扣掉已删除的个数）。SwiftUI 只在自己的模块里定义
    /// 了这个方法，核心库不依赖 SwiftUI，所以自带一份。
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        for i in source.sorted(by: >) {
            remove(at: i)
        }
        var dest = destination
        for i in source.sorted() where i < destination { dest -= 1 }
        insert(contentsOf: moving, at: Swift.min(Swift.max(0, dest), count))
    }
}
