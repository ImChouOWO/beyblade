# BeyTail iOS

BeyTail 是一套以 SwiftUI、AVFoundation、Vision／Core ML 與 StoreKit 2 開發的 iOS 陀螺辨識與動態尾跡特效應用。

系統可透過即時相機或相簿影片進行陀螺物件偵測、追蹤、尾跡繪製、離線影片渲染與特效購買管理。

## 主要功能

* 即時相機預覽
* 相簿影片選取與播放
* Core ML／Vision 模型推論
* Mock 模式測試
* Hungarian 多目標追蹤
* 陀螺動態尾跡渲染
* 即時錄影與影片輸出
* 相簿影片離線特效渲染
* 裝置方向與 UI 旋轉控制
* StoreKit 2 特效商店
* 非消耗型特效購買
* 恢復購買
* 未購買特效 10 秒試用

## 技術架構

| 功能     | iOS 技術                  |
| ------ | ----------------------- |
| UI     | SwiftUI                 |
| 相機串流   | AVFoundation            |
| 相簿影片選取 | PhotosUI／PhotosPicker   |
| 影片播放   | AVPlayer／AVKit          |
| 模型推論   | Core ML／Vision          |
| 多目標追蹤  | Hungarian Algorithm     |
| 尾跡繪製   | UIKit／Core Graphics     |
| 非同步處理  | Swift Concurrency       |
| 購買管理   | StoreKit 2              |
| 本地偏好設定 | AppStorage／UserDefaults |
| 相簿寫入   | Photos Framework        |

## Android 與 iOS 架構對應

| Android                | iOS                         | 說明                 |
| ---------------------- | --------------------------- | ------------------ |
| `MainActivity.kt`      | `ContentView.swift`         | 主畫面與 SwiftUI UI    |
| ViewModel              | `MainViewModel.swift`       | 狀態機、輸入來源與資源管理      |
| `CameraManager.kt`     | `CameraManager.swift`       | 相機串流與畫面方向          |
| `InferenceEngine.kt`   | `InferenceEngine.swift`     | 模型推論與 Mock 模式      |
| `BeybladeTracker.kt`   | `BeybladeTracker.swift`     | Hungarian 多目標追蹤    |
| `TrailEffectEngine.kt` | `TrailEffectEngine.swift`   | 軌跡點生命週期與淡出管理       |
| `TrailOverlayView.kt`  | `TrailOverlayView.swift`    | 尾跡與特效疊加層           |
| 錄影管理器                  | `RecordingManager.swift`    | 影片錄製與輸出            |
| `EffectType.kt`        | `EffectType.swift`          | 特效定義與商品對應          |
| `buildEffectMenu()`    | `EffectMenuView.swift`      | 快捷特效選單             |
| Google Play Billing    | `EffectPurchaseStore.swift` | StoreKit 2 購買與恢復購買 |

## 專案架構

```text
beyblade/
├── BeyTailApp.swift
│
├── Camera/
│   └── CameraManager.swift
│       └── 相機串流、相機方向與影格輸出
│
├── ML/
│   ├── InferenceEngine.swift
│   │   └── Core ML／Vision 模型推論與 Mock 模式
│   └── BeybladeTracker.swift
│       └── Hungarian 多目標追蹤
│
├── Effects/
│   ├── TrailEffectEngine.swift
│   │   └── 軌跡點生命週期與淡出時間管理
│   └── TrailOverlayView.swift
│       └── 即時尾跡與特效繪製
│
├── Recording/
│   └── RecordingManager.swift
│       └── 相機錄影與影片輸出管理
│
├── Models/
│   ├── EffectType.swift
│   │   └── 特效規格、價格類型與 StoreKit Product ID
│   ├── DetectionResult.swift
│   │   └── 物件偵測結果
│   └── TrailPoint.swift
│       └── 軌跡點資料結構
│
├── StoreKit/
│   └── EffectPurchaseStore.swift
│       ├── StoreKit 2 商品載入
│       ├── 非消耗型商品購買
│       ├── Transaction 驗證
│       ├── currentEntitlements 權限更新
│       └── AppStore.sync 恢復購買
│
└── UI/
    ├── ContentView.swift
    │   ├── 主相機畫面
    │   ├── 底部操作列
    │   ├── 設定頁
    │   └── 特效商店頁
    │
    ├── MainViewModel.swift
    │   ├── App 狀態機
    │   ├── 相機與影片來源切換
    │   ├── 推論與追蹤結果處理
    │   └── 特效使用權限檢查
    │
    ├── EffectMenuView.swift
    │   └── 已擁有特效的快捷選擇選單
    │
    ├── VideoRenderPage.swift
    │   ├── PhotosPicker 相簿影片選取
    │   ├── 離線影片特效渲染
    │   ├── 付費特效試用
    │   ├── 影片下載
    │   └── 影片分享
    │
    ├── VideoFrameSource.swift
    │   └── AVPlayer 影片影格讀取
    │
    └── VideoPlayerView.swift
        └── AVPlayerLayer 影片顯示
```

