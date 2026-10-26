import AppKit
import CoreLocation
import MapKit

// MARK: - Map Annotations & Interactive MKMapView

private final class BaseLocationAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

private final class DriftLocationAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? = "GPS 硬件实时输出"
    var subtitle: String?

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

final class InteractiveLocationMapView: MKMapView {
    var onSingleClickCoordinate: ((CLLocationCoordinate2D) -> Void)?
    private var mouseDownLocation: NSPoint?
    private var mouseDownTime: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        mouseDownTime = event.timestamp
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = convert(event.locationInWindow, from: nil)
        let elapsed = event.timestamp - mouseDownTime
        let downPoint = mouseDownLocation
        mouseDownLocation = nil
        super.mouseUp(with: event)

        guard event.clickCount == 1,
              elapsed < 0.45,
              let downPoint,
              hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < 4.5 else {
            return
        }
        let coord = convert(upPoint, toCoordinateFrom: self)
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        onSingleClickCoordinate?(coord)
    }
}

// MARK: - Persistent Developer Location Console View (Map + Search + 100ms/10m Drift)

@MainActor
final class DeveloperLocationWorkspaceView: NSView, MKMapViewDelegate, NSSearchFieldDelegate {
    private(set) var plugin: DeveloperLocationPlugin

    private let rootStack = NSStackView()
    private let controlCard = TFCardView(frame: .zero)
    private let searchField = NSSearchField(frame: .zero)
    private var searchButton: TFButton!
    private let quickDriftLbl = NSTextField(labelWithString: "自动漂移")
    private let cardSeparator = TFCardView(frame: .zero)
    private let presetTitle = NSTextField(labelWithString: "常用位置")
    private let searchResultsCard = TFCardView(frame: .zero)
    private let searchResultsStack = NSStackView()
    private let landmarksRowStack = NSStackView()

    private let mapCard = TFCardView(frame: .zero)
    let mapView = InteractiveLocationMapView(frame: .zero)
    private let floatingToolbar = TFCardView(frame: .zero)
    private var mapStyleButton: TFButton!
    private var pickCenterButton: TFButton!
    private var recenterButton: TFButton!
    private var zoomInButton: TFButton!
    private var zoomOutButton: TFButton!
    private let mapHintBadge = TFCardView(frame: .zero)
    private let mapHintDot = TFCardView(frame: .zero)
    private let mapHintLabel = NSTextField(labelWithString: "")

    private let baseAnnotation = BaseLocationAnnotation(
        coordinate: CLLocationCoordinate2D(latitude: 22.541664, longitude: 114.104519),
        title: "当前定位",
        subtitle: nil
    )
    private let driftAnnotation = DriftLocationAnnotation(
        coordinate: CLLocationCoordinate2D(latitude: 22.541664, longitude: 114.104519)
    )
    private var radiusOverlay: MKCircle?
    private var hasInitializedMapRegion = false
    private var lastRenderedBaseCoordinate: GeoCoordinate?

    private var headerDriftSwitch: TFToggleSwitch!

    private var isHybridMap = false
    private var searchTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init(plugin: DeveloperLocationPlugin, showCompanionButton: Bool = false) {
        _ = showCompanionButton
        self.plugin = plugin
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildWorkspaceUI()
        refreshTheme()
        syncFromTelemetry(plugin.currentTelemetrySnapshot(), recenterMap: true)
    }

    required init?(coder: NSCoder) { nil }

    func bindPlugin(_ newPlugin: DeveloperLocationPlugin) {
        guard plugin !== newPlugin else {
            rebuildLandmarkButtons()
            syncFromTelemetry(plugin.currentTelemetrySnapshot(), recenterMap: false)
            return
        }
        self.plugin = newPlugin
        headerDriftSwitch?.isOn = newPlugin.configuration.driftEnabled
        rebuildLandmarkButtons()
        syncFromTelemetry(newPlugin.currentTelemetrySnapshot(), recenterMap: true)
    }

    // MARK: - UI Construction

    private func buildWorkspaceUI() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        addFullWidth(makeSearchAndPresetCard(), to: rootStack)

