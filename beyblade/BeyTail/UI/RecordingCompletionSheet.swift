import SwiftUI

struct RecordingCompletionSheet: View {

    @ObservedObject var vm: MainViewModel

    let videoURL: URL

    var body: some View {
        VStack(spacing: 20) {
            header

            HStack(spacing: 12) {
                ShareLink(item: videoURL) {
                    actionCard(
                        icon: "square.and.arrow.up",
                        title: "分享",
                        subtitle: "分享影片"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    vm.saveCompletedRecording()
                } label: {
                    actionCard(
                        icon: downloadIcon,
                        title: downloadTitle,
                        subtitle: "儲存到照片"
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    vm.recordingSaveState == .saving ||
                    vm.recordingSaveState == .saved
                )

                Button {
                    vm.rerecordCompletedVideo()
                } label: {
                    actionCard(
                        icon: "arrow.counterclockwise",
                        title: "重新錄製",
                        subtitle: "捨棄目前影片",
                        destructive: true
                    )
                }
                .buttonStyle(.plain)
            }

            recordingStatusView
                .frame(minHeight: 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(.green)

            Text("錄影完成")
                .font(.system(size: 20, weight: .bold))

            Text("選擇要如何處理這段影片")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    private var downloadIcon: String {
        switch vm.recordingSaveState {
        case .saving:
            return "arrow.down.circle"

        case .saved:
            return "checkmark.circle.fill"

        case .idle, .failed:
            return "arrow.down.to.line"
        }
    }

    private var downloadTitle: String {
        switch vm.recordingSaveState {
        case .saving:
            return "下載中"

        case .saved:
            return "已下載"

        case .idle, .failed:
            return "下載"
        }
    }

    @ViewBuilder
    private var recordingStatusView: some View {
        switch vm.recordingSaveState {
        case .idle:
            Text("向下滑動可關閉")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("正在儲存到照片...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

        case .saved:
            Label(
                "影片已儲存到照片",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.green)

        case .failed(let message):
            Label(
                message,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.red)
        }
    }

    private func actionCard(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(
                    destructive
                        ? .red
                        : Color(hex: 0x00AEEF)
                )

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(
                    destructive ? .red : .primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 105)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(
            RoundedRectangle(cornerRadius: 16)
        )
    }
}
