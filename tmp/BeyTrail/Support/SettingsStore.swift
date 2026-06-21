import Foundation

/// 偏好設定（對應 Android SettingsPrefs / QuickMenuPrefs / PurchasePrefs 快取）
enum SettingsStore {
    private static let d = UserDefaults.standard

    // 60fps 模式
    static var is60Fps: Bool {
        get { d.bool(forKey: "pref_60fps") }
        set { d.set(newValue, forKey: "pref_60fps") }
    }

    // 手電筒記憶
    static var torchOn: Bool {
        get { d.bool(forKey: "torch_on") }
        set { d.set(newValue, forKey: "torch_on") }
    }

    // 快捷選單（最多 6 個特效）
    static var quickMenu: [EffectType] {
        get {
            let raw = d.stringArray(forKey: "quick_menu")
                ?? ["lightning", "fire", "stardust"]
            return raw.compactMap(EffectType.init(rawValue:))
        }
        set { d.set(newValue.map(\.rawValue), forKey: "quick_menu") }
    }

    // 購買紀錄本地快取（啟動先還原，StoreKit 查詢成功後覆蓋）
    static var cachedOwnedProducts: Set<String> {
        get { Set(d.stringArray(forKey: "owned_products") ?? []) }
        set { d.set(Array(newValue), forKey: "owned_products") }
    }

    // 倒數秒數
    static var timerSeconds: Int {
        get { let v = d.integer(forKey: "timer_seconds"); return v == 0 ? 3 : v }
        set { d.set(newValue, forKey: "timer_seconds") }
    }
}