        searchResultsCard.translatesAutoresizingMaskIntoConstraints = false
        searchResultsCard.cornerRadius = 10
        searchResultsCard.isHidden = true
        searchResultsStack.orientation = .vertical
        searchResultsStack.alignment = .leading
        searchResultsStack.spacing = 0
        searchResultsStack.translatesAutoresizingMaskIntoConstraints = false
        searchResultsCard.addSubview(searchResultsStack)
        NSLayoutConstraint.activate([
            searchResultsStack.leadingAnchor.constraint(equalTo: searchResultsCard.leadingAnchor),
            searchResultsStack.trailingAnchor.constraint(equalTo: searchResultsCard.trailingAnchor),
            searchResultsStack.topAnchor.constraint(equalTo: searchResultsCard.topAnchor),
            searchResultsStack.bottomAnchor.constraint(equalTo: searchResultsCard.bottomAnchor)
        ])
        addFullWidth(searchResultsCard, to: rootStack)

        addFullWidth(makeInteractiveMapSection(), to: rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeSearchAndPresetCard() -> NSView {
        let card = controlCard
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true

        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(topRow)

        searchField.placeholderString = "搜索地点、大厦或输入 纬度, 经度"
        searchField.font = .systemFont(ofSize: 12.5)
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.sendsWholeSearchString = true
            cell.sendsSearchStringImmediately = false
        }
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(triggerSearchFromField)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(searchField)

        let rightButtons = NSStackView()
        rightButtons.orientation = .horizontal
        rightButtons.alignment = .centerY
        rightButtons.spacing = 10
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(rightButtons)

        searchButton = TFButton(title: "搜索", symbolName: "magnifyingglass", variant: .primary, size: .sm)
        searchButton.onClick = { [weak self] in self?.performLocationSearch() }
        rightButtons.addArrangedSubview(searchButton)

        let quickDriftWrap = NSStackView()
        quickDriftWrap.orientation = .horizontal
        quickDriftWrap.alignment = .centerY
        quickDriftWrap.spacing = 6
        quickDriftWrap.translatesAutoresizingMaskIntoConstraints = false
        rightButtons.addArrangedSubview(quickDriftWrap)

        quickDriftLbl.font = .systemFont(ofSize: 12, weight: .medium)
        quickDriftLbl.textColor = TFTheme.ink2
        quickDriftWrap.addArrangedSubview(quickDriftLbl)

        headerDriftSwitch = TFToggleSwitch(isOn: plugin.configuration.driftEnabled)
        headerDriftSwitch.setAccessibilityLabel("位置漂移")
        headerDriftSwitch.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.plugin.setDriftEnabled(enabled)
            self.syncFromTelemetry(self.plugin.currentTelemetrySnapshot(), recenterMap: false)
        }
        quickDriftWrap.addArrangedSubview(headerDriftSwitch)

        let sep = cardSeparator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.cornerRadius = 0
        sep.fillColor = TFTheme.line
        card.addSubview(sep)

        let presetWrap = NSView()
        presetWrap.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(presetWrap)

        presetTitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        presetTitle.textColor = TFTheme.ink3
        presetTitle.setContentHuggingPriority(.required, for: .horizontal)
        presetTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        presetTitle.translatesAutoresizingMaskIntoConstraints = false
        presetWrap.addSubview(presetTitle)

        landmarksRowStack.orientation = .horizontal
        landmarksRowStack.alignment = .centerY
        landmarksRowStack.spacing = 6
        landmarksRowStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        landmarksRowStack.translatesAutoresizingMaskIntoConstraints = false
        presetWrap.addSubview(landmarksRowStack)

