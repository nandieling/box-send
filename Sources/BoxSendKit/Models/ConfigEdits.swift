import Foundation

/// 配置层的纯编辑动作（分组增删、站点排序、限速默认值等）。
///
/// 这些规则原来长在 macOS 的 AppModel 里，现在提到核心库：GUI 只负责把用户动作
/// 翻译成一次编辑调用，规则本身（重名加后缀、移回未分组时按名称默认序插入、
/// 新增站点沿用所在分组的默认限速）mac 与 Windows 共用一份，不会各写一遍各跑偏。
public extension AppConfig {

    var managedSites: [SiteConfig] { sourceSites.filter { $0.managed } }

    var unassignedManagedSites: [SiteConfig] {
        managedSites.filter { groupIndex(of: $0.id) < 0 }
    }

    func groupIndex(of siteID: String) -> Int {
        groups.firstIndex { $0.sites.contains(siteID) } ?? -1
    }

    /// 分组的已添加站点（按 group.sites 顺序）；gi = -1 返回未分组
    func groupMembers(_ gi: Int) -> [SiteConfig] {
        if gi < 0 { return unassignedManagedSites }
        guard groups.indices.contains(gi) else { return [] }
        return groups[gi].sites.compactMap { id in
            sourceSites.first { $0.id == id && $0.managed }
        }
    }

