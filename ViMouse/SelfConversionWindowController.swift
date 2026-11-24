import Cocoa

final class SelfConversionWindowController: NSWindowController {
    private let committedLabel = SelfConversionWindowController.makeLabel()
    private let rawLabel = SelfConversionWindowController.makeLabel()
    private let nextRawLabel = SelfConversionWindowController.makeLabel()
    private let stack = NSStackView()
    private let client: JapaneseConversionServing
    private var candidateLabels: [NSTextField] = []
    private var renderedCandidateValues: [NSAttributedString] = []
    private var renderedRawValue: NSAttributedString?
    private var candidateRenderScheduled = false
    private var layoutScheduled = false
    private var holdsCandidateDisplay = false
    private var stableContentWidth: CGFloat = 0
    private var stableContentHeight: CGFloat = 0
    private var usesRealtimeConversion: Bool { client.conversionDebounceDelay == 0 }
    private var rawWidthConstraint: NSLayoutConstraint?
    private var separatorWidthConstraint: NSLayoutConstraint?
    private var pendingConversion: DispatchWorkItem?
    private var isConversionRequestInFlight = false
    private var conversionGeneration = 0
    private var loadingWaveTimer: Timer?
    private var loadingWavePhase: CGFloat = 0
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var isBatchingConversionState = false
    private var isLoadingCandidates = false {
        didSet {
            if oldValue != isLoadingCandidates { updateLoadingState() }
        }
    }
    private var suffixMode = false
    private var suffixInput = ""
    // Full displayed candidate -> the text to actually commit.
    private var suffixPrefixes: [String: String] = [:]
    private var committedReading: String? = ""
    private var initialContext = ""
    private var committedText = "" {
        didSet {
            updateCommittedText()
            scheduleConversionAfterStateChange()
        }
    }
    private var inputBuffer = "" {
        didSet {
            updateRawText()
            scheduleConversionAfterStateChange()
        }
    }
    private var activeSessionInput = "" {
        didSet {
            updateRawText()
            resizeToFitContent()
        }
    }
    private var nextSessionBuffer = "" {
        didSet {
            updateNextRawText()
        }
    }
    private var candidates: [JapaneseConversionCandidate] = [] {
        didSet {
            punctuationCursor = nil
            explicitSelection = false
            selectedIndex = min(selectedIndex, max(candidates.count - 1, 0))
            updateCandidateViews()
        }
    }
    private var explicitSelection = false
    private var punctuationCursor: JapanesePunctuationCombinationCursor?
    private var recalledHistoryIndex: Int?
    private var selectedIndex = 0 {
        didSet {
            punctuationCursor = nil
            selectedIndex = min(max(selectedIndex, 0), max(candidates.count - 1, 0))
            updateCandidateSelection()
        }
    }

    var isActive: Bool {
        window?.isVisible == true
    }

    var hasNextSessionInput: Bool {
        !nextSessionBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(client: JapaneseConversionServing = JapaneseConversionClient()) {
        self.client = client
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.baseWindowWidth, height: 180),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true

        super.init(window: panel)
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        stopLoadingWave()
        stopMouseDownMonitors()
    }

    func begin(context: String = "") {
        recalledHistoryIndex = nil
        holdsCandidateDisplay = false
        stableContentWidth = 0
        stableContentHeight = 0
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        batchConversionStateChange {
            suffixMode = false
            suffixInput = ""
            suffixPrefixes = [:]
            initialContext = context
            committedReading = ""
            committedText = ""
            inputBuffer = ""
            activeSessionInput = ""
            nextSessionBuffer = ""
            candidates = []
            selectedIndex = 0
            isLoadingCandidates = false
        }
        flushCandidateDisplay()
        positionAtScreenCenter()
        resizeToFitContent(keepingTop: false)
        window?.orderFrontRegardless()
        startMouseDownMonitors()
    }

    func cancel() {
        if isActive {
            let reading = (committedReading ?? committedText)
                + (hasActiveConversionSession ? activeSessionInput : inputBuffer)
                + (suffixMode ? suffixInput : "") + nextSessionBuffer
            SelfConversionSettings.rememberInput(reading)
        }
        recalledHistoryIndex = nil
        holdsCandidateDisplay = false
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        stopMouseDownMonitors()
        window?.orderOut(nil)
        batchConversionStateChange {
            suffixMode = false
            suffixInput = ""
            suffixPrefixes = [:]
            initialContext = ""
            committedReading = ""
            committedText = ""
            inputBuffer = ""
            activeSessionInput = ""
            nextSessionBuffer = ""
            candidates = []
            selectedIndex = 0
            isLoadingCandidates = false
        }
    }