        rebuildLandmarkButtons()

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 86),
            topRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            topRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            topRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            topRow.heightAnchor.constraint(equalToConstant: 32),

            searchField.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: rightButtons.leadingAnchor, constant: -12),

            rightButtons.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            rightButtons.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            sep.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            sep.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            sep.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            sep.heightAnchor.constraint(equalToConstant: 1),

            presetWrap.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            presetWrap.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            presetWrap.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 5),
            presetWrap.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),

            presetTitle.leadingAnchor.constraint(equalTo: presetWrap.leadingAnchor),
            presetTitle.centerYAnchor.constraint(equalTo: presetWrap.centerYAnchor),

            landmarksRowStack.leadingAnchor.constraint(equalTo: presetTitle.trailingAnchor, constant: 8),
            landmarksRowStack.centerYAnchor.constraint(equalTo: presetWrap.centerYAnchor),
            landmarksRowStack.trailingAnchor.constraint(lessThanOrEqualTo: presetWrap.trailingAnchor)
        ])
        return card
    }

    func rebuildLandmarkButtons() {
        for sub in landmarksRowStack.arrangedSubviews {
            landmarksRowStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for item in plugin.landmarks.prefix(5) {
            let btn = TFButton(title: item.name, variant: .subtle, size: .sm)
            btn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            btn.onClick = { [weak self] in
                guard let self else { return }
                self.searchResultsCard.isHidden = true
                self.plugin.selectLocation(item.coordinate)
                self.syncFromTelemetry(self.plugin.currentTelemetrySnapshot(), recenterMap: true)
            }
            landmarksRowStack.addArrangedSubview(btn)
        }
    }

    private func makeInteractiveMapSection() -> NSView {
        mapCard.translatesAutoresizingMaskIntoConstraints = false
        mapCard.cornerRadius = 12
        mapCard.fillColor = TFTheme.card
        mapCard.strokeColor = TFTheme.line
        mapCard.hasCardShadow = true

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsZoomControls = false
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = 11
        mapView.layer?.masksToBounds = true
        mapView.addAnnotation(baseAnnotation)
        mapView.addAnnotation(driftAnnotation)
        mapView.onSingleClickCoordinate = { [weak self] clCoord in
            guard let self else { return }
            let picked = GeoCoordinate(
                latitude: clCoord.latitude,
                longitude: clCoord.longitude,
                name: String(format: "地图选点 (%.5f, %.5f)", clCoord.latitude, clCoord.longitude),
                subtitle: "手动点击地图拾取",
                coordinateSystem: .auto
            )
            self.plugin.selectLocation(picked)
            self.syncFromTelemetry(self.plugin.currentTelemetrySnapshot(), recenterMap: false)
        }
        mapCard.addSubview(mapView)

        floatingToolbar.translatesAutoresizingMaskIntoConstraints = false
        floatingToolbar.cornerRadius = 9
        floatingToolbar.fillColor = TFTheme.card.withAlphaComponent(0.92)
        floatingToolbar.strokeColor = TFTheme.line
        floatingToolbar.hasCardShadow = true
        mapCard.addSubview(floatingToolbar)

        let barStack = NSStackView()
        barStack.orientation = .horizontal
        barStack.alignment = .centerY
        barStack.spacing = 6
        barStack.translatesAutoresizingMaskIntoConstraints = false
        floatingToolbar.addSubview(barStack)

        pickCenterButton = TFButton(title: "拾取视野中心", symbolName: "scope", variant: .secondary, size: .sm)
        pickCenterButton.onClick = { [weak self] in
            guard let self else { return }
            let c = self.mapView.centerCoordinate
            guard CLLocationCoordinate2DIsValid(c) else { return }
            let picked = GeoCoordinate(
                latitude: c.latitude,
                longitude: c.longitude,
                name: String(format: "视野中心 (%.5f, %.5f)", c.latitude, c.longitude),
                subtitle: "地图中心点选定",
                coordinateSystem: .auto
            )
            self.plugin.selectLocation(picked)
            self.syncFromTelemetry(self.plugin.currentTelemetrySnapshot(), recenterMap: false)
        }
        barStack.addArrangedSubview(pickCenterButton)

        recenterButton = TFButton(title: "回到选点", symbolName: "location.fill", variant: .subtle, size: .sm)
        recenterButton.onClick = { [weak self] in
            guard let self else { return }
            self.centerMap(on: self.plugin.configuration.selectedCoordinate, spanMeters: 220)
        }
        barStack.addArrangedSubview(recenterButton)

        mapStyleButton = TFButton(title: "卫星图", symbolName: "globe.asia.australia.fill", variant: .subtle, size: .sm)
        mapStyleButton.onClick = { [weak self] in
            guard let self else { return }
            self.isHybridMap.toggle()
            if #available(macOS 13.0, *) {
                self.mapView.preferredConfiguration = self.isHybridMap
                    ? MKHybridMapConfiguration(elevationStyle: .flat)
                    : MKStandardMapConfiguration(elevationStyle: .flat)
            }
            self.mapStyleButton.title = self.isHybridMap ? "标准图" : "卫星图"
        }
        barStack.addArrangedSubview(mapStyleButton)

        zoomInButton = TFButton(title: "", symbolName: "plus.magnifyingglass", variant: .subtle, size: .sm)
        zoomInButton.setAccessibilityLabel("放大地图")
        zoomInButton.onClick = { [weak self] in self?.zoomMap(factor: 0.5) }
        barStack.addArrangedSubview(zoomInButton)

        zoomOutButton = TFButton(title: "", symbolName: "minus.magnifyingglass", variant: .subtle, size: .sm)
        zoomOutButton.setAccessibilityLabel("缩小地图")
        zoomOutButton.onClick = { [weak self] in self?.zoomMap(factor: 2.0) }
        barStack.addArrangedSubview(zoomOutButton)

        mapHintBadge.translatesAutoresizingMaskIntoConstraints = false
        mapHintBadge.cornerRadius = 7
        mapHintBadge.fillColor = TFTheme.card.withAlphaComponent(0.90)
        mapHintBadge.strokeColor = TFTheme.line
        mapCard.addSubview(mapHintBadge)

        mapHintDot.translatesAutoresizingMaskIntoConstraints = false
        mapHintDot.cornerRadius = 3.5
        mapHintDot.fillColor = TFTheme.positive
        mapHintBadge.addSubview(mapHintDot)

        mapHintLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        mapHintLabel.textColor = TFTheme.ink2
        mapHintLabel.lineBreakMode = .byTruncatingTail
        mapHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mapHintLabel.translatesAutoresizingMaskIntoConstraints = false
        mapHintBadge.addSubview(mapHintLabel)

        NSLayoutConstraint.activate([
            mapCard.heightAnchor.constraint(equalToConstant: 440),
            mapView.leadingAnchor.constraint(equalTo: mapCard.leadingAnchor, constant: 1),
            mapView.trailingAnchor.constraint(equalTo: mapCard.trailingAnchor, constant: -1),
            mapView.topAnchor.constraint(equalTo: mapCard.topAnchor, constant: 1),
            mapView.bottomAnchor.constraint(equalTo: mapCard.bottomAnchor, constant: -1),

            floatingToolbar.topAnchor.constraint(equalTo: mapCard.topAnchor, constant: 12),
            floatingToolbar.trailingAnchor.constraint(equalTo: mapCard.trailingAnchor, constant: -12),
            floatingToolbar.heightAnchor.constraint(equalToConstant: 36),
            barStack.leadingAnchor.constraint(equalTo: floatingToolbar.leadingAnchor, constant: 6),
            barStack.trailingAnchor.constraint(equalTo: floatingToolbar.trailingAnchor, constant: -6),
            barStack.centerYAnchor.constraint(equalTo: floatingToolbar.centerYAnchor),

            mapHintBadge.leadingAnchor.constraint(equalTo: mapCard.leadingAnchor, constant: 12),
            mapHintBadge.trailingAnchor.constraint(lessThanOrEqualTo: mapCard.trailingAnchor, constant: -12),
            mapHintBadge.bottomAnchor.constraint(equalTo: mapCard.bottomAnchor, constant: -12),
            mapHintBadge.heightAnchor.constraint(equalToConstant: 28),
            mapHintDot.leadingAnchor.constraint(equalTo: mapHintBadge.leadingAnchor, constant: 10),
            mapHintDot.centerYAnchor.constraint(equalTo: mapHintBadge.centerYAnchor),
            mapHintDot.widthAnchor.constraint(equalToConstant: 7),
            mapHintDot.heightAnchor.constraint(equalToConstant: 7),
            mapHintLabel.leadingAnchor.constraint(equalTo: mapHintDot.trailingAnchor, constant: 7),
            mapHintLabel.trailingAnchor.constraint(equalTo: mapHintBadge.trailingAnchor, constant: -11),
            mapHintLabel.centerYAnchor.constraint(equalTo: mapHintBadge.centerYAnchor)
        ])
        return mapCard
    }

    // MARK: - Search & Manual Coordinate Actions

    @objc private func triggerSearchFromField() {
        performLocationSearch()
    }

    func performLocationSearch() {
        let trimmed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            searchResultsCard.isHidden = true
            return
        }
        if let directCoord = DeveloperLocationPlugin.parseCoordinateQuery(trimmed) {
            searchResultsCard.isHidden = true
            plugin.selectLocation(directCoord)
            syncFromTelemetry(plugin.currentTelemetrySnapshot(), recenterMap: true)
            return
        }
        renderSearchStatusRow(message: "正在搜索「\(trimmed)」…", isError: false, showRetry: false)
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.plugin.searchLocationsWithStatus(query: trimmed)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .results(let list):
                self.renderSearchResults(list)
            case .empty(let q):
                self.renderSearchStatusRow(message: "未找到与「\(q)」匹配的位置", isError: false, showRetry: false)
            case .failed(let q, _):
                self.renderSearchStatusRow(message: "搜索「\(q)」失败，请检查网络后重试", isError: true, showRetry: true)
            }
        }
    }

    private func renderSearchStatusRow(message: String, isError: Bool, showRetry: Bool) {
        for sub in searchResultsStack.arrangedSubviews {
            searchResultsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        searchResultsCard.fillColor = TFTheme.card
        searchResultsCard.strokeColor = TFTheme.line
        searchResultsCard.hasCardShadow = true
        searchResultsCard.isHidden = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: message)
        lbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        lbl.textColor = isError ? TFTheme.danger : TFTheme.ink3
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        if showRetry {
            let retryBtn = TFButton(title: "重试", variant: .secondary, size: .sm)
            retryBtn.onClick = { [weak self] in
                self?.performLocationSearch()
            }
            row.addSubview(retryBtn)
            NSLayoutConstraint.activate([
                retryBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                retryBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                lbl.trailingAnchor.constraint(lessThanOrEqualTo: retryBtn.leadingAnchor, constant: -10)
            ])
        } else {
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14).isActive = true
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        addFullWidth(row, to: searchResultsStack)
    }

    private func renderSearchResults(_ results: [GeoCoordinate]) {
        for sub in searchResultsStack.arrangedSubviews {
            searchResultsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        guard !results.isEmpty else {
            searchResultsCard.isHidden = true
            return
        }
        searchResultsCard.fillColor = TFTheme.card
        searchResultsCard.strokeColor = TFTheme.line
        searchResultsCard.hasCardShadow = true
        searchResultsCard.isHidden = false

        let capped = Array(results.prefix(5))
        for (idx, item) in capped.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let nameLbl = NSTextField(labelWithString: item.name)
            nameLbl.font = .systemFont(ofSize: 13, weight: .medium)
            nameLbl.textColor = TFTheme.ink
            nameLbl.lineBreakMode = .byTruncatingTail
            nameLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(nameLbl)

            let subLbl = NSTextField(labelWithString: "\(item.subtitle) · \(item.formattedLatLon)")
            subLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
            subLbl.textColor = TFTheme.ink3
            subLbl.lineBreakMode = .byTruncatingTail
            subLbl.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subLbl)

            let selectBtn = TFButton(title: "选定此位置", symbolName: "location.fill", variant: .secondary, size: .sm)
            selectBtn.onClick = { [weak self] in
                guard let self else { return }
                self.searchResultsCard.isHidden = true
                self.plugin.selectLocation(item)
                self.syncFromTelemetry(self.plugin.currentTelemetrySnapshot(), recenterMap: true)
            }
            row.addSubview(selectBtn)

            if idx < capped.count - 1 {
                let sep = TFCardView(frame: .zero)
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.cornerRadius = 0
                sep.fillColor = TFTheme.line
                row.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1)
                ])
            }

            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 48),
                nameLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                nameLbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
                nameLbl.trailingAnchor.constraint(lessThanOrEqualTo: selectBtn.leadingAnchor, constant: -10),
                subLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                subLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 2),
                subLbl.trailingAnchor.constraint(lessThanOrEqualTo: selectBtn.leadingAnchor, constant: -10),
                selectBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                selectBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            addFullWidth(row, to: searchResultsStack)
        }
    }

    // MARK: - Live Telemetry & Map In-Place Sync

    func syncFromTelemetry(_ telemetry: DeveloperLocationTelemetry, recenterMap: Bool = false) {
        if headerDriftSwitch?.isOn != telemetry.driftEnabled {
            headerDriftSwitch?.isOn = telemetry.driftEnabled
        }

        let baseChanged = (lastRenderedBaseCoordinate != telemetry.baseCoordinate)
        lastRenderedBaseCoordinate = telemetry.baseCoordinate
        let clBase = telemetry.baseCoordinate.clCoordinate

        if baseChanged {
            baseAnnotation.coordinate = clBase
            baseAnnotation.title = telemetry.baseCoordinate.name
            baseAnnotation.subtitle = telemetry.baseCoordinate.formattedLatLon
        }

        if telemetry.driftEnabled {
            if baseChanged || radiusOverlay == nil {
                if let existingOverlay = radiusOverlay {
                    mapView.removeOverlay(existingOverlay)
                }
                let circle = MKCircle(center: clBase, radius: telemetry.driftRadiusMeters)
                radiusOverlay = circle
                mapView.addOverlay(circle)
            }
        } else {
            if let existingOverlay = radiusOverlay {
                mapView.removeOverlay(existingOverlay)
                radiusOverlay = nil
            }
        }

        let clDrift = CLLocationCoordinate2D(
            latitude: telemetry.currentMapLatitude,
            longitude: telemetry.currentMapLongitude
        )
        driftAnnotation.coordinate = clDrift
        driftAnnotation.subtitle = String(
            format: "偏移 %.2fm · WGS84 %.6f, %.6f",
            telemetry.currentDriftDistanceMeters,
            telemetry.hardwareWGS84Latitude,
            telemetry.hardwareWGS84Longitude
        )
        mapView.view(for: driftAnnotation)?.isHidden = !telemetry.driftEnabled

        if recenterMap || !hasInitializedMapRegion {
            hasInitializedMapRegion = true
            centerMap(on: telemetry.baseCoordinate, spanMeters: 220)
        }

        switch telemetry.healthState {
        case .healthy:
            mapHintDot.fillColor = telemetry.driftEnabled ? TFTheme.positive : TFTheme.accent
            if telemetry.driftEnabled {
                mapHintLabel.stringValue = String(
                    format: "%@ (%.5f, %.5f) · %.0fm 自动漂移 +%.1fm",
                    telemetry.baseCoordinate.name,
                    telemetry.baseCoordinate.latitude,
                    telemetry.baseCoordinate.longitude,
                    telemetry.driftRadiusMeters,
                    telemetry.currentDriftDistanceMeters
                )
            } else {
                mapHintLabel.stringValue = String(
                    format: "%@ (%.5f, %.5f) · 定点模式",
                    telemetry.baseCoordinate.name,
                    telemetry.baseCoordinate.latitude,
                    telemetry.baseCoordinate.longitude
                )
            }
        case .waitingForRuntime:
            mapHintDot.fillColor = TFTheme.warn
            mapHintLabel.stringValue = String(
                format: "%@ (%.5f, %.5f) · 等待安卓容器就绪",
                telemetry.baseCoordinate.name,
                telemetry.baseCoordinate.latitude,
                telemetry.baseCoordinate.longitude
            )
        case .degraded(let reason):
            mapHintDot.fillColor = TFTheme.warn
            mapHintLabel.stringValue = String(
                format: "%@ (%.5f, %.5f) · %@",
                telemetry.baseCoordinate.name,
                telemetry.baseCoordinate.latitude,
                telemetry.baseCoordinate.longitude,
                reason
            )
        case .inactive:
            mapHintDot.fillColor = TFTheme.ink3
            mapHintLabel.stringValue = String(
                format: "%@ (%.5f, %.5f) · 未启用",
                telemetry.baseCoordinate.name,
                telemetry.baseCoordinate.latitude,
                telemetry.baseCoordinate.longitude
            )
        }
    }

    func refreshTheme() {
        controlCard.fillColor = TFTheme.card
        controlCard.strokeColor = TFTheme.line
        quickDriftLbl.textColor = TFTheme.ink2
        cardSeparator.fillColor = TFTheme.line
        presetTitle.textColor = TFTheme.ink3
        searchResultsCard.fillColor = TFTheme.card
        searchResultsCard.strokeColor = TFTheme.line
        mapCard.fillColor = TFTheme.card
        mapCard.strokeColor = TFTheme.line
        floatingToolbar.fillColor = TFTheme.card.withAlphaComponent(0.92)
        floatingToolbar.strokeColor = TFTheme.line
        mapHintBadge.fillColor = TFTheme.card.withAlphaComponent(0.92)
        mapHintBadge.strokeColor = TFTheme.line
        mapHintLabel.textColor = TFTheme.ink2
        searchButton?.refreshColors()
        pickCenterButton?.refreshColors()
        recenterButton?.refreshColors()
        mapStyleButton?.refreshColors()
        zoomInButton?.refreshColors()
        zoomOutButton?.refreshColors()
        headerDriftSwitch?.refreshState()
        for case let btn as TFButton in landmarksRowStack.arrangedSubviews {
            btn.refreshColors()
        }
    }

    private func centerMap(on coordinate: GeoCoordinate, spanMeters: CLLocationDistance) {
        let region = MKCoordinateRegion(
            center: coordinate.clCoordinate,
            latitudinalMeters: spanMeters,
            longitudinalMeters: spanMeters
        )
        mapView.setRegion(region, animated: true)
    }

    private func zoomMap(factor: Double) {
        var region = mapView.region
        region.span.latitudeDelta = max(0.0004, min(60.0, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = max(0.0004, min(60.0, region.span.longitudeDelta * factor))
        mapView.setRegion(region, animated: true)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let circle = overlay as? MKCircle {
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = TFTheme.accent.withAlphaComponent(0.16)
            renderer.strokeColor = TFTheme.accent.withAlphaComponent(0.75)
            renderer.lineWidth = 1.5
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation is BaseLocationAnnotation {
            let id = "BasePin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = TFTheme.accent
            view.glyphImage = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
            view.canShowCallout = true
            return view
        }
        if annotation is DriftLocationAnnotation {
            let id = "DriftDot"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            view.layer?.backgroundColor = TFTheme.positive.cgColor
            view.layer?.borderWidth = 2.0
            view.layer?.borderColor = NSColor.white.cgColor
            view.canShowCallout = true
            view.isHidden = !plugin.configuration.driftEnabled
            return view
        }
        return nil
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// MARK: - Generic External Script Plugin Dedicated Management Workspace

@MainActor
final class ExternalScriptPluginWorkspaceView: NSView {
    let plugin: ExternalDeveloperSystemPlugin
    weak var hostBridge: SystemPluginHostBridge?

    private let card = TFCardView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let hooksLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(plugin: ExternalDeveloperSystemPlugin, hostBridge: SystemPluginHostBridge?) {
        self.plugin = plugin
        self.hostBridge = hostBridge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        refreshContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 12
        card.fillColor = TFTheme.card
        card.strokeColor = TFTheme.line
        card.hasCardShadow = true
        addSubview(card)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = TFTheme.ink
        stack.addArrangedSubview(statusLabel)

        hooksLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        hooksLabel.textColor = TFTheme.ink2
        hooksLabel.maximumNumberOfLines = 4
        hooksLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(hooksLabel)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let runBtn = TFButton(title: "立即执行就绪钩子", symbolName: "play.fill", variant: .secondary, size: .sm)
        runBtn.onClick = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.plugin.triggerManualHookCheck(bridge: self.hostBridge)
                self.refreshContent()
            }
        }
        actions.addArrangedSubview(runBtn)

        let openDirBtn = TFButton(title: "打开插件包目录", symbolName: "folder", variant: .subtle, size: .sm)
        openDirBtn.onClick = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.selectFile(
                self.plugin.bundleDirectoryURL.appendingPathComponent("manifest.json").path,
                inFileViewerRootedAtPath: self.plugin.bundleDirectoryURL.path
            )
        }
        actions.addArrangedSubview(openDirBtn)
        stack.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
    }

    func refreshContent() {
        statusLabel.stringValue = "\(plugin.runtimeStatusSummary) · 已执行钩子 \(plugin.executedHookCount) 次"
        let hooks = plugin.manifest.entrypoints.allRelativePaths.joined(separator: "  ·  ")
        hooksLabel.stringValue = hooks.isEmpty ? "包路径：\(plugin.bundleDirectoryURL.path)" : "脚本入口：\(hooks)"
    }
}