## 特效規格

### 免費特效

| 特效 | 規格                |   尾跡時間 |
| -- | ----------------- | -----: |
| 閃電 | 固定黃色 `#FFDD22` 尾跡 | 400 ms |
| 火炎 | 固定紅色 `#FF2A12` 尾跡 | 600 ms |
| 星塵 | 擷取陀螺主色作為尾跡顏色      | 280 ms |

### 付費特效

| 特效   | 規格               |   尾跡時間 |
| ---- | ---------------- | -----: |
| 滔天浪潮 | 水感尾跡、水珠粒子與漣漪效果   | 800 ms |
| 不滅鋼盾 | 力場尾跡、噴射火花與旋轉六角裝甲 | 450 ms |
| 爆刃亂舞 | 刀刃尾跡、金屬火花與劍氣效果   | 280 ms |
| 狂暴冰裂 | 冰裂尾跡與碎冰拋射效果      | 800 ms |

> StoreKit 購買權限與試用限制已完成串接；各付費特效的完整粒子與視覺演出仍需依上述規格實作。

## StoreKit 2 特效商店

付費特效使用 StoreKit 2 的非消耗型商品：

```text
chou.beyblade.effect.wave
chou.beyblade.effect.steel_shield
chou.beyblade.effect.blade_dance
chou.beyblade.effect.ice_break
chou.beyblade.effects.premium_pack
```

商品對應如下：

| Product ID                           | 商品        |
| ------------------------------------ | --------- |
| `chou.beyblade.effect.wave`          | 滔天浪潮      |
| `chou.beyblade.effect.steel_shield`  | 不滅鋼盾      |
| `chou.beyblade.effect.blade_dance`   | 爆刃亂舞      |
| `chou.beyblade.effect.ice_break`     | 狂暴冰裂      |
| `chou.beyblade.effects.premium_pack` | 四款付費特效組合包 |

購買紀錄由 Apple Account 與 StoreKit 管理，不需要另外建立使用者登入系統。

App 啟動後會透過 `Transaction.currentEntitlements` 重新檢查目前有效的購買權限。

使用者也可以透過商店頁的「恢復購買」功能呼叫 `AppStore.sync()`，恢復相同 Apple Account 曾購買的特效。

## 特效使用規則

### 免費特效

免費特效可直接用於：

* 即時相機畫面
* 相機錄影
* 相簿影片渲染
* 影片下載
* 影片分享

### 已購買付費特效

已購買的付費特效可完整用於：

* 即時相機畫面
* 相機錄影
* 快捷特效選單
* 相簿影片完整渲染
* 影片下載
* 影片分享

### 未購買付費特效

未購買的付費特效只能進入試用模式：

* 只能使用相簿中的影片
* 不允許使用即時相機正式錄影
* 最多渲染前 10 秒
* 可以在 App 內預覽
* 不可下載到相簿
* 不可透過系統分享
* 不會加入快捷特效選單

## 加入 Xcode 專案

1. 使用 Xcode 建立 SwiftUI iOS App 專案。
2. 將 `BeyTail/` 內的 Swift 檔案加入 App Target。
3. 確認所有檔案的 Target Membership 已勾選。
4. 加入相機、麥克風與相簿權限描述。
5. 將 Core ML 模型加入 App Bundle。
6. 在 App Store Connect 建立 StoreKit 商品。
7. 使用實機或 StoreKit Configuration 測試購買流程。

## 權限設定

專案需要下列權限：

```xml
<key>NSCameraUsageDescription</key>
<string>需要使用相機辨識陀螺並顯示軌跡特效</string>

<key>NSMicrophoneUsageDescription</key>
<string>需要使用麥克風錄製影片聲音</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>需要讀取相簿中的影片進行陀螺辨識</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>需要儲存錄影與特效影片到相簿</string>
```

## 模型設定

建議使用 Core ML 模型：

```text
beyblade/
├── beyblade_detector.mlmodel
├── BeyTailApp.swift
├── Camera/
├── ML/
├── Effects/
├── Models/
├── Recording/
├── StoreKit/
└── UI/
```

