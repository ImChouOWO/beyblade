import SwiftUI
import UniformTypeIdentifiers

struct QuickEffectMenuRow: View {
    @ObservedObject var quickMenuStore: EffectQuickMenuStore

    let ownedEffects: [EffectType]

    @Binding var selectedEffect: EffectType

    @State private var pickerTarget: SlotPickerTarget?
    @State private var draggedEffect: EffectType?

    private let slotSize: CGFloat = 60
    private let emojiSize: CGFloat = 24
    private let dragScale: CGFloat = 0.78

    /// 排序、新增與移除動畫：100 ms。
    private let reorderAnimationDuration: Double = 0.10

    var body: some View {
        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {
            HStack(spacing: 12) {
                ForEach(displayedSlots) { item in
                    slotContainer(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
            .animation(
                .easeInOut(
                    duration: reorderAnimationDuration
                ),
                value: quickMenuStore.effects
            )
        }
        .sheet(item: $pickerTarget) { target in
            QuickEffectPickerSheet(
                ownedEffects: availableEffects,
                onPick: { effect in
                    withAnimation(
                        .easeInOut(
                            duration: reorderAnimationDuration
                        )
                    ) {
                        if quickMenuStore.add(
                            effect,
                            at: target.index
                        ) {
                            selectedEffect = effect
                        }
                    }

                    pickerTarget = nil
                }
            )
        }
    }

    // MARK: - Data

    /// 所有特效由第一格開始排列，
    /// 空槽只會出現在最後方。
    private var displayedSlots: [QuickEffectSlotItem] {
        var items = quickMenuStore.effects
            .enumerated()
            .map { index, effect in
                QuickEffectSlotItem.effect(
                    index: index,
                    effect: effect
                )
            }

        if items.count < EffectQuickMenuStore.maximumCount {
            for index in items.count
                ..< EffectQuickMenuStore.maximumCount {
                items.append(
                    .empty(index: index)
                )
            }
        }

        return items
    }

    private var availableEffects: [EffectType] {
        ownedEffects.filter { effect in
            !quickMenuStore.contains(effect)
        }
    }

    // MARK: - Slot

    @ViewBuilder
    private func slotContainer(
        _ item: QuickEffectSlotItem
    ) -> some View {
        switch item {
        case let .effect(index, effect):
            effectSlot(
                effect: effect,
                index: index
            )

        case let .empty(index):
            emptySlot(index: index)
        }
    }

    private func effectSlot(
        effect: EffectType,
        index: Int
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            effectButton(
                effect: effect,
                index: index
            )
            /*
             使用 ButtonStyle 顯示按壓縮放。

             不再加入 LongPressGesture 或 DragGesture，
             避免攔截系統 onDrag。
             */
            .buttonStyle(
                QuickEffectPressStyle(
                    pressedScale: dragScale,
                    pressedOpacity: 0.68,
                    animationDuration:
                        reorderAnimationDuration
                )
            )
            .contentShape(
                .dragPreview,
                Circle()
            )
            .onDrag {
                draggedEffect = effect

                return NSItemProvider(
                    object: effect.rawValue as NSString
                )
            } preview: {
                dragPreview(
                    effect: effect,
                    index: index
                )
            }
            .onDrop(
                of: [UTType.text],
                delegate: QuickEffectDropDelegate(
                    targetIndex: index,
                    draggedEffect: $draggedEffect,
                    quickMenuStore: quickMenuStore,
                    animationDuration:
                        reorderAnimationDuration
                )
            )

            removeButton(
                effect: effect,
                index: index
            )
        }
        .frame(
            width: slotSize + 6,
            height: slotSize + 6
        )
    }

    private func emptySlot(
        index: Int
    ) -> some View {
        effectButton(
            effect: nil,
            index: index
        )
        .buttonStyle(
            QuickEffectPressStyle(
                pressedScale: 0.90,
                pressedOpacity: 0.75,
                animationDuration:
                    reorderAnimationDuration
            )
        )
        .frame(
            width: slotSize + 6,
            height: slotSize + 6
        )
        .onDrop(
            of: [UTType.text],
            delegate: QuickEffectDropDelegate(
                targetIndex: index,
                draggedEffect: $draggedEffect,
                quickMenuStore: quickMenuStore,
                animationDuration:
                    reorderAnimationDuration
            )
        )
    }

    // MARK: - Effect Button

    private func effectButton(
        effect: EffectType?,
        index: Int
    ) -> some View {
        Button {
            if let effect {
                selectedEffect = effect
            } else {
                pickerTarget = SlotPickerTarget(
                    index: index
                )
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        Color.white.opacity(0.06)
                    )

                Circle()
                    .stroke(
                        slotBorderColor(
                            effect: effect
                        ),
                        lineWidth: 1.2
                    )

                if let effect {
                    /*
                     快捷列只顯示 Emoji，
                     不顯示 effect.displayName。
                     */
                    Text(effect.emoji)
                        .font(
                            .system(size: emojiSize)
                        )
                        .lineLimit(1)
                } else {
                    Image(systemName: "plus")
                        .font(
                            .system(
                                size: 19,
                                weight: .bold
                            )
                        )
                        .foregroundColor(
                            Color(hex: 0x00F5FF)
                        )
                }
            }
            .frame(
                width: slotSize,
                height: slotSize
            )
            .contentShape(Circle())
            .clipShape(Circle())
        }
        .frame(
            width: slotSize,
            height: slotSize
        )
        .contentShape(Circle())
    }

    // MARK: - Remove Button

    private func removeButton(
        effect: EffectType,
        index: Int
    ) -> some View {
        Button {
            var removedEffect: EffectType?

            withAnimation(
                .easeInOut(
                    duration: reorderAnimationDuration
                )
            ) {
                removedEffect =
                    quickMenuStore.remove(
                        at: index
                    )

                if removedEffect == selectedEffect {
                    selectedEffect =
                        quickMenuStore.effects.first
                        ?? EffectType
                            .defaultMenuEffects.first
                        ?? .lightning
                }
            }

            /*
             保險清除拖曳資料。

             此狀態不再控制透明度或縮放，
             因此即使取消拖曳也不會卡住畫面。
             */
            draggedEffect = nil
        } label: {
            ZStack {
                Circle()
                    .fill(
                        Color.red.opacity(0.95)
                    )

                Image(systemName: "minus")
                    .font(
                        .system(
                            size: 10,
                            weight: .bold
                        )
                    )
                    .foregroundColor(.white)
            }
            .frame(
                width: 20,
                height: 20
            )
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 2, y: -2)
        .accessibilityLabel(
            "從快捷選單移除\(effect.displayName)"
        )
    }

    // MARK: - Drag Preview

    private func dragPreview(
        effect: EffectType,
        index: Int
    ) -> some View {
        let previewSize =
            slotSize * dragScale

        let previewEmojiSize =
            emojiSize * dragScale

        let previewLineWidth =
            1.2 * dragScale

        return ZStack {
            /*
             透明安全範圍仍是 60 × 60，
             實際圓形則縮小到 78%。

             這樣系統拖曳預覽的矩形範圍
             不會裁切到圓形邊緣。
             */
            Color.clear

            ZStack {
                Circle()
                    .fill(
                        Color.black.opacity(0.94)
                    )

                Circle()
                    .stroke(
                        slotBorderColor(
                            effect: effect
                        ),
                        lineWidth:
                            previewLineWidth
                    )

                Text(effect.emoji)
                    .font(
                        .system(
                            size: previewEmojiSize
                        )
                    )
                    .lineLimit(1)
            }
            .frame(
                width: previewSize,
                height: previewSize
            )
            .compositingGroup()
            .clipShape(Circle())
        }
        .frame(
            width: slotSize,
            height: slotSize
        )
        .contentShape(
            .dragPreview,
            Circle()
        )
    }

    // MARK: - Border

    private func slotBorderColor(
        effect: EffectType?
    ) -> Color {
        if effect == selectedEffect {
            return Color(hex: 0x00F5FF)
                .opacity(0.55)
        }

        return Color.white.opacity(0.12)
    }
}

// MARK: - Press Style

/// 使用 ButtonStyle 提供按壓動畫。
///
/// ButtonStyle 不會像自訂 DragGesture 一樣
/// 攔截系統的 onDrag。
///
/// 手指放開、取消操作或開始系統拖曳後，
/// configuration.isPressed 會由 SwiftUI 自動恢復。
private struct QuickEffectPressStyle: ButtonStyle {
    let pressedScale: CGFloat
    let pressedOpacity: Double
    let animationDuration: Double

