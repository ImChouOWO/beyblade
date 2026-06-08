# BeyTail iOS — 參考實作

Android 版移植的最簡結構，用於 iOS 開發參考。

## 架構對應表

| Android | iOS | 說明 |
|---|---|---|
| `MainActivity.kt` | `ContentView.swift` + `MainViewModel.swift` | 主畫面 UI + 狀態 |
| `CameraManager.kt` | `CameraManager.swift` | 相機串流 |
| `InferenceEngine.kt` | `InferenceEngine.swift` | 模型推論 / mock |
| `BeybladeTracker.kt` | `BeybladeTracker.swift` | Hungarian 多目標追蹤 |
| `TrailEffectEngine.kt` | `TrailEffectEngine.swift` | 軌跡點管理 |
| `TrailOverlayView.kt` | `TrailOverlayView.swift` | 軌跡繪製疊加層 |
| `GLRecordingManager.kt` | `RecordingManager.swift` | 螢幕錄製 |
| `EffectType.kt` | `EffectType.swift` | 特效定義 |
| `buildEffectMenu()` | `EffectMenuView.swift` | 特效選單 |

## 技術對應

| Android | iOS |
|---|---|
| CameraX | AVFoundation |
| LiteRT (TFLite) | Core ML / Vision |
| OpenGL ES (trail) | Core Graphics (trail) |
| MediaProjection | ReplayKit |
| ConstraintLayout | SwiftUI ZStack/VStack |
| Coroutines | Swift Concurrency (async/await) |

## 加入 Xcode 專案

1. 在 Xcode 建新 iOS App 專案（SwiftUI, Swift）
2. 把 `BeyTail/` 資料夾內所有 `.swift` 拖進 Xcode
3. 替換自動產生的 `ContentView.swift`
4. 在 Info.plist 加入相機/麥克風/相簿權限描述
5. 有模型時：把 `beyblade_detector.mlmodel` 加進 Bundle，`InferenceEngine` 會自動載入

## Mock 模式

沒有 `.mlmodel` 時自動啟用，行為與 Android mock 相同（兩顆陀螺繞圈）。

## 主要架構
```
ios/BeyTail/
├── BeyTailApp.swift          ← App 進入點
├── Camera/
│   └── CameraManager.swift   ← 相機串流（AVFoundation）
├── ML/
│   ├── InferenceEngine.swift ← 模型推論 + mock 模式
│   └── BeybladeTracker.swift ← Hungarian 多目標追蹤
├── Effects/
│   ├── TrailEffectEngine.swift ← 軌跡點管理
│   └── TrailOverlayView.swift  ← 軌跡繪製
├── Recording/
│   └── RecordingManager.swift ← 螢幕錄製（ReplayKit）
├── Models/
│   ├── EffectType.swift       ← 特效定義
│   ├── DetectionResult.swift  ← 辨識結果資料結構
│   └── TrailPoint.swift       ← 軌跡點資料結構
└── UI/
    ├── ContentView.swift      ← 主畫面
    ├── EffectMenuView.swift   ← 特效選單
    ├── VideoFrameSource.swift
    ├── VideoPlayerView.swift
    └── MainViewModel.swift    ← 狀態管理
唯一缺的是模型檔本身（.tflite 或 .mlmodel），要自己拖進 Xcode，程式碼裡已經寫好讀取邏輯。

模型要拖進 Xcode 的專案根目錄（跟 BeyTailApp.swift 同一層）：

BeyTail/                     ← 拖到這裡
├── beyblade_detector.tflite  ← ✅ 放這
├── BeyTailApp.swift
├── Camera/
├── ML/
```