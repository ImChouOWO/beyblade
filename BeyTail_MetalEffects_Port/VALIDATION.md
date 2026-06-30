# Validation

## 已完成

- 10 個 Kotlin 特效皆有獨立 Metal Swift 類別。
- `GenericMetalEffect` 同時承接閃電、火炎與星塵。
- 21 種 shader kind 皆有 Swift program mapping 與 MSL 分支。
- `UI/MetalEffects` 不含 `OpenGLES`、`GLKit`、`GLKView`、`EAGLContext`、`glUseProgram` 或 `glDrawArrays` 呼叫。
- 所有套件 Swift 檔皆通過 `swiftc -frontend -parse`。
- 10 個 effect 檔已使用 Swift stub 執行跨檔型別檢查。
- `TrailOverlayView()` 與 `TrailOverlayView(frame: .zero)` 兩種初始化方式皆保留。
- 即時預覽使用 `MetalTrailOverlayView`。
- 錄影與離線渲染的 `PicTrailMetalRenderCore` 已改為呼叫同一批 `MetalEffect` 類別。
- `install.sh` 會把舊 `UI/GLEffects` 移出 filesystem-synchronized Xcode source root。

## 需要在使用者的 Mac／iPhone 完成

目前執行環境不是 macOS，無法在此呼叫 Apple Metal compiler、iOS SDK typecheck、Xcode build 或 iPhone GPU。套件中的 `validate.sh` 會在 Mac 上呼叫：

```bash
xcrun -sdk iphoneos metal
```

建置後仍需以使用者提供的 Android 參考影片進行實機畫面比對。Metal 與 Kotlin 端保留相同的演算法結構，但不同平台的亂數序列、影格 timestamp、物件偵測更新率及色彩空間可能造成非逐像素差異。
