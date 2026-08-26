//
//  MainDashboardView.swift
//  IntelliDoc
//

import PhotosUI
import SwiftUI
import UIKit

/// A scan that has just been filed — drives the fly-into-folder animation.
struct FiledScan: Identifiable, Equatable {
    let id: String
    let folderId: String
    let thumbnail: UIImage?
    let pageCount: Int
}

/// The filing dashboard: folders with badge counts, recent scans, and the
/// amber capture bar pinned to the bottom edge.
struct MainDashboardView: View {
    @Environment(VaultStore.self) private var store
    @Environment(ScannerManager.self) private var scanner
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(VaultLockManager.self) private var locks
    @Environment(DeepLinkRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [VaultRoute] = []
    @State private var isShowingCamera = false
    @State private var isShowingReview = false
    @State private var isShowingNewFolder = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var isShowingPaywall = false
    @State private var isShowingSettings = false

    /// Set by the "Scan & Redact" deep link: after filing, the redaction
    /// studio opens on the freshly captured document.
    @State private var redactAfterScan = false
    @State private var redactTarget: ScannedDocument?

    @State private var flight: FiledScan?
    @State private var flightLanded = false
    @State private var pulsingFolderId: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        @Bindable var bindableStore = store

        NavigationStack(path: $path) {
            ZStack {
                Theme.backdrop

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        header
                        VaultSearchField(text: $bindableStore.searchQuery)

                        if store.isSearching {
                            searchResults
                        } else {
                            foldersSection
                            recentsSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) { captureBar }
            }
            .overlayPreferenceValue(FolderAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let flight {
                        FlightOverlay(
                            scan: flight,
                            landed: flightLanded,
                            reduceMotion: reduceMotion,
                            target: targetPoint(for: flight.folderId, anchors: anchors, proxy: proxy),
                            origin: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: VaultRoute.self) { route in
                switch route {
                case .folder(let folder):
                    FolderDetailView(folder: folder)
                case .document(let document):
                    DocumentDetailView(document: document)
                }
            }
        }
        .tint(Theme.amber)
        .fullScreenCover(isPresented: $isShowingCamera) {
            DocumentCameraView(
                onFinish: { images in
                    scanner.finish(with: images, source: .camera)
                    isShowingCamera = false
                    isShowingReview = true
                },
                onCancel: {
                    scanner.cancel()
                    isShowingCamera = false
                },
                onError: { error in
                    scanner.fail(error)
                    isShowingCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isShowingReview) {
            ScanReviewView { filed in
                isShowingReview = false
                Task {
                    await runFlight(filed)
                    if redactAfterScan {
                        redactAfterScan = false
                        if let document = store.documents.first(where: { $0.id == filed.id }) {
                            redactTarget = document
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingNewFolder) {
            FolderEditorSheet()
        }
        .sheet(item: $redactTarget) { document in
            DocumentRedactionView(document: document)
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView()
                .environment(subscriptions)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(store)
        }
        .photosPicker(
            isPresented: $isImportingPhotos,
            selection: $photoSelection,
            maxSelectionCount: 12,
            matching: .images
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .task { await store.bootstrap() }
        .task { handleDeepLinks() }
        .onChange(of: router.pendingLink) { _, _ in
            handleDeepLinks()
        }
        .onChange(of: scenePhase) { _, phase in
            // Vault folders re-seal the instant the app leaves the foreground.
            if phase != .active {
                locks.lockAll()
            }
        }
    }

    // MARK: - Deep links

    /// Routes links raised by widgets, quick actions, Siri and URL schemes.
    private func handleDeepLinks() {
        guard let link = router.consume() else { return }
        switch link {
        case .scan:
            startScan()
        case .redact:
            redactAfterScan = true
            startScan()
        case .vault:
            break // The dashboard is already the vault.
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IntelliDoc")
                        .font(Theme.display(.largeTitle))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.textPrimary, Theme.textSecondary],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Text("\(store.documents.count) documents · \(store.totalPages) pages")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 12)
                settingsPill
                proPill
                cloudPill
            }
            ScanLine()
        }
        .padding(.top, 6)
    }

    private var settingsPill: some View {
        Button {
            Haptics.selection()
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(Color.white.opacity(0.05))
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Settings")
    }

    private var proPill: some View {
        Button {
            Haptics.selection()
            isShowingPaywall = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: subscriptions.hasPro ? "checkmark.seal.fill" : "crown.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(subscriptions.hasPro ? "Pro" : "Go Pro")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(subscriptions.hasPro ? Theme.amber : Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(
                    subscriptions.hasPro
                        ? AnyShapeStyle(Theme.amber.opacity(0.16))
                        : AnyShapeStyle(LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom))
                )
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .symbolEffect(.pulse, value: !subscriptions.hasPro)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(subscriptions.hasPro ? "IntelliDoc Pro active" : "Upgrade to Pro")
    }

    private var cloudPill: some View {
        HStack(spacing: 6) {
            Image(systemName: store.cloudEnabled ? "checkmark.icloud.fill" : "iphone.gen3")
                .font(.system(size: 11, weight: .semibold))
            Text(store.cloudEnabled ? "Firebase" : "On device")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(store.cloudEnabled ? Color(hex: "3FB0A0") : Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(Color.white.opacity(0.05))
        }
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Vault lock helpers

    /// Sealed vault folders authenticate on tap; success reveals with a spring.
    private func openFolder(_ folder: AppFolder) {
        Haptics.selection()
        guard locks.isLocked(folder) else {
            path.append(.folder(folder))
            return
        }
        Task {
            if await locks.unlock(folder) {
                Haptics.success()
                withAnimation(Theme.flight) {
                    path.append(.folder(folder))
                }
            } else {
                Haptics.warning()
            }
        }
    }

    /// Toggles the biometric lock from the folder card context menu.
    private func toggleFolderLock(_ folder: AppFolder) {
        var updated = folder
        updated.isBiometricLocked.toggle()
        store.updateFolder(updated)
        if updated.isBiometricLocked {
            locks.lock(updated)
        }
        Haptics.impact(.medium)
    }

    // MARK: - Sections

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Folders", trailing: "\(store.folders.count)")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.folders) { folder in
                    FolderCard(
                        folder: folder,
                        count: store.documentCount(in: folder),
                        isPulsing: pulsingFolderId == folder.id,
                        isLocked: locks.isLocked(folder)
                    ) {
                        openFolder(folder)
                    }
                    .anchorPreference(key: FolderAnchorKey.self, value: .bounds) { anchor in
                        [folder.id: anchor]
                    }
                    .contextMenu {
                        if folder.id != AppFolder.inboxID {
                            Button {
                                toggleFolderLock(folder)
                            } label: {
                                Label(
                                    folder.isBiometricLocked ? "Remove Face ID Lock" : "Lock with Face ID",
                                    systemImage: folder.isBiometricLocked ? "lock.open" : "lock"
                                )
                            }
                            Button(role: .destructive) {
                                store.deleteFolder(folder)
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                }

                NewFolderCard {
                    Haptics.selection()
                    isShowingNewFolder = true
                }
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Recent scans")

            if store.recentDocuments.isEmpty {
                VaultEmptyState(
                    title: "Nothing filed yet",
                    message: "Tap Scan to capture your first page. It lands in the Inbox unless you pick a folder.",
                    symbol: "doc.viewfinder"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(store.recentDocuments) { document in
                        DocumentRow(document: document) {
                            path.append(.document(document))
                        }
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Results", trailing: "\(store.searchResults.count)")

            searchFilterRow

            if store.searchResults.isEmpty {
                VaultEmptyState(
                    title: "No matches",
                    message: "Search covers document titles, tags and the full text read from every scanned page — sealed vault folders stay hidden.",
                    symbol: "text.magnifyingglass"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(store.searchResults) { document in
                        DocumentRow(
                            document: document,
                            showsFolder: true,
                            snippet: store.searchSnippet(for: document)
                        ) {
                            path.append(.document(document))
                        }
                    }
                }
            }
        }
    }

    /// Consolidated filter & sort menu layered on top of the free-text query:
    /// result ordering plus file-type / date-range / smart-category filters.
    private var searchFilterRow: some View {
        @Bindable var bindableStore = store
        return HStack(spacing: 8) {
            Menu {
                // --- Sort results ------------------------------------------------
                Section("Sort results") {
                    ForEach(SearchSort.allCases) { option in
                        Button {
                            Haptics.selection()
                            bindableStore.searchSort = option
                        } label: {
                            if store.searchSort == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                }

                // --- File type ---------------------------------------------------
                Section("File type") {
                    Button {
                        Haptics.selection()
                        bindableStore.searchTypeFilter = nil
                    } label: {
                        if store.searchTypeFilter == nil {
                            Label("All types", systemImage: "checkmark")
                        } else {
                            Text("All types")
                        }
                    }
                    ForEach(store.availableDocTypes, id: \.self) { docType in
                        Button {
                            Haptics.selection()
                            bindableStore.searchTypeFilter = docType
                        } label: {
                            if store.searchTypeFilter == docType {
                                Label(docType, systemImage: "checkmark")
                            } else {
                                Text(docType)
                            }
                        }
                    }
                }

                // --- Date range --------------------------------------------------
                Section("Date") {
                    ForEach(SearchDateFilter.allCases) { filter in
                        Button {
                            Haptics.selection()
                            bindableStore.searchDateFilter = filter
                        } label: {
                            if store.searchDateFilter == filter {
                                Label(filter.label, systemImage: "checkmark")
                            } else {
                                Text(filter.label)
                            }
                        }
                    }
                }

                // --- Smart-routing category ---------------------------------------
                if !store.availableCategories.isEmpty {
                    Section("Category") {
                        Button {
                            Haptics.selection()
                            bindableStore.searchCategoryFilter = nil
                        } label: {
                            if store.searchCategoryFilter == nil {
                                Label("All categories", systemImage: "checkmark")
                            } else {
                                Text("All categories")
                            }
                        }
                        ForEach(store.availableCategories, id: \.self) { category in
                            Button {
                                Haptics.selection()
                                bindableStore.searchCategoryFilter = category
                            } label: {
                                if store.searchCategoryFilter == category {
                                    Label(category, systemImage: "checkmark")
                                } else {
                                    Text(category)
                                }
                            }
                        }
                    }
                }

                if store.activeSearchFilters > 0 {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            bindableStore.searchTypeFilter = nil
                            bindableStore.searchDateFilter = .anyTime
                            bindableStore.searchCategoryFilter = nil
                        } label: {
                            Label("Clear filters", systemImage: "xmark.circle")
                        }
                    }
                }
            } label: {
                filterChip(
                    symbol: "slider.horizontal.3",
                    label: store.activeSearchFilters == 0
                        ? "Filters · \(store.searchSort.label)"
                        : "Filters · \(store.activeSearchFilters)"
                )
            }

            Spacer(minLength: 0)
        }
    }

    private func filterChip(symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.amberBright)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { Capsule().fill(Theme.amber.opacity(0.1)) }
        .overlay { Capsule().strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1) }
    }

    // MARK: - Capture bar

    private var captureBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.impact(.light)
                isImportingPhotos = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 56, height: 56)
                    .background {
                        Circle().fill(Theme.surfaceHigh)
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Import images from Photos")

            Button {
                Haptics.impact()
                startScan()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Scan")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    Capsule().fill(
                        LinearGradient(
                            colors: [Theme.amberBright, Theme.amber],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .shadow(color: Theme.amber.opacity(0.4), radius: 18, y: 8)
            }
            .buttonStyle(PressableStyle(scale: 0.96))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .padding(.top, 12)
        .background {
            LinearGradient(
                colors: [Theme.ink.opacity(0), Theme.ink.opacity(0.92), Theme.ink],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Actions

    private func startScan() {
        scanner.reset()
        if scanner.isDocumentCameraAvailable {
            scanner.beginCapture()
            isShowingCamera = true
        } else {
            isImportingPhotos = true
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoSelection = []
        guard !images.isEmpty else { return }
        scanner.load(images, source: .photoImport)
        isShowingReview = true
    }

    private func targetPoint(
        for folderId: String,
        anchors: [String: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> CGPoint {
        guard let anchor = anchors[folderId] else {
            return CGPoint(x: proxy.size.width / 2, y: 120)
        }
        let rect = proxy[anchor]
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Plays the "document flies into its folder" transition, then settles the
    /// folder card with a pulse.
    private func runFlight(_ filed: FiledScan) async {
        try? await Task.sleep(for: .milliseconds(360))
        flightLanded = false
        flight = filed

        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : Theme.flight) {
            flightLanded = true
        }

        try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 520))
        Haptics.success()
        withAnimation(Theme.snap) { pulsingFolderId = filed.folderId }

        try? await Task.sleep(for: .milliseconds(180))
        flight = nil

        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(Theme.soft) { pulsingFolderId = nil }
        scanner.reset()
    }
}

// MARK: - Navigation

enum VaultRoute: Hashable {
    case folder(AppFolder)
    case document(ScannedDocument)
}

// MARK: - Animated scan line

private struct ScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(height: 2)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Theme.amber, Theme.amberBright, Theme.amber, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.42, height: 2)
                    .offset(x: sweep ? proxy.size.width * 0.58 : -proxy.size.width * 0.06)
                    .shadow(color: Theme.amber.opacity(0.7), radius: 6)
                    .opacity(reduceMotion ? 0.5 : 1)
            }
            .frame(height: 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    sweep = true
                }
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Flight overlay

private struct FlightOverlay: View {
    let scan: FiledScan
    let landed: Bool
    let reduceMotion: Bool
    let target: CGPoint
    let origin: CGPoint

    var body: some View {
        PageThumbnail(
            image: scan.thumbnail,
            pageCount: scan.pageCount,
            width: 116,
            cornerRadius: 14
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.amber.opacity(landed ? 0 : 0.8), lineWidth: 2)
                .blur(radius: 1)
                .frame(width: 116, height: 153)
        }
        .scaleEffect(landed ? (reduceMotion ? 1 : 0.16) : 1)
        .rotationEffect(.degrees(landed && !reduceMotion ? -14 : 0))
        .opacity(landed ? 0 : 1)
        .position(landed && !reduceMotion ? target : origin)
        .shadow(color: Theme.amber.opacity(0.35), radius: 30)
    }
}

// MARK: - Preview

#Preview("Dashboard") {
    MainDashboardView()
        .environment(VaultStore.mock())
        .environment(ScannerManager())
        .preferredColorScheme(.dark)
}

#Preview("Empty vault") {
    MainDashboardView()
        .environment(VaultStore.mock(documents: []))
        .environment(ScannerManager())
        .preferredColorScheme(.dark)
}