也可以使用 `.mlpackage`：

```text
beyblade_detector.mlpackage
```

模型加入 Xcode 後需要確認：

* `Target Membership` 已勾選
* 模型存在於 App Bundle
* 模型名稱與 `InferenceEngine.swift` 中的載入名稱一致

若沒有找到模型，`InferenceEngine` 會進入 Mock 模式，以模擬偵測結果測試 UI、追蹤與尾跡功能。

`.tflite` 模型不能直接透過 Core ML／Vision 載入。若要使用 `.tflite`，需要另外整合 TensorFlow Lite 或 LiteRT iOS Runtime。

## Mock 模式

沒有可用模型時，系統會自動使用 Mock 模式。

Mock 模式可用於測試：

* 相機預覽
* 多目標追蹤
* 軌跡渲染
* UI 旋轉
* 特效選擇
* 錄影流程
* 影片庫流程

Mock 模式不能代表真實模型的準確率與推論效能。

## StoreKit 本機測試

開發階段可以建立 StoreKit Configuration File：

```text
File
→ New
→ File
→ StoreKit Configuration File
```

加入五個非消耗型商品後，在 Scheme 設定中選擇：

```text
Product
→ Scheme
→ Edit Scheme
→ Run
→ Options
→ StoreKit Configuration
```

本機測試時可透過 Xcode StoreKit Transaction Manager：

* 模擬購買成功
* 模擬取消購買
* 模擬待處理交易
* 刪除本機交易
* 測試恢復購買
* 測試退款或撤銷權限

## 商店頁串接 TODO List

### StoreKit 程式功能

* [x] 建立 `EffectPurchaseStore.swift`
* [x] 使用 StoreKit 2 載入商品
* [x] 使用 `Product.purchase()` 購買商品
* [x] 驗證 StoreKit Transaction
* [x] 監聽 `Transaction.updates`
* [x] 使用 `Transaction.currentEntitlements` 更新購買權限
* [x] 使用 `AppStore.sync()` 恢復購買
* [x] 支援單件付費特效
* [x] 支援四款特效組合包
* [x] 將購買狀態串接到特效商店
* [x] 將購買狀態串接到快捷特效選單
* [x] 將購買狀態串接到即時特效選擇
* [x] 將購買狀態串接到影片渲染頁
* [x] 未購買特效限制為相簿影片試用
* [x] 試用影片限制為 10 秒
* [x] 試用結果禁止下載
* [x] 試用結果禁止分享

### App Store Connect

* [ ] 完成 Apple Developer Program 與付費 App 合約
* [ ] 完成銀行與稅務資料
* [ ] 建立 `chou.beyblade.effect.wave`
* [ ] 建立 `chou.beyblade.effect.steel_shield`
* [ ] 建立 `chou.beyblade.effect.blade_dance`
* [ ] 建立 `chou.beyblade.effect.ice_break`
* [ ] 建立 `chou.beyblade.effects.premium_pack`
* [ ] 將五個商品類型設為 Non-Consumable
* [ ] 設定商品名稱與繁體中文描述
* [ ] 設定各商品價格級距
* [ ] 上傳 App 內購買審核截圖
* [ ] 將 App 內購買項目加入 App 版本送審

### 測試與驗證

* [ ] 建立 `.storekit` 本機測試檔
* [ ] 測試每個單件商品購買
* [ ] 測試特效組合包購買
* [ ] 測試使用者取消付款
* [ ] 測試付款 Pending 狀態
* [ ] 測試恢復購買
* [ ] 測試刪除 App 後重新安裝
* [ ] 測試相同 Apple Account 跨裝置恢復
* [ ] 測試退款或撤銷交易後重新鎖定特效
* [ ] 測試無網路時的購買狀態
* [ ] 使用 Sandbox Apple Account 實機測試
* [ ] 使用 TestFlight 測試正式 StoreKit 流程

### 特效實作

* [ ] 完成閃電固定黃色 `#FFDD22` 尾跡
* [ ] 完成火炎固定紅色 `#FF2A12` 尾跡
* [ ] 完成星塵主色擷取尾跡
* [ ] 完成滔天浪潮水珠粒子與漣漪效果
* [ ] 完成不滅鋼盾力場、火花與六角裝甲效果
* [ ] 完成爆刃亂舞刀刃、金屬火花與劍氣效果
* [ ] 完成狂暴冰裂冰裂尾跡與碎冰拋射效果
* [ ] 測試各特效在 30 FPS 與 60 FPS 下的效能
* [ ] 測試長時間錄影的記憶體與 GPU 使用量