    /// 区块内位置（界面用来判断上下按钮是否可用）
    func managedSitePosition(_ siteID: String) -> (index: Int, count: Int) {
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = groups[gi].sites
            if let i = sites.firstIndex(of: siteID) { return (i, sites.count) }
        } else {
            let order = unassignedManagedSites.map { $0.id }
            if let k = order.firstIndex(of: siteID) { return (k, order.count) }
        }
        return (-1, 0)
    }

    mutating func addGroup(name: String, upLimitMB: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        groups.append(GroupConfig(name: trimmed, upLimitMB: max(0, upLimitMB)))
    }

    /// 重命名分组（组内站点与排序不受影响）；重名时自动追加数字后缀
    mutating func renameGroup(at index: Int, name: String) {
        guard groups.indices.contains(index) else { return }
        let base = name.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }
        var finalName = base
        var n = 2
        while groups.enumerated().contains(where: { $0.offset != index && $0.element.name == finalName }) {
            finalName = "\(base)\(n)"
            n += 1
        }
        groups[index].name = finalName
    }

    /// 删除分组：组内已纳管站点退回「批量添加站点」列表（不产生无分组残留）
    mutating func removeGroup(at index: Int, unselect: (String) -> Void = { _ in }) {
        guard groups.indices.contains(index) else { return }
        let members = groups[index].sites
        groups.remove(at: index)
        var returned: [String] = []
        for id in members where site(id)?.managed == true {
            if let i = sourceSites.firstIndex(where: { $0.id == id }) {
                sourceSites[i].managed = false
            }
            unselect(id)
            returned.append(id)
        }
        reinsertUnmanagedOrder(returned)
    }

    /// 移动分组顺序：把名为 dragged 的分组移到 target 之前
    mutating func moveGroup(named dragged: String, before target: String) {
        guard dragged != target,
              let from = groups.firstIndex(where: { $0.name == dragged }),
              let to = groups.firstIndex(where: { $0.name == target }) else { return }
        groups.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    mutating func setGroupUpLimit(at index: Int, mb: Int) {
        guard groups.indices.contains(index) else { return }
        groups[index].upLimitMB = max(0, mb)
    }

    /// 把站点放进指定分组（gi = -1 移出所有分组）
    mutating func setGroup(index: Int, for siteID: String) {
        for i in groups.indices where i != index {
            groups[i].sites.removeAll { $0 == siteID }
        }
        if index >= 0, index < groups.count, !groups[index].sites.contains(siteID) {
            groups[index].sites.append(siteID)
        }
    }

    /// 分组内/未分组区块内上下移动
    mutating func moveManagedSite(_ siteID: String, delta: Int) {
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = groups[gi].sites
            guard let i = sites.firstIndex(of: siteID) else { return }
            let j = i + delta
            guard sites.indices.contains(j) else { return }
            groups[gi].sites.swapAt(i, j)
        } else {
            let order = unassignedManagedSites.map { $0.id }
            guard let k = order.firstIndex(of: siteID) else { return }
            let kk = k + delta
            guard order.indices.contains(kk) else { return }
            guard let a = sourceSites.firstIndex(where: { $0.id == siteID }),
                  let b = sourceSites.firstIndex(where: { $0.id == order[kk] }) else { return }
            sourceSites.swapAt(a, b)
        }
    }

    /// 拖拽排序：把 siteID 移到 targetID 之前（未分组时按 sourceSites 整体顺序移动）
    mutating func moveSite(_ siteID: String, before targetID: String) {
        guard siteID != targetID else { return }
        let gi = groupIndex(of: siteID)
        if gi >= 0 {
            let sites = groups[gi].sites
            guard let from = sites.firstIndex(of: siteID),
                  let to = sites.firstIndex(of: targetID) else { return }
            groups[gi].sites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        } else {
            let ids = sourceSites.map { $0.id }
            guard let from = ids.firstIndex(of: siteID),
                  let to = ids.firstIndex(of: targetID) else { return }
            sourceSites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    /// 按序号排序区块内站点（gi = -1 为未分组区块；序号缺失的排在末尾并保持相对顺序）
    mutating func sortGroupSites(_ gi: Int, by nums: [String: Int]) {
        func stableSorted(_ ids: [String]) -> [String] {
            let indexed = ids.enumerated().map { (offset: $0.offset, id: $0.element) }
            return indexed.sorted { a, b in
                let na = nums[a.id] ?? Int.max
                let nb = nums[b.id] ?? Int.max
                if na != nb { return na < nb }
                return a.offset < b.offset
            }.map { $0.id }
        }
        if gi >= 0, groups.indices.contains(gi) {
            groups[gi].sites = stableSorted(groups[gi].sites)
        } else {
            let order = unassignedManagedSites.map { $0.id }
            var remaining = stableSorted(order)
            sourceSites = sourceSites.map { site in
                guard order.contains(site.id) else { return site }
                let newID = remaining.removeFirst()
                return sourceSites.first { $0.id == newID } ?? site
            }
        }
    }

    /// 批量纳管内置站点到指定分组（gi = -1 不分组）；添加即默认开启，
    /// 限速沿用所在分组的默认值（未设 = 10 MB/s），已有单独设置的保留
    mutating func addManagedSites(_ ids: [String], group gi: Int) {
        guard !ids.isEmpty else { return }
        var changed = false
        sourceSites = sourceSites.map { site in
            var site = site
            if ids.contains(site.id) {
                site.managed = true
                site.enabled = true
                changed = true
            }
            return site
        }
        if gi >= 0, groups.indices.contains(gi) {
            for other in groups.indices where other != gi {
                groups[other].sites.removeAll { ids.contains($0) }
            }
            for id in ids where !groups[gi].sites.contains(id) {
                groups[gi].sites.append(id)
            }
        }
        let defaultMB = (gi >= 0 && groups.indices.contains(gi) && groups[gi].upLimitMB > 0)
            ? groups[gi].upLimitMB : 10
        for id in ids where downloader.siteUpLimits[id] == nil {
            downloader.siteUpLimits[id] = Int64(defaultMB) * 1_048_576
        }
        if changed { unmanagedSiteOrder = unmanagedSiteOrder.filter { !ids.contains($0) } }
    }

    /// 从站点列表移除（保留 cookie 与启用状态，之后可再次添加）
    mutating func removeManagedSite(_ id: String, unselect: (String) -> Void = { _ in }) {
        guard let i = sourceSites.firstIndex(where: { $0.id == id }) else { return }
        sourceSites[i].managed = false
        for g in groups.indices { groups[g].sites.removeAll { $0 == id } }
        unselect(id)
        reinsertUnmanagedOrder([id])
    }

    mutating func setSiteEnabled(_ id: String, _ on: Bool) {
        guard let i = sourceSites.firstIndex(where: { $0.id == id }) else { return }
        sourceSites[i].enabled = on
    }

    /// 各站限速（整数 MB/s，0 = 不限速）
    var siteUpLimitMBInt: [String: Int] {
        var out: [String: Int] = [:]
        for s in sourceSites {
            let v = downloader.siteUpLimits[s.id] ?? 0
            out[s.id] = Int((Double(v) / 1048576.0).rounded())
        }
        return out
    }

    mutating func setSiteUpLimitMB(_ mb: Int?, siteID: String) {
        downloader.siteUpLimits[siteID] = Int64(mb ?? 0) * 1_048_576
    }

    /// 站点退回未分组列表时：已有手动排序不变，返回站点按名称默认序插到其名称序位置
    mutating func reinsertUnmanagedOrder(_ returnedIDs: [String]) {
        let unmanaged = Set(sourceSites.filter { !$0.managed }.map { $0.id })
        let returned = returnedIDs.filter { unmanaged.contains($0) }
        guard !returned.isEmpty else { return }
        let valid = unmanagedSiteOrder.filter { unmanaged.contains($0) }
        unmanagedSiteOrder = NameSort.reinsert(returned, into: valid, name: { site($0)?.name ?? $0 })
    }

    /// 勾选的目标站按 sourceSites 顺序落定；勾上即启用（内置表新站默认 enabled=false）
    mutating func applyTargetSites(_ ids: [String]) {
        var targets = targetSites.filter { ids.contains($0) }
        for s in sourceSites where ids.contains(s.id) && !targets.contains(s.id) {
            targets.append(s.id)
        }
        targetSites = targets
        sourceSites = sourceSites.map { site in
            var site = site
            if targets.contains(site.id) && !site.enabled { site.enabled = true }
            return site
        }
    }
}
