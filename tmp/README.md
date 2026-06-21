# BeyTrail iOS — 戰鬥陀螺軌跡特效 App（Android 版移植）

對應 Android 版（`d:\flutter`）功能 1:1 移植。技術選型：

| Android | iOS |
|---------|-----|
| CameraX | AVFoundation（AVCaptureSession） |
| OpenGL ES 2.0 | Metal（MTKView + 離屏紋理） |
| TFLite/NNAPI | Core ML（模型到位後放入 `BeyTrail/Resources/Models/`，未到位自動 Mock） |
| MediaRecorder | AVAssetWriter（H.264 + AAC） |
| Play Billing | StoreKit 2 |
| SharedPreferences | UserDefaults |

最低支援：**iOS 16.0**（StoreKit 2 / PhotosPicker 需求）。UI 採 SwiftUI + MTKView。

---

## 建置環境（必讀）

iOS app **無法在 Windows 編譯**，需要：

1. **Mac**（實體或雲端租用，如 MacinCloud / Scaleway）+ **Xcode 15+**
2. 把整個 `Beytail_ios` 資料夾複製到 Mac
3. 安裝 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
4. 在資料夾根目錄執行：`xcodegen` → 產生 `BeyTrail.xcodeproj`
5. 用 Xcode 開啟，Signing & Capabilities 填入你的 Team，接上 iPhone 即可跑

（不想用 XcodeGen 的話：Xcode 新建 App 專案 → 把 `BeyTrail/` 底下所有 .swift/.metal 拖進去 → 照 `project.yml` 內容設定 Info.plist 權限即可）

---

## 上架前要辦的事

1. **Apple Developer Program**：US$99/年（developer.apple.com）
2. **App Store Connect** 建立 App（Bundle ID：`com.beyblade.trailfilter`，可自行更改）
3. **IAP 商品**（App 內購買 → 非消耗型），ID 與 Android 完全一致：
   | 商品 ID | 內容 | 參考價 |
   |---------|------|--------|
   | waveeffect | 滔天浪潮 | NT$30 |
   | thundereffect | 不滅鋼盾 | NT$30 |
   | vortexeffect | 爆刃亂舞 | NT$30 |
   | darkeffect | 狂暴冰裂 | NT$30 |
   | bundleeffects | 限定特效包 | NT$100 |
4. **隱私權政策 URL**（相機+麥克風 app 必填）
5. App 隱私問卷（收集崩潰資料的話要申報）
6. 送審（首次審查通常 1-3 天）

---

## 陀螺辨識模型

- 預留路徑：`BeyTrail/Resources/Models/BeybladeDetector.mlmodel`（Core ML 格式）
- 你的 `.tflite` 需先轉檔：用 `coremltools`（Python）把 YOLO 模型轉成 Core ML，
  或改用 TensorFlowLiteSwift pod 直接跑 tflite（`InferenceEngine.swift` 介面已預留兩種路線的註解）
- 模型不存在 → 自動 Mock 模式（畫面中央繞圈假資料），UI/特效照常可開發測試

## 付費特效

- StoreKit 2 實作在 `Billing/StoreManager.swift`，商品 ID 沿用 Android
- 含「下架隱藏」與「開發測試白名單」機制（同 Android 的 delisted / devUnlocked）
- App Store Connect 商品建好前，商店會顯示「無法載入價格」— 正常

## 進度

見 [PROGRESS.md](PROGRESS.md) — 若接續開發（新對話），先讀該檔。
