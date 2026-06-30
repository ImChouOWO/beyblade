# BeyTail Metal Effects Port

此套件以使用者提供的 10 支 Android/Kotlin `GLEffect` 原始碼為基準，將 GPU 管線改寫為 iOS Metal。它不是把上一版 Swift OpenGL 結果再包裝成 Metal，而是保留 Kotlin CPU 端的軌跡幾何、粒子池、生成條件、速度、衰減與多 pass 順序，再將 21 組 GLSL program 對應成 Metal Shading Language。

## 執行路徑

### 即時預覽

```text
SwiftUI ContentView
    → TrailOverlayRepresentable
    → MetalTrailOverlayView (MTKView)
    → MetalEffectFactory
    → 10 個獨立 MetalEffect 類別
    → MTLRenderCommandEncoder
    → BeyTailEffects.metal
```

### 錄影與離線影片

```text
RecordingManager / VideoRenderProcessor
    → PicTrailPixelBufferCompositor
    → PicTrailMetalRenderCore（本套件替換版）
    → 相同的 MetalEffectFactory 與 MetalEffect 類別
    → BeyTailEffects.metal
```

因此即時預覽、錄影與離線影片不再各自維護不同的特效近似版本。

## 包含的特效

| Kotlin | Metal Swift | EffectType |
|---|---|---|
| `GenericGLEffect.kt` | `GenericMetalEffect.swift` | `lightning`、`fire`、`stardust` |
| `WaveGLEffect.kt` | `WaveMetalEffect.swift` | `wave` |
| `MoneyGLEffect.kt` | `MoneyMetalEffect.swift` | `thunder` |
| `BladeGLEffect.kt` | `BladeMetalEffect.swift` | `vortex` |
| `IceShatterGLEffect.kt` | `IceShatterMetalEffect.swift` | `dark` |
| `CrimsonLotusGLEffect.kt` | `CrimsonLotusMetalEffect.swift` | `crimson` |
| `DeathRayGLEffect.kt` | `DeathRayMetalEffect.swift` | `deathRay` |
| `EmeraldGLEffect.kt` | `EmeraldMetalEffect.swift` | `emerald` |
| `InkWashGLEffect.kt` | `InkWashMetalEffect.swift` | `inkWash` |
| `SprayPaintGLEffect.kt` | `SprayPaintMetalEffect.swift` | `spray` |

## 主要修改

- 完全不使用 `GLKView`、`EAGLContext`、`OpenGLES` 或 `GLKit`。
- 使用 `MTKView`、`MTLRenderPipelineState`、`MTLBuffer`、`MTLRenderCommandEncoder` 與 MSL。
- 21 組 Kotlin GLSL shader 邏輯集中移植到 `BeyTailEffects.metal`。
- 保留每個 Kotlin 特效獨立的 CPU 粒子狀態與繪製順序。
- 即時預覽以固定 30 Hz 驅動，避免 60/120 Hz 螢幕增加隨機粒子生成次數。
- 錄影與離線渲染依影片 timestamp 計算 `dtScale`，沿用 Kotlin 的 30 FPS 基準物理量。
- 模型推論低於顯示更新率時，使用固定像素間距補齊軌跡中心線。
- Kotlin `GL_LINES + glLineWidth` 改為 CPU 產生三角形寬線，避免不同 Apple GPU 的線寬差異。
- 一般 alpha 與 additive blending 使用不同 Metal pipeline state。
- 使用三重緩衝暫存 `MTLBuffer`，避免每個粒子 draw call 都建立新 buffer。

## 修改檔案結構

