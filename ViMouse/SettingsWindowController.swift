import Cocoa

final class SettingsWindowController: NSWindowController {
    private var popupByAction: [KeyMappingAction: NSPopUpButton] = [:]
    private var actionsByTag: [Int: KeyMappingAction] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("settings.window.title")
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func reloadControls() {
        for (action, popup) in popupByAction {
            selectKey(KeyMapping.keyCode(for: action), in: popup)
        }
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let title = label(localized("settings.keyMapping.title"))
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)

        let rows = FlippedStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rows

        for action in KeyMappingAction.allCases {
            rows.addArrangedSubview(row(for: action))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        let resetButton = button(localized("settings.resetDefaults.button"), action: #selector(resetDefaults(_:)))
        buttons.addArrangedSubview(resetButton)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(spacer)

        let closeButton = button(localized("settings.done.button"), action: #selector(closeModal(_:)))
        closeButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 500),
            rows.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    private func row(for action: KeyMappingAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        row.addArrangedSubview(labelStack)

        let title = label(action.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelStack.addArrangedSubview(title)

        let detail = label(action.detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        labelStack.addArrangedSubview(detail)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(keyChanged(_:))
        popup.tag = KeyMappingAction.allCases.firstIndex(of: action) ?? 0
        actionsByTag[popup.tag] = action
        for choice in KeyMapping.choices {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = choice.keyCode
        }
        selectKey(KeyMapping.keyCode(for: action), in: popup)
        popupByAction[action] = popup
        row.addArrangedSubview(popup)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 520),
            labelStack.widthAnchor.constraint(equalToConstant: 360),
            popup.widthAnchor.constraint(equalToConstant: 120),
        ])

        return row
    }

    private func selectKey(_ keyCode: Int, in popup: NSPopUpButton) {
        let item = popup.itemArray.first { ($0.representedObject as? Int) == keyCode }
        popup.select(item)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField()
        field.stringValue = text
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        return button
    }

    @objc private func keyChanged(_ sender: NSPopUpButton) {
        guard
            let action = actionsByTag[sender.tag],
            let keyCode = sender.selectedItem?.representedObject as? Int
        else { return }

        KeyMapping.setKeyCode(keyCode, for: action)
    }

    @objc private func resetDefaults(_ sender: NSButton) {
        KeyMapping.resetDefaults()
        reloadControls()
    }

    @objc private func closeModal(_ sender: NSButton) {
        guard let window else { return }
        NSApp.stopModal()
        window.orderOut(sender)
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
