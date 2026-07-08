import SwiftUI
import UniformTypeIdentifiers

struct QuickEffectMenuRow: View {

    @ObservedObject var quickMenuStore: EffectQuickMenuStore
    @ObservedObject var purchaseStore: EffectPurchaseStore

    let ownedEffects: [EffectType]
    let rotationAngle: Angle
    let onSelectEffect: (EffectType) -> Void

    @State private var editingSlotIndex: Int?
    @State private var draggedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷選單")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(quickMenuStore.slots.indices, id: \.self) { index in
                        slotView(at: index)
                            .onDrag {
                                draggedIndex = index
                                return NSItemProvider(object: "\(index)" as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: QuickEffectDropDelegate(
                                    targetIndex: index,
                                    draggedIndex: $draggedIndex,
                                    quickMenuStore: quickMenuStore
                                )
                            )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .rotationEffect(rotationAngle)
    }

    @ViewBuilder
    private func slotView(at index: Int) -> some View {
        let effect = quickMenuStore.slots[index]

        ZStack(alignment: .topTrailing) {
            Button {
                if let effect {
                    onSelectEffect(effect)
                } else {
                    editingSlotIndex = index
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .frame(width: 78, height: 78)

                    if let effect {
                        VStack(spacing: 4) {
                            Text(effect.emoji)
                                .font(.system(size: 28))

                            Text(effect.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(width: 64)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                }
            }
            .buttonStyle(.plain)

            if effect != nil {
                Button {
                    quickMenuStore.remove(at: index)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.95))
                            .frame(width: 24, height: 24)

                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .offset(x: 2, y: -2)
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(
            get: {
                editingSlotIndex.map { SlotPickerTarget(index: $0) }
            },
            set: { newValue in
                editingSlotIndex = newValue?.index
            }
        )) { target in
            QuickEffectPickerSheet(
                ownedEffects: ownedEffects.filter { !quickMenuStore.contains($0) },
                onPick: { effect in
                    quickMenuStore.add(effect, at: target.index)
                    editingSlotIndex = nil
                }
            )
        }
    }
}

private struct SlotPickerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct QuickEffectPickerSheet: View {

    let ownedEffects: [EffectType]
    let onPick: (EffectType) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(ownedEffects, id: \.self) { effect in
                Button {
                    onPick(effect)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(effect.emoji)
                            .font(.system(size: 26))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(effect.displayName)
                                .foregroundColor(.white)

                            Text(effect.shortDescription)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.black)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("加入快捷選單")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct QuickEffectDropDelegate: DropDelegate {

    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let quickMenuStore: EffectQuickMenuStore

    func performDrop(info: DropInfo) -> Bool {
        guard let source = draggedIndex else { return false }
        quickMenuStore.move(from: source, to: targetIndex)
        draggedIndex = nil
        return true
    }
}
