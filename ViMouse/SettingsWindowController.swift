import Cocoa

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTabViewDelegate {
    private let remoteAgent: RemoteAgentAPI
    private var remoteAgentTabVisible = false
    private var popupByAction: [KeyMappingAction: NSPopUpButton] = [:]
    private var actionsByTag: [Int: KeyMappingAction] = [:]
    private var sliderBySetting: [MovementSetting: NSSlider] = [:]
    private var fieldBySetting: [MovementSetting: NSTextField] = [:]
    private var settingsByTag: [Int: MovementSetting] = [:]
    private var selfConversionCheckbox: NSButton?
    private var remoteAgentCheckbox: NSButton?
    private var remoteAgentURLs: NSPopUpButton?
    private var remoteAgentURLField: NSTextField?
    private var remoteAgentStatus: NSTextField?
    private var remoteAgentCopyButton: NSButton?
    private var conversionBackendPopup: NSPopUpButton?
    private var conversionBackendDetail: NSTextField?
    private var apiEndpointField: NSTextField?
    private var requestTimeoutField: NSTextField?
    private var inputHistoryLimitField: NSTextField?
    private var learningCheckbox: NSButton?
    private var conversionTestInputField: NSTextField?
    private var conversionTestButton: NSButton?
    private var conversionTestStatusLabel: NSTextField?
    private var conversionTestResultsView: NSTextView?
    private let conversionTestClient = JapaneseConversionClient()
    private static let conversionServerSpecURL = URL(string: "https://genki.github.io/ViMouse/conversion-server/")!

    init(remoteAgent: RemoteAgentAPI = .shared) {
        self.remoteAgent = remoteAgent
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
        NotificationCenter.default.addObserver(self, selector: #selector(remoteAgentChanged(_:)), name: RemoteAgentAPI.changed, object: remoteAgent)
        reloadRemoteAgent()
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
        selfConversionCheckbox?.state = SelfConversionSettings.enabled ? .on : .off
        learningCheckbox?.state = SelfConversionSettings.learningEnabled ? .on : .off
        apiEndpointField?.stringValue = SelfConversionSettings.apiEndpoint
        requestTimeoutField?.doubleValue = SelfConversionSettings.requestTimeout
        inputHistoryLimitField?.integerValue = SelfConversionSettings.inputHistoryLimit
        reloadConversionBackend()
        reloadRemoteAgent()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.delegate = self
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

        let conversionItem = NSTabViewItem(identifier: "conversion")
        conversionItem.label = localized("settings.tab.conversion")
        conversionItem.view = buildConversionTab()
        tabView.addTabViewItem(conversionItem)

        let agentItem = NSTabViewItem(identifier: "remoteAgent")
        agentItem.label = localized("agent.tab")
        agentItem.view = buildRemoteAgentTab()
        tabView.addTabViewItem(agentItem)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(spacer)

        let closeButton = button(localized("settings.done.button"), action: #selector(closeSettingsWindow(_:)))
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
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let rows = FlippedStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rows)

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
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            rows.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -10),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        return container
    }

    private func buildRemoteAgentTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        stack.addArrangedSubview(sectionTitle(localized("agent.tab")))
        let enabled = NSButton()
        enabled.setButtonType(.switch)
        enabled.title = localized("agent.menu")
        enabled.target = self; enabled.action = #selector(toggleRemoteAgent(_:))
        remoteAgentCheckbox = enabled
        stack.addArrangedSubview(enabled)
        let status = label("")
        remoteAgentStatus = status
        stack.addArrangedSubview(status)
        let hint = label(localized("agent.help"))
        hint.lineBreakMode = .byWordWrapping
        hint.usesSingleLineMode = false
        hint.cell?.wraps = true
        hint.preferredMaxLayoutWidth = 530
        stack.addArrangedSubview(hint)
        let urls = NSPopUpButton()
        urls.target = self; urls.action = #selector(selectRemoteAgentURL(_:))
        remoteAgentURLs = urls
        stack.addArrangedSubview(urls)
        let field = NSTextField()
        field.isEditable = false; field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        remoteAgentURLField = field
        stack.addArrangedSubview(field)
        let buttons = NSStackView()
        buttons.orientation = .horizontal; buttons.spacing = 12
        let copy = button(localized("agent.copy"), action: #selector(copyRemoteAgentURL(_:)))
        remoteAgentCopyButton = copy
        buttons.addArrangedSubview(copy)
        buttons.addArrangedSubview(button(localized("agent.rotate"), action: #selector(rotateRemoteAgentToken(_:))))
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            urls.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    @objc private func toggleRemoteAgent(_ sender: NSButton) { remoteAgent.setEnabled(sender.state == .on) }
    @objc private func remoteAgentChanged(_ notification: Notification) { reloadRemoteAgent() }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        remoteAgentTabVisible = tabViewItem?.identifier as? String == "remoteAgent"
        if remoteAgentTabVisible { reloadRemoteAgent() }
    }
    private func reloadRemoteAgent() {
        let api = remoteAgent
        if remoteAgentTabVisible || api.enabled { api.prepareSettings() }
        remoteAgentCheckbox?.state = api.enabled ? .on : .off
        remoteAgentStatus?.stringValue = api.status.isEmpty ? localized("agent.disabled") : api.status
        let previous = remoteAgentURLs?.titleOfSelectedItem
        remoteAgentURLs?.removeAllItems()
        // Prefer a usable LAN URL over localhost for a remote agent.
        let addresses = api.displayAddresses.sorted { ($0.address >> 24 == 127 ? 1 : 0) < ($1.address >> 24 == 127 ? 1 : 0) }
        remoteAgentURLs?.addItems(withTitles: addresses.map { $0.text })
        if let previous { remoteAgentURLs?.selectItem(withTitle: previous) }
        selectRemoteAgentURL(self)
    }
    @objc private func selectRemoteAgentURL(_ sender: Any) {
        let address = remoteAgentURLs?.titleOfSelectedItem ?? ""
        let url = remoteAgent.urls.first { $0.hasPrefix("http://\(address):") } ?? ""
        remoteAgentURLField?.stringValue = url
        remoteAgentCopyButton?.isEnabled = !url.isEmpty
    }
    @objc private func copyRemoteAgentURL(_ sender: Any) {
        guard let value = remoteAgentURLField?.stringValue, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    @objc private func rotateRemoteAgentToken(_ sender: Any) { remoteAgent.rotateToken() }

    private func buildConversionTab() -> NSView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container
        let stack = contentStack()
        container.addSubview(stack)

        let title = sectionTitle(localized("settings.conversion.title"))
        stack.addArrangedSubview(title)

        let checkbox = NSButton()
        checkbox.setButtonType(.switch)
        checkbox.title = localized("settings.selfConversion.enabled")
        checkbox.target = self
        checkbox.action = #selector(selfConversionChanged(_:))
        checkbox.state = SelfConversionSettings.enabled ? .on : .off
        selfConversionCheckbox = checkbox
        stack.addArrangedSubview(checkbox)

        let detail = label(localized("settings.selfConversion.detail"))
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        stack.addArrangedSubview(detail)

        let backend = NSPopUpButton()
        backend.addItems(withTitles: [localized("settings.selfConversion.backend.local"), localized("settings.selfConversion.backend.server")])
        backend.selectItem(at: SelfConversionSettings.backend == .local ? 0 : 1)
        backend.target = self
        backend.action = #selector(conversionBackendChanged(_:))
        conversionBackendPopup = backend
        stack.addArrangedSubview(backend)
        let backendDetail = label(localized("settings.selfConversion.backend.detail"))
        conversionBackendDetail = backendDetail
        backendDetail.font = NSFont.systemFont(ofSize: 12)
        backendDetail.textColor = .secondaryLabelColor
        backendDetail.lineBreakMode = .byWordWrapping
        backendDetail.maximumNumberOfLines = 0
        stack.addArrangedSubview(backendDetail)

        let endpointRow = NSStackView()
        endpointRow.orientation = .horizontal
        endpointRow.alignment = .centerY
        endpointRow.spacing = 12
        endpointRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(endpointRow)

        let endpointLabel = label(localized("settings.selfConversion.apiEndpoint"))
        endpointLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        endpointRow.addArrangedSubview(endpointLabel)

        let endpointField = NSTextField()
        endpointField.placeholderString = localized("settings.selfConversion.apiEndpoint.placeholder")
        endpointField.stringValue = SelfConversionSettings.apiEndpoint
        endpointField.target = self
        endpointField.action = #selector(apiEndpointChanged(_:))
        endpointField.delegate = self
        endpointField.isEnabled = SelfConversionSettings.backend == .server
        apiEndpointField = endpointField
        endpointRow.addArrangedSubview(endpointField)

        let endpointDetail = label(localized("settings.selfConversion.apiEndpoint.detail"))
        endpointDetail.font = NSFont.systemFont(ofSize: 12)
        endpointDetail.textColor = .secondaryLabelColor
        endpointDetail.lineBreakMode = .byWordWrapping
        endpointDetail.maximumNumberOfLines = 0
        stack.addArrangedSubview(endpointDetail)

        let apiSpecButton = button(localized("settings.selfConversion.apiSpec.button"), action: #selector(openConversionServerSpec(_:)))
        stack.addArrangedSubview(apiSpecButton)

        let timeoutRow = NSStackView()
        timeoutRow.orientation = .horizontal
        timeoutRow.alignment = .centerY
        timeoutRow.spacing = 12
        timeoutRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(timeoutRow)

        let timeoutLabel = label(localized("settings.selfConversion.requestTimeout"))
        timeoutLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        timeoutRow.addArrangedSubview(timeoutLabel)

        let timeoutField = NSTextField()
        timeoutField.alignment = .right
        timeoutField.formatter = decimalFormatter()
        timeoutField.doubleValue = SelfConversionSettings.requestTimeout
        timeoutField.target = self
        timeoutField.action = #selector(requestTimeoutChanged(_:))
        timeoutField.delegate = self
        timeoutField.isEnabled = SelfConversionSettings.backend == .server
        requestTimeoutField = timeoutField
        timeoutRow.addArrangedSubview(timeoutField)

        let timeoutUnit = label(localized("settings.selfConversion.requestTimeout.unit"))
        timeoutUnit.font = NSFont.systemFont(ofSize: 13)
        timeoutRow.addArrangedSubview(timeoutUnit)

        let timeoutDetail = label(localized("settings.selfConversion.requestTimeout.detail"))
        timeoutDetail.font = NSFont.systemFont(ofSize: 12)
        timeoutDetail.textColor = .secondaryLabelColor
        timeoutDetail.lineBreakMode = .byWordWrapping
        timeoutDetail.maximumNumberOfLines = 0
        stack.addArrangedSubview(timeoutDetail)

        let historyField = NSTextField()
        let historyFormatter = NumberFormatter()
        historyFormatter.numberStyle = .decimal
        historyFormatter.allowsFloats = false
        historyFormatter.minimum = 0
        historyFormatter.maximum = 1000
        historyField.formatter = historyFormatter
        historyField.integerValue = SelfConversionSettings.inputHistoryLimit
        historyField.alignment = .right
        historyField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        historyField.target = self
        historyField.action = #selector(inputHistoryLimitChanged(_:))
        historyField.delegate = self
        inputHistoryLimitField = historyField
        let historyRow = NSStackView(views: [label(localized("settings.selfConversion.historyLimit")), historyField])
        historyRow.orientation = .horizontal
        historyRow.spacing = 12
        stack.addArrangedSubview(historyRow)
        let historyDetail = label(localized("settings.selfConversion.historyDetail"))
        historyDetail.font = NSFont.systemFont(ofSize: 12)
        historyDetail.textColor = .secondaryLabelColor
        historyDetail.lineBreakMode = .byWordWrapping
        historyDetail.maximumNumberOfLines = 0
        stack.addArrangedSubview(historyDetail)

        let learning = NSButton()
        learning.setButtonType(.switch)
        learning.title = localized("settings.selfConversion.learning")
        learning.target = self
        learning.action = #selector(learningChanged(_:))
        learning.state = SelfConversionSettings.learningEnabled ? .on : .off
        learningCheckbox = learning
        stack.addArrangedSubview(learning)
        let learningActions = NSStackView(views: [
            button(localized("settings.selfConversion.learning.undo"), action: #selector(undoLearning(_:))),
            button(localized("settings.selfConversion.learning.clear"), action: #selector(clearLearning(_:)))])
        learningActions.orientation = .horizontal
        stack.addArrangedSubview(learningActions)
        stack.addArrangedSubview(conversionTestView())

        let keys = label(localized("settings.selfConversion.keys"))
        keys.font = NSFont.userFixedPitchFont(ofSize: 12) ?? NSFont.systemFont(ofSize: 12)
        keys.textColor = .secondaryLabelColor
        keys.lineBreakMode = .byWordWrapping
        keys.maximumNumberOfLines = 0
        stack.addArrangedSubview(keys)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            detail.widthAnchor.constraint(equalToConstant: 552),
            endpointRow.widthAnchor.constraint(equalToConstant: 552),
            endpointLabel.widthAnchor.constraint(equalToConstant: 150),
            endpointField.widthAnchor.constraint(equalToConstant: 390),
            endpointDetail.widthAnchor.constraint(equalToConstant: 552),
            timeoutRow.widthAnchor.constraint(equalToConstant: 552),
            timeoutLabel.widthAnchor.constraint(equalToConstant: 150),
            timeoutField.widthAnchor.constraint(equalToConstant: 80),
            timeoutUnit.widthAnchor.constraint(equalToConstant: 60),
            timeoutDetail.widthAnchor.constraint(equalToConstant: 552),
            historyDetail.widthAnchor.constraint(equalToConstant: 552),
            keys.widthAnchor.constraint(equalToConstant: 552),
        ])

        return scrollView
    }

    private func conversionTestView() -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false

        let title = label(localized("settings.selfConversion.test.title"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        group.addArrangedSubview(title)

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        group.addArrangedSubview(inputRow)

        let input = NSTextField()
        input.placeholderString = localized("settings.selfConversion.test.placeholder")
        input.stringValue = "kyouhatennkigaiidesu"
        input.target = self
        input.action = #selector(runSelfConversionTest(_:))
        conversionTestInputField = input
        inputRow.addArrangedSubview(input)

        let runButton = button(localized("settings.selfConversion.test.button"), action: #selector(runSelfConversionTest(_:)))
        conversionTestButton = runButton
        inputRow.addArrangedSubview(runButton)

        let status = label(localized("settings.selfConversion.test.ready"))
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        conversionTestStatusLabel = status
        group.addArrangedSubview(status)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(scrollView)

        let results = NSTextView()
        results.isEditable = false
        results.isSelectable = true
        results.drawsBackground = false
        results.font = NSFont.userFixedPitchFont(ofSize: 12) ?? NSFont.systemFont(ofSize: 12)
        results.string = localized("settings.selfConversion.test.empty")
        conversionTestResultsView = results
        scrollView.documentView = results

        NSLayoutConstraint.activate([
            group.widthAnchor.constraint(equalToConstant: 552),
            inputRow.widthAnchor.constraint(equalToConstant: 552),
            input.widthAnchor.constraint(equalToConstant: 420),
            runButton.widthAnchor.constraint(equalToConstant: 124),
            status.widthAnchor.constraint(equalToConstant: 552),
            scrollView.widthAnchor.constraint(equalToConstant: 552),
            scrollView.heightAnchor.constraint(equalToConstant: 120),
        ])

        return group
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
            row.widthAnchor.constraint(equalToConstant: 528),
            labelStack.widthAnchor.constraint(equalToConstant: 366),
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

    @objc private func selfConversionChanged(_ sender: NSButton) {
        saveSelfConversionFields()
        if sender.state == .on && !SelfConversionSettings.hasConversionBackend {
            sender.state = .off
            SelfConversionSettings.enabled = false
            return
        }
        SelfConversionSettings.enabled = sender.state == .on
    }

    @objc private func learningChanged(_ sender: NSButton) {
        SelfConversionSettings.learningEnabled = sender.state == .on
    }

    @objc private func clearLearning(_ sender: NSButton) {
        SelfConversionPersonalizer.shared.clear()
    }

    @objc private func undoLearning(_ sender: NSButton) {
        SelfConversionPersonalizer.shared.undoLastLearning()
    }

    @objc private func apiEndpointChanged(_ sender: NSTextField) {
        saveSelfConversionFields()
        reloadControls()
    }

    @objc private func requestTimeoutChanged(_ sender: NSTextField) {
        saveSelfConversionFields()
        reloadControls()
    }

    @objc private func openConversionServerSpec(_ sender: Any) {
        NSWorkspace.shared.open(Self.conversionServerSpecURL)
    }

    @objc private func runSelfConversionTest(_ sender: Any) {
        saveSelfConversionFields()
        guard SelfConversionSettings.hasConversionBackend else {
            conversionTestStatusLabel?.stringValue = localized("settings.selfConversion.test.endpointRequired")
            conversionTestResultsView?.string = ""
            return
        }

        let input = conversionTestInputField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !input.isEmpty else {
            conversionTestStatusLabel?.stringValue = localized("settings.selfConversion.test.inputRequired")
            conversionTestResultsView?.string = ""
            return
        }

        conversionTestButton?.isEnabled = false
        conversionTestStatusLabel?.stringValue = localized("settings.selfConversion.test.running")
        conversionTestResultsView?.string = ""

        conversionTestClient.convertDetailed(input) { [weak self] result in
            guard let self else { return }
            self.conversionTestButton?.isEnabled = true
            self.conversionTestStatusLabel?.stringValue = self.formatConversionTestStatus(result)
            self.conversionTestResultsView?.string = self.formatConversionTestResults(result)
        }
    }

    @objc private func closeSettingsWindow(_ sender: NSButton) {
        guard let window else { return }
        saveSelfConversionFields()
        window.orderOut(sender)
    }

    func windowWillClose(_ notification: Notification) {
        saveSelfConversionFields()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveSelfConversionFields()
    }

    @objc private func conversionBackendChanged(_ sender: NSPopUpButton) {
        SelfConversionSettings.backend = sender.indexOfSelectedItem == 0 ? .local : .server
        reloadConversionBackend()
    }

    private func reloadConversionBackend() {
        let server = SelfConversionSettings.backend == .server
        conversionBackendPopup?.selectItem(at: server ? 1 : 0)
        conversionBackendDetail?.stringValue = server
            ? localized("settings.selfConversion.backend.detail")
            : SelfConversionSettings.localUnavailableReason ?? "ローカル変換を使用できます。入力は端末内で変換し、オフラインでも利用できます。"
        apiEndpointField?.isEnabled = server
        requestTimeoutField?.isEnabled = server
    }

    @objc private func inputHistoryLimitChanged(_ sender: NSTextField) {
        saveSelfConversionFields()
        sender.integerValue = SelfConversionSettings.inputHistoryLimit
    }

    private func saveSelfConversionFields() {
        if let inputHistoryLimitField {
            SelfConversionSettings.inputHistoryLimit = inputHistoryLimitField.integerValue
        }
        if let apiEndpointField {
            SelfConversionSettings.apiEndpoint = apiEndpointField.stringValue
        }
        if let requestTimeoutField {
            SelfConversionSettings.setRequestTimeout(requestTimeoutField.doubleValue)
        }
    }

    private func formatConversionTestStatus(_ result: JapaneseConversionResult) -> String {
        let elapsed = String(format: "%.2f", result.elapsed)
        return "\(localized("settings.selfConversion.test.done")): \(result.source.rawValue), \(elapsed)s"
    }

    private func formatConversionTestResults(_ result: JapaneseConversionResult) -> String {
        let header = [
            "source: \(result.source.rawValue)",
            String(format: "elapsed: %.2fs", result.elapsed),
            result.detail.map { "detail: \($0)" },
        ].compactMap { $0 }.joined(separator: "\n")

        let candidates = result.candidates
        guard !candidates.isEmpty else {
            return header + "\n\n" + localized("settings.selfConversion.test.empty")
        }
        let rows = candidates.enumerated()
            .map { index, candidate in
                let score = String(format: "%.2f", candidate.score)
                return "\(index + 1). \(candidate.text)  \(score)"
            }
            .joined(separator: "\n")
        return header + "\n\n" + rows
    }

}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
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