```text
beyblade/BeyTail/
├── Effects/
│   └── TrailOverlayView.swift
└── UI/
    ├── MetalEffects/
    │   ├── Core/
    │   │   ├── MetalEffect.swift
    │   │   ├── MetalEffectFactory.swift
    │   │   ├── MetalFloatBuffer.swift
    │   │   ├── MetalFrameAllocator.swift
    │   │   ├── MetalHelper.swift
    │   │   ├── MetalPipelineLibrary.swift
    │   │   ├── MetalProgram.swift
    │   │   ├── MetalRenderContext.swift
    │   │   ├── MetalTrailOverlayView.swift
    │   │   └── TrailResampler.swift
    │   ├── Effects/
    │   │   ├── GenericMetalEffect.swift
    │   │   ├── WaveMetalEffect.swift
    │   │   ├── MoneyMetalEffect.swift
    │   │   ├── BladeMetalEffect.swift
    │   │   ├── IceShatterMetalEffect.swift
    │   │   ├── CrimsonLotusMetalEffect.swift
    │   │   ├── DeathRayMetalEffect.swift
    │   │   ├── EmeraldMetalEffect.swift
    │   │   ├── InkWashMetalEffect.swift
    │   │   └── SprayPaintMetalEffect.swift
    │   └── Shaders/
    │       └── BeyTailEffects.metal
    └── pic/icon/
        └── PicTrailMetalRenderCore.swift
```

`MainViewModel.swift` 與 `ContentView.swift` 不需要修改。`TrailOverlayView.swift` 會將既有型別名稱映射到 `MetalTrailOverlayView`。

## 安裝

先提交或備份目前工作，再執行：

```bash
cd /path/to/BeyTail_MetalEffects_Port
chmod +x install.sh validate.sh
./install.sh /Users/zhouchenghan/Desktop/iosAPP/beyblade
```

腳本會：

1. 將既有 `UI/MetalEffects` 備份到 `tmp/metal_effect_backup_<時間>`。
2. 將 `UI/GLEffects` 移出正式 source root，避免 deprecated OpenGL ES 程式繼續編譯。
3. 備份並替換 `Effects/TrailOverlayView.swift`。
4. 安裝完整 `UI/MetalEffects`。
5. 備份並替換 `UI/pic/icon/PicTrailMetalRenderCore.swift`，統一錄影與離線渲染路徑。

你的 Xcode 專案使用 filesystem-synchronized root group。檔案放入 `beyblade/` 後通常會自動納入 target；仍需在 Xcode 確認 `BeyTailEffects.metal` 可被 Metal compiler 找到。

## MainViewModel 相容性

下列兩種寫法都可使用：

```swift
let trailOverlayView = TrailOverlayView()
```

```swift
let trailOverlayView = TrailOverlayView(frame: .zero)
```

因此不需要再次修改 `MainViewModel.swift` 第 76 行。

## 驗證

```bash
./validate.sh /Users/zhouchenghan/Desktop/iosAPP/beyblade
```

腳本會檢查：

- 10 個 Metal effect 類別是否完整。
- 正式 `UI/MetalEffects` 是否仍含 OpenGL ES API。
- 所有新增／替換 Swift 檔是否能通過語法解析。
- Mac 上能否使用 Apple Metal compiler 編譯 `BeyTailEffects.metal`。
- 錄影／離線相容 adapter 是否已安裝。

接著執行：

```text
Product → Clean Build Folder
Command + B
```

建議先在實機依序驗證：

1. 閃電、火炎、星塵：基本 ribbon、色彩與衰減。
2. 滔天浪潮：fluid ribbon、水滴、氣泡與 ripple。
3. 金錢衝擊：硬幣、火花與衝擊環。
4. 爆刃亂舞：刀光、裂痕、glint 與 wave。
5. 其餘五款程序化特效。
6. 同一特效分別測試即時預覽、錄影輸出與離線影片輸出。

## 視覺一致性的限制

Metal 可以保留相同公式、幾何、混合模式與粒子物理，但 Android 與 iOS 的亂數序列、相機時間戳、物件偵測輸出頻率及畫面色彩空間不同，因此不能保證逐像素、逐幀完全相同。此版本的目標是讓演算法與視覺結構對齊 Kotlin 原始碼；實機比對後若仍有差異，應優先校正 drawable 尺寸、軌跡輸入密度與少數平台尺度常數，而不是重新設計特效。