    @discardableResult
    func append(_ text: String) -> SelfConversionDecisionSnapshot? {
        guard !text.isEmpty else { return nil }
        recalledHistoryIndex = nil
        // A non-leading selection is an explicit choice. Preserve it before
        // typing changes the reading and resets the candidate selection.
        let partialCommit: SelfConversionDecisionSnapshot?
        if selectedIndex > 0, candidates.indices.contains(selectedIndex),
           !selectedText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            partialCommit = commitCurrentCandidateForContinuation()
        } else {
            partialCommit = nil
        }
        if suffixMode {
            guard (activeSessionInput + suffixInput + text).unicodeScalars.count <= Self.maximumConversionInputScalars else {
                NSSound.beep()
                return partialCommit
            }
            suffixInput += text
            reviseSuffix()
            return partialCommit
        }
        if hasActiveConversionSession {
            // Continue editing the current range, including the following
            // range promoted by a partial commit above.
            reviseBoundary(activeInput: activeSessionInput + text, nextInput: nextSessionBuffer)
        } else {
            inputBuffer += text
        }
        return partialCommit
    }

    func backspace() {
        recalledHistoryIndex = nil
        if suffixMode {
            if suffixInput.isEmpty {
                suffixMode = false
                suffixPrefixes = [:]
                reviseBoundary(activeInput: activeSessionInput, nextInput: nextSessionBuffer)
            } else {
                suffixInput.removeLast()
                reviseSuffix()
            }
            updateRawText()
            return
        }
        // DEL edits the current conversion range, not the queued next range,
        // including while its old conversion response is still in flight.
        if hasActiveConversionSession {
            var nextInput = activeSessionInput
            nextInput.removeLast()
            if nextInput.isEmpty {
                pendingConversion?.cancel()
                invalidateActiveConversionRequest()
                batchConversionStateChange {
                    activeSessionInput = ""
                    inputBuffer = nextSessionBuffer
                    nextSessionBuffer = ""
                    candidates = []
                    selectedIndex = 0
                    isLoadingCandidates = false
                }
                // Promote immediately, retaining API-limit overflow in the
                // next range through the existing initial split machinery.
                startCurrentInputConversion()
            } else {
                reviseBoundary(activeInput: nextInput, nextInput: nextSessionBuffer)
            }
            return
        }

        if !hasActiveConversionSession, !inputBuffer.isEmpty {
            inputBuffer.removeLast()
            return
        }

        guard !hasActiveConversionSession, candidates.isEmpty, !committedText.isEmpty else { return }
        committedReading = nil
        committedText.removeLast()
    }

    func moveLastInputCharacterToNextSession() {
        guard !suffixMode else { return }
        guard hasActiveConversionSession, activeSessionInput.count > 1 else { return }
        var nextActiveInput = activeSessionInput
        let moved = nextActiveInput.removeLast()
        reviseBoundary(activeInput: nextActiveInput, nextInput: String(moved) + nextSessionBuffer)
    }

    func moveFirstNextSessionCharacterToInput() {
        guard !suffixMode else { return }
        guard hasActiveConversionSession, !nextSessionBuffer.isEmpty else { return }
        var nextInput = nextSessionBuffer
        let moved = nextInput.removeFirst()
        reviseBoundary(activeInput: activeSessionInput + String(moved), nextInput: nextInput)
    }

    func splitInputAfterFirstCharacter() {
        recalledHistoryIndex = nil
        guard !suffixMode else { return }
        guard hasActiveConversionSession, activeSessionInput.count > 1,
              let first = activeSessionInput.first else { return }
        // Range boundaries belong to the raw input, never to a displayed
        // conversion result. Character boundaries preserve graphemes.
        let remainder = String(activeSessionInput.dropFirst())
        reviseBoundary(activeInput: String(first),
                       nextInput: remainder + nextSessionBuffer)
        // Splitting alone does not convert or normalize the raw first character.
        // Editing or explicitly converting resumes the normal conversion path.
        pendingConversion?.cancel()
        candidates = [JapaneseConversionCandidate(text: String(first), score: 1)]
    }

    func beginSuffixInput() {
        recalledHistoryIndex = nil
        guard !suffixMode else { return }
        if !hasActiveConversionSession { startCurrentInputConversion() }
        guard hasActiveConversionSession else { return }
        suffixMode = true
        suffixInput = ""
        reviseSuffix()
    }

    private func reviseSuffix() {
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        suffixPrefixes = [:]
        selectedIndex = 0
        setInterimCandidates(for: activeSessionInput, context: joinCommittedText(initialContext, committedText))
        isLoadingCandidates = false
        updateRawText()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.suffixMode, !self.explicitSelection else { return }
            self.startSuffixConversion()
        }
        pendingConversion = work
        enqueueConversion(work)
    }

    private func startSuffixConversion() {
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        let base = activeSessionInput
        let suffix = suffixInput
        guard suffixMode, !base.isEmpty else { return }
        if suffix.isEmpty {
            startConversionRequest(for: base)
            return
        }
        let generation = nextConversionGeneration()
        let context = joinCommittedText(initialContext, committedText)
        isConversionRequestInFlight = true
        isLoadingCandidates = true
        var fullCandidates: [JapaneseConversionCandidate]?
        var suffixCandidates: [JapaneseConversionCandidate]?
        let apply: () -> Void = { [weak self] in
            guard let self, self.conversionGeneration == generation, self.suffixMode,
                  self.activeSessionInput == base, self.suffixInput == suffix,
                  let full = fullCandidates, let endings = suffixCandidates else { return }
            let suffixReading = RomajiKanaConverter.hiragana(suffix)
            let suffixTexts = Array(Set(endings.filter { $0.reading == nil || RomajiKanaConverter.hiragana($0.reading!) == suffixReading }.map(\.text) + [suffix, suffixReading]))
                .filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            var prefixes: [String: String] = [:]
            let matched = full.filter { candidate in
                if let reading = candidate.reading, !RomajiKanaConverter.hiragana(reading).hasSuffix(suffixReading) { return false }
                guard let ending = suffixTexts.first(where: { candidate.text.hasSuffix($0) && candidate.text.count > $0.count }) else { return false }
                prefixes[candidate.text] = String(candidate.text.dropLast(ending.count))
                return true
            }
            self.holdsCandidateDisplay = false
            self.suffixPrefixes = prefixes
            // Unknown boundaries cannot safely be truncated; keep body-only fallback choices.
            self.candidates = matched.isEmpty ? SelfConversionCandidateBuilder.fallbackCandidates(for: base, context: context) : matched
            self.isConversionRequestInFlight = false
            self.isLoadingCandidates = false
        }
        client.convert(base + suffix, context: context) { result in
            DispatchQueue.main.async { fullCandidates = result; apply() }
        }
        client.convertSuffix(suffix, context: "") { result in
            DispatchQueue.main.async { suffixCandidates = result; apply() }
        }
    }

    private static func suffixDisplay(prefix: String, suffix: String, selected: Bool = false) -> NSAttributedString {
        func visible(_ text: String) -> String {
            text.replacingOccurrences(of: " ", with: "␣")
                .replacingOccurrences(of: "　", with: "␣")
                .replacingOccurrences(of: "\t", with: "⇥")
                .replacingOccurrences(of: "\n", with: "↵")
        }
        let prefixColor = selected ? Self.selectionTextColor() : NSColor.labelColor
        let gapColor = selected ? prefixColor.withAlphaComponent(0.65) : NSColor.tertiaryLabelColor
        let suffixColor = selected ? prefixColor : NSColor.systemBlue
        let result = NSMutableAttributedString(string: visible(prefix), attributes: [.foregroundColor: prefixColor])
        result.append(NSAttributedString(string: "\u{2003}│\u{2003}", attributes: [.foregroundColor: gapColor]))
        result.append(NSAttributedString(string: visible(suffix), attributes: [.foregroundColor: suffixColor]))
        return result
    }

    func selectNext() {
        recalledHistoryIndex = nil
        flushCandidateDisplay()
        guard !candidates.isEmpty else { return }
        beginCandidateSelection()
        selectedIndex = (selectedIndex + 1) % candidates.count
    }

    func selectPrevious() {
        if recallPreviousInputIfNeeded() { return }
        flushCandidateDisplay()
        guard !candidates.isEmpty else { return }
        beginCandidateSelection()
        selectedIndex = (selectedIndex + candidates.count - 1) % candidates.count
    }

    func selectPunctuationCombination(forward: Bool) {
        flushCandidateDisplay()
        guard candidates.indices.contains(selectedIndex) else { return }
        let candidate = candidates[selectedIndex]
        let body = suffixPrefixes[candidate.text] ?? candidate.text
        guard var cursor = punctuationCursor ?? JapanesePunctuationCombinationCursor(text: body) else {
            NSSound.beep()
            return
        }
        beginCandidateSelection()
        recalledHistoryIndex = nil
        let nextBody = cursor.move(forward: forward)
        let suffix = suffixPrefixes[candidate.text].map { _ in String(candidate.text.dropFirst(body.count)) } ?? ""
        let nextText = nextBody + suffix
        if suffixPrefixes[candidate.text] != nil { suffixPrefixes[nextText] = nextBody }
        candidates[selectedIndex] = JapaneseConversionCandidate(
            text: nextText, score: candidate.score, isNative: false,
            reading: candidate.reading, isLearned: candidate.isLearned)
        // Candidate mutation clears selection state; retain ownership and the same product.
        punctuationCursor = cursor
        explicitSelection = true
    }

    private func recallPreviousInputIfNeeded() -> Bool {
        let empty = committedText.isEmpty && inputBuffer.isEmpty && activeSessionInput.isEmpty
            && nextSessionBuffer.isEmpty && suffixInput.isEmpty
        guard empty || recalledHistoryIndex != nil else { return false }
        let history = SelfConversionSettings.inputHistory
        let index = recalledHistoryIndex.map { $0 + 1 } ?? 0
        guard history.indices.contains(index) else {
            NSSound.beep()
            return true
        }
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        batchConversionStateChange {
            suffixMode = false
            suffixInput = ""
            suffixPrefixes = [:]
            committedReading = ""
            committedText = ""
            activeSessionInput = ""
            nextSessionBuffer = ""
            inputBuffer = history[index]
            candidates = []
            selectedIndex = 0
            isLoadingCandidates = false
        }
        recalledHistoryIndex = index
        forceStartCurrentConversion()
        return true
    }

    private func beginCandidateSelection() {
        // The user's selection owns this candidate list until input/range is
        // edited or conversion is explicitly requested. Neither a debounce nor
        // an already-running response may replace it before Enter/Tab.
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        isLoadingCandidates = false
        explicitSelection = true
    }

    func selectedText() -> String {
        flushCandidateDisplay()
        let source = hasActiveConversionSession ? activeSessionInput : inputBuffer
        guard !source.isEmpty else { return "" }
        guard candidates.indices.contains(selectedIndex) else {
            // With no displayed candidate, confirm the displayed raw input.
            // A key press must not silently transliterate an unconverted word.
            return source
        }
        let text = candidates[selectedIndex].text
        return suffixPrefixes[text] ?? text
    }

    func composedText() -> String {
        let source = hasActiveConversionSession ? activeSessionInput : inputBuffer
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joinCommittedText(committedText, selectedText())
    }

    func confirmAndClose() -> SelfConversionDecisionSnapshot {
        let snapshot = decisionSnapshot()
        cancel()
        return snapshot
    }

    @discardableResult
    func commitCurrentCandidateForContinuation() -> SelfConversionDecisionSnapshot {
        recalledHistoryIndex = nil
        let snapshot = decisionSnapshot()
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        let text = selectedText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return snapshot }
        let source = hasActiveConversionSession ? activeSessionInput : inputBuffer
        let nextReading = committedReading.map { $0 + source }
        let nextCommittedText = joinCommittedText(committedText, text)
        let nextInput = nextSessionBuffer
        batchConversionStateChange {
            suffixMode = false
            suffixInput = ""
            suffixPrefixes = [:]
            committedReading = nextReading
            committedText = nextCommittedText
            inputBuffer = nextInput
            activeSessionInput = ""
            nextSessionBuffer = ""
            candidates = []
            selectedIndex = 0
            isLoadingCandidates = false
        }
        forceStartCurrentConversion()
        return snapshot
    }

    func forceStartCurrentConversion() {
        pendingConversion?.cancel()
        if suffixMode {
            startSuffixConversion()
            return
        }
        if hasActiveConversionSession {
            guard !isConversionRequestInFlight else { return }
            startConversionRequest(for: activeSessionInput)
            return
        }
        startCurrentInputConversion()
    }

    func decisionSnapshot() -> SelfConversionDecisionSnapshot {
        flushCandidateDisplay()
        let committedCandidates = candidates.map { candidate in
            JapaneseConversionCandidate(text: suffixPrefixes[candidate.text] ?? candidate.text,
                                        score: candidate.score, isNative: candidate.isNative && !suffixMode)
        }
        let selected = committedCandidates.indices.contains(selectedIndex) ? committedCandidates[selectedIndex] : nil
        let source = hasActiveConversionSession ? activeSessionInput : inputBuffer
        return SelfConversionDecisionSnapshot(
            input: source,
            context: joinCommittedText(initialContext, committedText),
            committedText: committedText,
            composedText: composedText(),
            selectedIndex: selectedIndex,
            selectedCandidate: selected,
            candidates: committedCandidates,
            explicitSelection: explicitSelection,
            learningInput: committedReading.map { $0 + source },
            learningText: committedReading == nil ? nil : composedText()
        )
    }

    private func buildContent(in panel: NSPanel) {
        let content = SelfConversionBackgroundView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        committedLabel.font = Self.committedTextFont()
        committedLabel.textColor = .secondaryLabelColor
        committedLabel.lineBreakMode = .byCharWrapping
        committedLabel.maximumNumberOfLines = 0
        committedLabel.usesSingleLineMode = false
        committedLabel.isHidden = true
        stack.addArrangedSubview(committedLabel)

        rawLabel.font = Self.rawTextFont()
        rawLabel.textColor = .labelColor
        Self.configureExpandableSingleLineLabel(rawLabel)
        stack.addArrangedSubview(rawLabel)

        nextRawLabel.font = Self.rawTextFont()
        nextRawLabel.textColor = .labelColor
        Self.configureExpandableSingleLineLabel(nextRawLabel)
        nextRawLabel.isHidden = true
        stack.addArrangedSubview(nextRawLabel)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        ensureCandidateRows(count: Self.initialCandidateRowCount)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        rawWidthConstraint = rawLabel.widthAnchor.constraint(equalToConstant: Self.baseContentWidth)
        separatorWidthConstraint = separator.widthAnchor.constraint(equalToConstant: Self.baseContentWidth)
        rawWidthConstraint?.isActive = true
        separatorWidthConstraint?.isActive = true
    }

    private func ensureCandidateRows(count: Int) {
        while candidateLabels.count < count {
            addCandidateRow()
        }
    }

    private func addCandidateRow() {
        let label = Self.makeLabel()
        label.font = NSFont.systemFont(ofSize: 15)
        Self.configureExpandableSingleLineLabel(label)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false

        candidateLabels.append(label)
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: rawLabel.widthAnchor).isActive = true
    }

    private func positionAtScreenCenter() {
        guard let window else { return }
        let screen = window.screen ?? Self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        window.setFrameOrigin(Self.centeredOrigin(windowSize: window.frame.size, visibleFrame: visible))
    }

    static func centeredOrigin(windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func startMouseDownMonitors() {
        stopMouseDownMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.cancelIfMouseDownIsOutsideWindow(at: NSEvent.mouseLocation)
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.cancelIfMouseDownIsOutsideWindow(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func stopMouseDownMonitors() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
    }

    private func cancelIfMouseDownIsOutsideWindow(at point: NSPoint) {
        let cancelIfNeeded = { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            guard Self.shouldCancelForMouseDown(at: point, windowFrame: window.frame) else { return }
            self.cancel()
        }

        if Thread.isMainThread {
            cancelIfNeeded()
        } else {
            DispatchQueue.main.async(execute: cancelIfNeeded)
        }
    }

    static func shouldCancelForMouseDown(at point: NSPoint, windowFrame: NSRect) -> Bool {
        !windowFrame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func updateRawText() {
        let value: NSAttributedString
        if suffixMode {
            let suffix = NSMutableAttributedString(attributedString: Self.suffixDisplay(prefix: activeSessionInput, suffix: suffixInput))
            suffix.addAttribute(.font, value: Self.rawTextFont(), range: NSRange(location: 0, length: suffix.length))
            value = suffix
        } else if hasActiveConversionSession && isLoadingCandidates && !usesRealtimeConversion {
            value = Self.loadingWaveText(activeSessionInput, phase: loadingWavePhase)
        } else {
            let text = hasActiveConversionSession ? activeSessionInput : (inputBuffer.isEmpty ? localized("conversion.placeholder") : inputBuffer)
            let color: NSColor = hasActiveConversionSession ? Self.convertingTextColor() : (inputBuffer.isEmpty ? .secondaryLabelColor : .labelColor)
            value = NSAttributedString(string: text, attributes: [.font: Self.rawTextFont(), .foregroundColor: color])
        }
        if renderedRawValue?.isEqual(to: value) != true {
            rawLabel.attributedStringValue = value
            renderedRawValue = value
            resizeToFitContent()
        }
    }

    private func updateNextRawText() {
        if nextRawLabel.stringValue != nextSessionBuffer { nextRawLabel.stringValue = nextSessionBuffer }
        let hidden = nextSessionBuffer.isEmpty
        if nextRawLabel.isHidden != hidden { nextRawLabel.isHidden = hidden }
        resizeToFitContent()
    }

    private func updateCommittedText() {
        if committedLabel.stringValue != committedText { committedLabel.stringValue = committedText }
        let hidden = committedText.isEmpty
        if committedLabel.isHidden != hidden { committedLabel.isHidden = hidden }
        resizeToFitContent()
    }

    private func scheduleConversionAfterStateChange() {
        guard !isBatchingConversionState else { return }
        scheduleConversion()
    }

    private func batchConversionStateChange(_ update: () -> Void) {
        isBatchingConversionState = true
        update()
        isBatchingConversionState = false
        scheduleConversion()
    }

    private func scheduleConversion() {
        pendingConversion?.cancel()
        guard !explicitSelection else { return }
        guard !hasActiveConversionSession else { return }
        guard !inputBuffer.isEmpty else {
            isLoadingCandidates = false
            candidates = []
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.explicitSelection else { return }
            self.startCurrentInputConversion()
        }
        pendingConversion = workItem
        enqueueConversion(workItem)
    }

    private func startCurrentInputConversion() {
        pendingConversion?.cancel()
        guard !hasActiveConversionSession else { return }
        let source = inputBuffer
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let split = Self.initialSessionSplit(for: source)
        inputBuffer = ""
        nextSessionBuffer = split.next
        startConversionRequest(for: split.current)
    }

    private func reviseBoundary(activeInput: String, nextInput: String) {
        recalledHistoryIndex = nil
        pendingConversion?.cancel()
        invalidateActiveConversionRequest()
        guard !activeInput.isEmpty else { return }

        isBatchingConversionState = true
        activeSessionInput = activeInput
        nextSessionBuffer = nextInput
        selectedIndex = 0
        setInterimCandidates(for: activeInput, context: joinCommittedText(initialContext, committedText))
        isLoadingCandidates = false
        isBatchingConversionState = false
        scheduleActiveSessionRevision(allowNextSessionBuffer: true)
    }

    private func scheduleActiveSessionRevision(allowNextSessionBuffer: Bool = false) {
        pendingConversion?.cancel()
        guard !explicitSelection else { return }
        guard canEditCompletedActiveSession || (allowNextSessionBuffer && hasActiveConversionSession && !isConversionRequestInFlight && !isLoadingCandidates) else {
            return
        }
        let source = activeSessionInput
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.explicitSelection, self.activeSessionInput == source else { return }
            guard self.canEditCompletedActiveSession || allowNextSessionBuffer else { return }
            self.startConversionRequest(for: source)
        }
        pendingConversion = workItem
        enqueueConversion(workItem)
    }

    private func startConversionRequest(for input: String) {
        // Revisions and manual boundary moves can also reach the API limit.
        // Apply the same bound as initial input, retaining every leftover char.
        let split = Self.initialSessionSplit(for: input)
        let source = split.current
        if !split.next.isEmpty {
            nextSessionBuffer = split.next + nextSessionBuffer
        }
        let currentCommittedText = committedText
        let currentInitialContext = initialContext
        let currentContext = joinCommittedText(currentInitialContext, currentCommittedText)
        let currentGeneration = nextConversionGeneration()
        activeSessionInput = source
        selectedIndex = 0
        setInterimCandidates(for: source, context: currentContext)
        isConversionRequestInFlight = true
        isLoadingCandidates = true
        client.convert(source, context: currentContext) { [weak self] converted in
            guard let self else { return }
            guard self.conversionGeneration == currentGeneration else { return }
            self.isConversionRequestInFlight = false

            let stateMatches = self.activeSessionInput == source
                && self.committedText == currentCommittedText
                && self.initialContext == currentInitialContext
            if stateMatches {
                self.holdsCandidateDisplay = false
                self.candidates = converted
                self.isLoadingCandidates = false
            }
        }
    }

    private var hasActiveConversionSession: Bool {
        !activeSessionInput.isEmpty
    }

    private var canEditCompletedActiveSession: Bool {
        hasActiveConversionSession &&
            !isConversionRequestInFlight &&
            !isLoadingCandidates &&
            nextSessionBuffer.isEmpty
    }

    private func invalidateActiveConversionRequest() {
        conversionGeneration += 1
        isConversionRequestInFlight = false
        stopLoadingWave()
    }

    private func nextConversionGeneration() -> Int {
        conversionGeneration += 1
        return conversionGeneration
    }

    private func updateLoadingState() {
        updateLoadingWaveTimer()
        updateRawText()
        resizeToFitContent()
    }

    private func setInterimCandidates(for input: String, context: String) {
        // Keep the last rendered result until the engine returns. The model is
        // replaced immediately so a quick confirm never commits stale input.
        holdsCandidateDisplay = usesRealtimeConversion && candidateLabels.contains { !$0.isHidden && !$0.stringValue.isEmpty }
        candidates = SelfConversionCandidateBuilder.fallbackCandidates(for: input, context: context)
    }

    private func flushCandidateDisplay() {
        // Selection/confirmation must use the current model and its display,
        // even if conversion is still running or a render is queued.
        holdsCandidateDisplay = false
        candidateRenderScheduled = false
        renderCandidateRows()
    }

    private func updateCandidateViews() {
        guard !holdsCandidateDisplay, !candidateRenderScheduled else { return }
        candidateRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.candidateRenderScheduled else { return }
            self.candidateRenderScheduled = false
            guard !self.holdsCandidateDisplay else { return }
            self.renderCandidateRows()
        }
    }

    private func updateCandidateSelection() {
        updateCandidateViews()
    }

    private func renderCandidateRows() {
        ensureCandidateRows(count: candidates.count)
        while renderedCandidateValues.count < candidateLabels.count { renderedCandidateValues.append(NSAttributedString(string: "")) }
        for (index, label) in candidateLabels.enumerated() {
            guard candidates.indices.contains(index) else {
                if !label.isHidden { label.isHidden = true }
                continue
            }
            let candidate = candidates[index]
            let selected = index == selectedIndex
            let font = NSFont.systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
            let color = selected ? Self.selectionTextColor() : NSColor.labelColor
            let value: NSMutableAttributedString
            if suffixMode, let prefix = suffixPrefixes[candidate.text] {
                value = NSMutableAttributedString(attributedString: Self.suffixDisplay(
                    prefix: prefix, suffix: String(candidate.text.dropFirst(prefix.count)), selected: selected))
                value.addAttribute(.font, value: font, range: NSRange(location: 0, length: value.length))
            } else {
                let text = (candidate.isNative || candidate.isLearned) ? candidate.text : String(format: "%@  %.2f", candidate.text, candidate.score)
                value = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            }
            // AppKit invalidates a field when its setters run, even if a new
            // value looks identical. Compare the complete row before writing.
            if !renderedCandidateValues[index].isEqual(to: value) {
                label.attributedStringValue = value
                if label.font != font { label.font = font }
                renderedCandidateValues[index] = value
            }
            if label.isHidden { label.isHidden = false }
            if label.drawsBackground != selected { label.drawsBackground = selected }
            let background = selected ? Self.selectionBackgroundColor() : NSColor.clear
            if label.backgroundColor != background { label.backgroundColor = background }
        }
        resizeToFitContent()
    }

    private func resizeToFitContent(keepingTop: Bool = true) {
        if !keepingTop {
            layoutScheduled = false
            performContentResize(keepingTop: false)
            return
        }
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutScheduled else { return }
            self.layoutScheduled = false
            self.performContentResize()
        }
    }

    private func performContentResize(keepingTop: Bool = true) {
        guard let window else { return }
        let measuredWidth = desiredContentWidth()
        let contentWidth = usesRealtimeConversion ? min(max(measuredWidth, stableContentWidth), maxContentWidthForCurrentScreen()) : measuredWidth
        stableContentWidth = contentWidth
        if rawWidthConstraint?.constant != contentWidth { rawWidthConstraint?.constant = contentWidth }
        if separatorWidthConstraint?.constant != contentWidth { separatorWidthConstraint?.constant = contentWidth }
        window.contentView?.layoutSubtreeIfNeeded()

        let targetWidth = contentWidth + Self.horizontalPadding
        let measuredHeight = desiredContentHeight()
        let targetContentHeight = usesRealtimeConversion ? max(measuredHeight, stableContentHeight) : measuredHeight
        stableContentHeight = targetContentHeight
        var frame = window.frame
        let visibleFrame = (window.screen ?? Self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame
            ?? frame
        let targetFrame = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: NSSize(width: targetWidth, height: targetContentHeight)
        ))
        let maximumHeight = keepingTop
            ? min(visibleFrame.height - 24, max(Self.minimumContentHeight, frame.maxY - visibleFrame.minY - 12))
            : visibleFrame.height - 24
        let targetSize = NSSize(width: targetFrame.width, height: min(targetFrame.height, maximumHeight))
        frame = keepingTop
            ? Self.frameResizedKeepingTop(currentFrame: frame, targetSize: targetSize, visibleFrame: visibleFrame)
            : NSRect(origin: Self.centeredOrigin(windowSize: targetSize, visibleFrame: visibleFrame), size: targetSize)
        if !keepingTop {
            frame.origin.y = max(frame.origin.y, visibleFrame.minY + 12)
        } else if usesRealtimeConversion {
            frame.origin.x = window.frame.minX
        }
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + 12), visibleFrame.maxX - frame.width - 12)

        guard abs(window.frame.width - frame.width) > 1 ||
            abs(window.frame.height - frame.height) > 1 ||
            abs(window.frame.origin.x - frame.origin.x) > 1 ||
            abs(window.frame.origin.y - frame.origin.y) > 1 else { return }
        window.setFrame(frame, display: true)
    }

    static func frameResizedKeepingTop(currentFrame: NSRect, targetSize: NSSize, visibleFrame: NSRect) -> NSRect {
        var frame = currentFrame
        frame.size = targetSize
        frame.origin.x = visibleFrame.midX - targetSize.width / 2
        let top = min(max(currentFrame.maxY, visibleFrame.minY + targetSize.height + 12), visibleFrame.maxY - 12)
        frame.origin.y = top - targetSize.height
        return frame
    }

    static func initialSessionSplit(for input: String) -> (current: String, next: String) {
        guard input.unicodeScalars.count > maximumConversionInputScalars else {
            return (input, "")
        }
        // The headless API supports 256 Unicode scalars. The previous 40/48
        // character split was a workaround for the retired LLM backend.
        var upperBound = input.startIndex
        var scalarCount = 0
        while upperBound < input.endIndex {
            let next = input.index(after: upperBound)
            let count = input[upperBound..<next].unicodeScalars.count
            guard scalarCount + count <= maximumConversionInputScalars else { break }
            scalarCount += count
            upperBound = next
        }
        var split = upperBound
        var cursor = input.startIndex
        while cursor < upperBound {
            let next = input.index(after: cursor)
            if next <= upperBound, isPreferredSplitCharacter(input[cursor]) {
                split = next
            }
            cursor = next
        }
        guard split > input.startIndex, split < input.endIndex else {
            return (input, "")
        }
        return (String(input[..<split]), String(input[split...]))
    }

    private static func isPreferredSplitCharacter(_ character: Character) -> Bool {
        switch character.lowercased() {
        case "a", "i", "u", "e", "o", "n", "-", " ", ".", ",", "?", "!":
            return true
        default:
            return false
        }
    }

    private func desiredContentHeight() -> CGFloat {
        window?.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = ceil(stack.fittingSize.height)
        return max(Self.minimumContentHeight, fittingHeight)
    }

    private func desiredContentWidth() -> CGFloat {
        var measuredItems: [(text: String, font: NSFont)] = []
        if !committedLabel.isHidden {
            measuredItems.append((committedLabel.stringValue, committedLabel.font ?? Self.committedTextFont()))
        }
        measuredItems.append((rawLabel.stringValue, Self.rawTextFont()))
        if !nextRawLabel.isHidden {
            measuredItems.append((nextRawLabel.stringValue, Self.rawTextFont()))
        }
        measuredItems.append(contentsOf: candidateLabels
            .enumerated()
            .filter { _, label in !label.isHidden }
            .map { (text: $0.element.stringValue, font: $0.element.font ?? Self.candidateTextFont()) })
        let measured = measuredItems.reduce(Self.baseContentWidth) { width, item in
            max(width, ceil(Self.measuredWidth(of: item.text, font: item.font)))
        }
        let maxWidth = maxContentWidthForCurrentScreen()
        return min(max(measured + Self.textMeasurementPadding, Self.baseContentWidth), maxWidth)
    }

    private func maxContentWidthForCurrentScreen() -> CGFloat {
        let screen = window?.screen ?? Self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        let visibleWidth = screen?.visibleFrame.width ?? Self.baseWindowWidth
        return max(Self.baseContentWidth, visibleWidth - Self.horizontalPadding - 24)
    }

    private static func measuredWidth(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private static func configureExpandableSingleLineLabel(_ field: NSTextField) {
        field.lineBreakMode = .byClipping
        field.cell?.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private static func rawTextFont() -> NSFont {
        if #available(macOS 10.15, *) {
            return NSFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        }
        return NSFont(name: "Menlo", size: 18) ?? NSFont.systemFont(ofSize: 18, weight: .medium)
    }

    private static func committedTextFont() -> NSFont {
        NSFont.systemFont(ofSize: 14, weight: .medium)
    }

    private static func candidateTextFont() -> NSFont {
        NSFont.systemFont(ofSize: 15, weight: .semibold)
    }

    private static func selectionBackgroundColor() -> NSColor {
        if #available(macOS 10.14, *) {
            return NSColor.controlAccentColor.withAlphaComponent(1.0)
        }
        return NSColor.systemBlue.withAlphaComponent(1.0)
    }

    private static func selectionTextColor() -> NSColor {
        if #available(macOS 10.14, *) {
            return NSColor.selectedMenuItemTextColor
        }
        return .white
    }

    private func updateLoadingWaveTimer() {
        guard !usesRealtimeConversion, isLoadingCandidates, hasActiveConversionSession else {
            stopLoadingWave()
            return
        }
        guard loadingWaveTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.loadingWaveInterval,
            target: self,
            selector: #selector(SelfConversionWindowController.advanceLoadingWave(_:)),
            userInfo: nil,
            repeats: true
        )
        loadingWaveTimer = timer
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.add(timer, forMode: .eventTracking)
        RunLoop.current.add(timer, forMode: .modalPanel)
    }

    @objc private func advanceLoadingWave(_ timer: Timer) {
        loadingWavePhase = (loadingWavePhase + Self.loadingWavePhaseStep)
            .truncatingRemainder(dividingBy: Self.loadingWavePeriod)
        updateRawText()
    }

    private func stopLoadingWave() {
        loadingWaveTimer?.invalidate()
        loadingWaveTimer = nil
        loadingWavePhase = 0
    }

    private static func convertingTextColor() -> NSColor {
        NSColor(calibratedWhite: 0.32, alpha: 1.0)
    }

    private static func loadingWaveText(_ text: String, phase: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        guard !text.isEmpty else { return result }
        let font = rawTextFont()
        var location = 0
        var cursorX: CGFloat = 0
        for character in text {
            let fragment = String(character)
            let width = measuredWidth(of: fragment, font: font)
            let centerX = cursorX + width / 2
            let white = loadingWaveWhiteValue(atX: centerX, phase: phase)
            let length = (fragment as NSString).length
            result.addAttributes(
                [
                    .foregroundColor: NSColor(calibratedWhite: white, alpha: 1.0),
                    .font: font,
                ],
                range: NSRange(location: location, length: max(length, 1))
            )
            cursorX += width
            location += max(length, 1)
        }
        return result
    }

    static func loadingWaveWhiteValue(atX x: CGFloat, phase: CGFloat) -> CGFloat {
        let shifted = (x - phase).truncatingRemainder(dividingBy: loadingWavePeriod)
        let wrapped = shifted >= 0 ? shifted : shifted + loadingWavePeriod
        let distanceFromWaveCenter = abs(wrapped - loadingWavePeriod / 2)
        let normalized = min(max(distanceFromWaveCenter / (loadingWavePeriod / 2), 0), 1)
        return normalized * 0.78
    }

    private static func makeLabel(_ string: String = "") -> NSTextField {
        let field = NSTextField()
        field.stringValue = string
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        return field
    }

    private static let baseWindowWidth: CGFloat = 420
    private static let baseContentWidth: CGFloat = 384
    private static let horizontalPadding: CGFloat = 36
    private static let textMeasurementPadding: CGFloat = 24
    private static let minimumContentHeight: CGFloat = 96
    private static let initialCandidateRowCount = 5
    private func enqueueConversion(_ work: DispatchWorkItem) {
        if client.conversionDebounceDelay == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + client.conversionDebounceDelay, execute: work)
        }
    }
    private static let loadingWaveInterval: TimeInterval = 0.12
    static let loadingWavePeriod: CGFloat = 96
    private static let loadingWavePhaseStep: CGFloat = 14
    private static let maximumConversionInputScalars = 256

    private func joinCommittedText(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        return lhs + rhs
    }
}

private final class SelfConversionBackgroundView: NSView {
    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