    func makeBody(
        configuration: Configuration
    ) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? pressedScale
                    : 1
            )
            .opacity(
                configuration.isPressed
                    ? pressedOpacity
                    : 1
            )
            .animation(
                .easeInOut(
                    duration: animationDuration
                ),
                value: configuration.isPressed
            )
    }
}

// MARK: - Slot Item

private enum QuickEffectSlotItem: Identifiable {
    case effect(
        index: Int,
        effect: EffectType
    )

    case empty(index: Int)

    var id: String {
        switch self {
        case let .effect(_, effect):
            /*
             使用特效本身作為識別值。

             排序時 SwiftUI 會將同一個 View
             從舊位置移動至新位置，而不是直接換內容。
             */
            return "effect-\(effect.rawValue)"

        case let .empty(index):
            return "empty-\(index)"
        }
    }
}

// MARK: - Picker Target

private struct SlotPickerTarget: Identifiable {
    let index: Int

    var id: Int {
        index
    }
}

// MARK: - Effect Picker

private struct QuickEffectPickerSheet: View {
    let ownedEffects: [EffectType]
    let onPick: (EffectType) -> Void

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if ownedEffects.isEmpty {
                    ContentUnavailableView(
                        "沒有可加入的特效",
                        systemImage: "sparkles",
                        description: Text(
                            "已擁有的特效都已加入快捷選單"
                        )
                    )
                } else {
                    List(
                        ownedEffects,
                        id: \.self
                    ) { effect in
                        Button {
                            onPick(effect)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(effect.emoji)
                                    .font(
                                        .system(size: 26)
                                    )

                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {
                                    Text(
                                        effect.displayName
                                    )
                                    .foregroundColor(
                                        .white
                                    )

                                    Text(
                                        effect.description
                                    )
                                    .font(
                                        .system(size: 12)
                                    )
                                    .foregroundColor(
                                        .secondary
                                    )
                                }

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            Color.black
                        )
                    }
                    .scrollContentBackground(
                        .hidden
                    )
                }
            }
            .background(
                Color.black.ignoresSafeArea()
            )
            .navigationTitle(
                "加入快捷選單"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button("關閉") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Drop Delegate

private struct QuickEffectDropDelegate:
    DropDelegate {
    let targetIndex: Int

    @Binding var draggedEffect: EffectType?

    let quickMenuStore:
        EffectQuickMenuStore

    let animationDuration: Double

    func validateDrop(
        info: DropInfo
    ) -> Bool {
        draggedEffect != nil
    }

    func performDrop(
        info: DropInfo
    ) -> Bool {
        guard let draggedEffect,
              let sourceIndex =
                quickMenuStore.effects
                    .firstIndex(
                        of: draggedEffect
                    ) else {
            self.draggedEffect = nil
            return false
        }

        withAnimation(
            .easeInOut(
                duration: animationDuration
            )
        ) {
            _ = quickMenuStore.move(
                from: sourceIndex,
                to: targetIndex
            )
        }

        self.draggedEffect = nil
        return true
    }

    func dropUpdated(
        info: DropInfo
    ) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
