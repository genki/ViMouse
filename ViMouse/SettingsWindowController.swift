import Cocoa

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var popupByAction: [KeyMappingAction: NSPopUpButton] = [:]
    private var actionsByTag: [Int: KeyMappingAction] = [:]
    private var sliderBySetting: [MovementSetting: NSSlider] = [:]
    private var fieldBySetting: [MovementSetting: NSTextField] = [:]
    private var settingsByTag: [Int: MovementSetting] = [:]
    var modalWillClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("settings.window.title")
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func reloadControls() {
        for (action, popup) in popupByAction {
            selectKey(KeyMapping.keyCode(for: action), in: popup)
        }
        for setting in MovementSetting.allCases {
            updateMovementControls(for: setting)
        }
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)

        let keyMappingItem = NSTabViewItem(identifier: "keyMapping")
        keyMappingItem.label = localized("settings.tab.keyMapping")
        keyMappingItem.view = buildKeyMappingTab()
        tabView.addTabViewItem(keyMappingItem)

        let movementItem = NSTabViewItem(identifier: "movement")
        movementItem.label = localized("settings.tab.movement")
        movementItem.view = buildMovementTab()
        tabView.addTabViewItem(movementItem)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(spacer)

        let closeButton = button(localized("settings.done.button"), action: #selector(closeModal(_:)))
        closeButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            tabView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
    }

    private func buildKeyMappingTab() -> NSView {
        let container = NSView()

        let stack = contentStack()
        container.addSubview(stack)

        let title = sectionTitle(localized("settings.keyMapping.title"))
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
            rows.addArrangedSubview(keyMappingRow(for: action))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        let resetButton = button(localized("settings.resetDefaults.button"), action: #selector(resetKeyMappingDefaults(_:)))
        buttons.addArrangedSubview(resetButton)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(spacer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 500),
            rows.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        return container
    }

    private func buildMovementTab() -> NSView {
        let container = NSView()
        let stack = contentStack()
        container.addSubview(stack)

        let title = sectionTitle(localized("settings.movement.title"))
        stack.addArrangedSubview(title)

        for setting in MovementSetting.allCases {
            stack.addArrangedSubview(movementRow(for: setting))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        let resetButton = button(localized("settings.resetMovementDefaults.button"), action: #selector(resetMovementDefaults(_:)))
        buttons.addArrangedSubview(resetButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])

        return container
    }

    private func keyMappingRow(for action: KeyMappingAction) -> NSView {
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
            row.widthAnchor.constraint(equalToConstant: 552),
            labelStack.widthAnchor.constraint(equalToConstant: 390),
            popup.widthAnchor.constraint(equalToConstant: 120),
        ])

        return row
    }

    private func movementRow(for setting: MovementSetting) -> NSView {
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

        let title = label(setting.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelStack.addArrangedSubview(title)

        let detail = label(setting.detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        labelStack.addArrangedSubview(detail)

        let slider = NSSlider()
        slider.minValue = setting.minimumValue
        slider.maxValue = setting.maximumValue
        slider.doubleValue = MovementSettings.value(for: setting)
        slider.target = self
        slider.action = #selector(movementSliderChanged(_:))
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.tag = MovementSetting.allCases.firstIndex(of: setting) ?? 0
        settingsByTag[slider.tag] = setting
        sliderBySetting[setting] = slider
        row.addArrangedSubview(slider)

        let field = NSTextField()
        field.alignment = .right
        field.formatter = decimalFormatter()
        field.target = self
        field.action = #selector(movementFieldChanged(_:))
        field.tag = slider.tag
        fieldBySetting[setting] = field
        row.addArrangedSubview(field)
        updateMovementControls(for: setting)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 552),
            labelStack.widthAnchor.constraint(equalToConstant: 270),
            slider.widthAnchor.constraint(equalToConstant: 190),
            field.widthAnchor.constraint(equalToConstant: 64),
        ])

        return row
    }

    private func updateMovementControls(for setting: MovementSetting) {
        let value = MovementSettings.value(for: setting)
        sliderBySetting[setting]?.doubleValue = value
        fieldBySetting[setting]?.doubleValue = value
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

    private func sectionTitle(_ text: String) -> NSTextField {
        let title = label(text)
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        return title
    }

    private func contentStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func decimalFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return formatter
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

    @objc private func movementSliderChanged(_ sender: NSSlider) {
        guard let setting = settingsByTag[sender.tag] else { return }
        MovementSettings.setValue(sender.doubleValue, for: setting)
        updateMovementControls(for: setting)
    }

    @objc private func movementFieldChanged(_ sender: NSTextField) {
        guard let setting = settingsByTag[sender.tag] else { return }
        MovementSettings.setValue(sender.doubleValue, for: setting)
        updateMovementControls(for: setting)
    }

    @objc private func resetKeyMappingDefaults(_ sender: NSButton) {
        KeyMapping.resetDefaults()
        reloadControls()
    }

    @objc private func resetMovementDefaults(_ sender: NSButton) {
        MovementSettings.resetDefaults()
        reloadControls()
    }

    @objc private func closeModal(_ sender: NSButton) {
        guard let window else { return }
        stopModal()
        window.orderOut(sender)
    }

    func windowWillClose(_ notification: Notification) {
        stopModal()
    }

    private func stopModal() {
        modalWillClose?()
        NSApp.stopModal()
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
