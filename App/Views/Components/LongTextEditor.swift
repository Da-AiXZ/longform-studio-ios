import SwiftUI
import UIKit

struct LongTextEditor: UIViewRepresentable {
    static let undoNotification = Notification.Name("LongTextEditor.undo")
    static let redoNotification = Notification.Name("LongTextEditor.redo")

    @Binding var text: String
    @Binding var selectedRange: NSRange
    var isEditable = true
    var focusOnAppear = false
    var onCommit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 40, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.smartQuotesType = .yes
        view.smartDashesType = .no
        view.autocorrectionType = .yes
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "chapter-editor"
        view.text = text
        context.coordinator.connect(to: view)
        if focusOnAppear {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text, !context.coordinator.isApplyingUserEdit {
            let currentSelection = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = NSRange(location: min(currentSelection.location, uiView.text.utf16.count), length: 0)
        }
        uiView.isEditable = isEditable
        if uiView.selectedRange != selectedRange, !context.coordinator.isSelecting {
            let maxLocation = uiView.text.utf16.count
            let safeLocation = min(selectedRange.location, maxLocation)
            let safeLength = min(selectedRange.length, maxLocation - safeLocation)
            uiView.selectedRange = NSRange(location: safeLocation, length: safeLength)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LongTextEditor
        var isApplyingUserEdit = false
        var isSelecting = false
        weak var textView: UITextView?
        private var observers: [NSObjectProtocol] = []
        private var commitWorkItem: DispatchWorkItem?

        init(parent: LongTextEditor) { self.parent = parent }

        deinit {
            commitWorkItem?.cancel()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func connect(to textView: UITextView) {
            self.textView = textView
            guard observers.isEmpty else { return }
            observers.append(NotificationCenter.default.addObserver(forName: LongTextEditor.undoNotification, object: nil, queue: .main) { [weak self] _ in
                self?.textView?.undoManager?.undo()
            })
            observers.append(NotificationCenter.default.addObserver(forName: LongTextEditor.redoNotification, object: nil, queue: .main) { [weak self] _ in
                self?.textView?.undoManager?.redo()
            })
        }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            isApplyingUserEdit = true
            parent.text = textView.text
            scheduleCommit()
            isApplyingUserEdit = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            isSelecting = true
            parent.selectedRange = textView.selectedRange
            isSelecting = false
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            commitWorkItem?.cancel()
            parent.onCommit?()
        }

        private func scheduleCommit() {
            commitWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.parent.onCommit?() }
            commitWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
        }
    }
}

extension String {
    func substring(in range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
