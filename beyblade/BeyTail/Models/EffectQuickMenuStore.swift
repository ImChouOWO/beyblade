import Foundation
import Combine

/// 六格快捷特效選單。
///
/// 規則：
/// 1. 所有特效一律由第一格開始連續排列。
/// 2. 移除特效後，後方特效會自動向前遞補。
/// 3. 拖曳排序採用插入式排序，不會留下中間空格。
/// 4. UserDefaults 仍使用 effectMenuIDs 儲存，空格以 `_` 表示。
final class EffectQuickMenuStore: ObservableObject {
    static let shared = EffectQuickMenuStore()
    static let storageKey = "effectMenuIDs"
    static let maximumCount = 6

    @Published private(set) var slots: [EffectType?]

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Self.storageKey) == nil {
            slots = Self.makeSlots(
                from: EffectType.defaultMenuEffects
            )
            persist()
        } else {
            slots = Self.decodeSlots(
                defaults.string(
                    forKey: Self.storageKey
                ) ?? ""
            )
            normalizeStoredValue()
        }
    }

    /// 依畫面顯示順序取得所有非空特效。
    var effects: [EffectType] {
        slots.compactMap { $0 }
    }

    var isFull: Bool {
        effects.count >= Self.maximumCount
    }

    func effect(at slotIndex: Int) -> EffectType? {
        guard slots.indices.contains(slotIndex) else {
            return nil
        }

        return slots[slotIndex]
    }

    func contains(_ effect: EffectType) -> Bool {
        effects.contains(effect)
    }

    func reload() {
        let decoded = Self.decodeSlots(
            defaults.string(
                forKey: Self.storageKey
            ) ?? ""
        )

        if decoded != slots {
            slots = decoded
        }

        normalizeStoredValue()
    }

    /// 點擊任一空槽時，都會接在目前最後一個特效之後，
    /// 確保特效永遠由第一格開始連續排列。
    @discardableResult
    func add(
        _ effect: EffectType,
        at slotIndex: Int? = nil
    ) -> Bool {
        guard !contains(effect), !isFull else {
            return false
        }

        var updatedEffects = effects

        if let slotIndex,
           slotIndex < updatedEffects.count {
            let insertionIndex = max(
                0,
                min(slotIndex, updatedEffects.count)
            )

            updatedEffects.insert(
                effect,
                at: insertionIndex
            )
        } else {
            updatedEffects.append(effect)
        }

        commitEffects(updatedEffects)
        return true
    }

    /// 移除指定位置的特效，後方項目會自動向前遞補。
    @discardableResult
    func remove(at slotIndex: Int) -> EffectType? {
        var updatedEffects = effects

        guard updatedEffects.indices.contains(slotIndex) else {
            return nil
        }

        let removedEffect = updatedEffects.remove(
            at: slotIndex
        )

        commitEffects(updatedEffects)
        return removedEffect
    }

    @discardableResult
    func remove(_ effect: EffectType) -> Bool {
        guard let index = effects.firstIndex(
            of: effect
        ) else {
            return false
        }

        _ = remove(at: index)
        return true
    }

    /// 插入式拖曳排序。
    ///
    /// 例如：
    /// A, B, C, D
    ///
    /// 將 A 拖曳至索引 2：
    /// B, C, A, D
    @discardableResult
    func move(
        from sourceIndex: Int,
        to targetIndex: Int
    ) -> Int? {
        var updatedEffects = effects

        guard updatedEffects.indices.contains(sourceIndex),
              targetIndex >= 0,
              targetIndex < Self.maximumCount else {
            return nil
        }

        if sourceIndex == targetIndex {
            return sourceIndex
        }

        let movingEffect = updatedEffects.remove(
            at: sourceIndex
        )

        let insertionIndex = min(
            targetIndex,
            updatedEffects.count
        )

        updatedEffects.insert(
            movingEffect,
            at: insertionIndex
        )

        commitEffects(updatedEffects)
        return insertionIndex
    }

    /// 移除未擁有的特效後，自動重新壓縮排序。
    func removeUnownedEffects(
        isOwned: (EffectType) -> Bool
    ) {
        let ownedEffects = effects.filter(isOwned)

        guard ownedEffects != effects else {
            return
        }

        commitEffects(ownedEffects)
    }

    func resetToDefaults() {
        commitEffects(
            Array(
                EffectType.defaultMenuEffects
                    .prefix(Self.maximumCount)
            )
        )
    }

    /// 供主畫面讀取，回傳連續且已排序的特效。
    static func decode(_ raw: String) -> [EffectType] {
        decodeSlots(raw).compactMap { $0 }
    }

    static func encode(_ effects: [EffectType]) -> String {
        encodeSlots(
            makeSlots(from: effects)
        )
    }

    static func normalizeRaw(_ raw: String) -> String {
        encodeSlots(
            decodeSlots(raw)
        )
    }

    /// 舊資料即使包含中間空格，也會在讀取時自動向前壓縮。
    static func decodeSlots(
        _ raw: String
    ) -> [EffectType?] {
        let tokens = raw.split(
            separator: ",",
            omittingEmptySubsequences: false
        )

        var decodedEffects: [EffectType] = []
        var seen = Set<String>()

        for token in tokens {
            let id = String(token)

            guard !id.isEmpty,
                  id != "_",
                  seen.insert(id).inserted,
                  let effect = EffectType(
                    rawValue: id
                  ) else {
                continue
            }

            decodedEffects.append(effect)

            if decodedEffects.count == maximumCount {
                break
            }
        }

        return makeSlots(from: decodedEffects)
    }

    static func encodeSlots(
        _ slots: [EffectType?]
    ) -> String {
        let compactSlots = makeSlots(
            from: slots.compactMap { $0 }
        )

        return compactSlots
            .map { effect in
                effect?.rawValue ?? "_"
            }
            .joined(separator: ",")
    }

    private static func makeSlots(
        from effects: [EffectType]
    ) -> [EffectType?] {
        var compactEffects: [EffectType] = []
        var seen = Set<String>()

        for effect in effects {
            guard seen.insert(
                effect.rawValue
            ).inserted else {
                continue
            }

            compactEffects.append(effect)

            if compactEffects.count == maximumCount {
                break
            }
        }

        var result = compactEffects.map {
            Optional($0)
        }

        while result.count < maximumCount {
            result.append(nil)
        }

        return result
    }

    private func commitEffects(
        _ newEffects: [EffectType]
    ) {
        commitSlots(
            Self.makeSlots(from: newEffects)
        )
    }

    private func commitSlots(
        _ newSlots: [EffectType?]
    ) {
        let normalized = Self.makeSlots(
            from: newSlots.compactMap { $0 }
        )

        if normalized != slots {
            slots = normalized
        }

        persist()
    }

    private func persist() {
        defaults.set(
            Self.encodeSlots(slots),
            forKey: Self.storageKey
        )
    }

    private func normalizeStoredValue() {
        let normalizedRaw = Self.encodeSlots(slots)

        let storedRaw = defaults.string(
            forKey: Self.storageKey
        ) ?? ""

        if normalizedRaw != storedRaw {
            defaults.set(
                normalizedRaw,
                forKey: Self.storageKey
            )
        }
    }
}
