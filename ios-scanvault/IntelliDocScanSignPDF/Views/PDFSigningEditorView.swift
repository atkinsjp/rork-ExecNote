//
//  PDFSigningEditorView.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UIKit

// MARK: - Runtime placement model

/// A stamp being positioned in the editor, wrapping the persisted placement
/// payload with a stable UI identity.
struct PlacedStamp: Identifiable {
    let id = UUID()
    var data: PlacementData
}

// MARK: - Dynamic stamps (date badge & sign-here flag)

/// Renders kit items that are generated at runtime rather than drawn.
enum StampFactory {
    /// "August 26, 2026" text with an amber underline — burned in like ink.
    static func dateStampPNG(date: Date = .now) -> Data? {
        let size = CGSize(width: 640, height: 170)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { context in
            let text = date.formatted(date: .long, time: .omitted)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .semibold),
                .foregroundColor: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
            ]
            let bounds = (text as NSString).size(withAttributes: attributes)
            let origin = CGPoint(x: (size.width - bounds.width) / 2, y: 26)
            (text as NSString).draw(at: origin, withAttributes: attributes)

            UIColor(Color(hex: "E8A33D")).setFill()
            let rule = CGRect(
                x: (size.width - bounds.width) / 2,
                y: origin.y + bounds.height + 18,
                width: bounds.width,
                height: 6
            )
            UIBezierPath(roundedRect: rule, cornerRadius: 3).fill()
            _ = context
        }
        return image.pngData()
    }

    /// Amber "Sign Here" sticky flag with an arrow.
    static func signHerePNG() -> Data? {
        let size = CGSize(width: 560, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { _ in
            let amber = UIColor(Color(hex: "E8A33D"))
            let ink = UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)

            // Flag card.
            let card = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
            let path = UIBezierPath(roundedRect: card, cornerRadius: 26)
            amber.setFill()
            path.fill()

            // Downward arrow tail.
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: size.width / 2 - 22, y: card.maxY - 4))
            arrow.addLine(to: CGPoint(x: size.width / 2 + 22, y: card.maxY - 4))
            arrow.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            arrow.close()
            amber.setFill()
            arrow.fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 58, weight: .bold),
                .foregroundColor: ink,
            ]
            let text = "SIGN HERE"
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2 - 10),
                withAttributes: attributes
            )
        }
        return image.pngData()
    }
}

// MARK: - Editor

/// Multi-page signing canvas: drag or tap stamps from the Signature Kit onto
/// any page, then flatten everything into a cryptographically stamped PDF.
struct PDFSigningEditorView: View {
    @Environment(VaultStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    @State private var pages: [UIImage] = []
    @State private var profiles: [SignatureProfile] = []
    @State private var placements: [PlacedStamp] = []
    @State private var imagesById: [UUID: UIImage] = [:]
    @State private var selectedStampId: UUID?
    @State private var armedProfileId: UUID?
    @State private var confirmStampId: UUID?
    /// Maps a signature stamp to the auto-date stamp placed with it, so
    /// removing the signature in the confirmation step takes the date along.
    @State private var dateCompanions: [UUID: UUID] = [:]
    @State private var isLoading = true
    @State private var isDrawingNew = false
    @State private var isManagingKit = false
    @State private var isConfirmingFinalize = false
    @State private var isFinalizing = false
    @State private var didFinalize = false
    @State private var includeAuditPage = true
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var isShowingPaywall = false

    @AppStorage("signerName") private var signerName = ""
    @AppStorage("signerEmail") private var signerEmail = ""
    /// When on, every placed signature or initials stamp is accompanied by a
    /// current-date stamp just below it.
    @AppStorage("signingAutoDate") private var autoDateOn = true

    private var live: ScannedDocument {
        store.documents.first { $0.id == document.id } ?? document
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                VStack(spacing: 0) {
                    if isLoading {
                        loadingState
                    } else if pages.isEmpty {
                        VaultEmptyState(
                            title: "PDF not on this device",
                            message: "The pages could not be loaded for signing.",
                            symbol: "doc.badge.ellipsis"
                        )
                    } else {
                        pagesScroller
                        if confirmStamp != nil {
                            placementConfirmationCard
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        kitBar
                    }
                }
                .animation(Theme.snap, value: confirmStampId)

                if isFinalizing {
                    finalizeOverlay
                }
                if didFinalize {
                    successOverlay
                }
            }
            .navigationTitle("Sign & Finalize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !placements.isEmpty {
                        Text("\(placements.count) placed")
                            .font(Theme.mono(.caption, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }
                }
            }
            .sheet(isPresented: $isDrawingNew) {
                SignatureCanvasSheet { profile in
                    addProfile(profile)
                }
            }
            .sheet(isPresented: $isManagingKit, onDismiss: {
                Task { await reloadSavedProfiles() }
            }) {
                SignatureManagerView()
                    .environment(subscriptions)
            }
            .sheet(isPresented: $isConfirmingFinalize) {
                FinalizeSummarySheet(
                    documentTitle: live.title,
                    placements: placements,
                    imagesById: imagesById,
                    auditTrailUnlocked: subscriptions.hasAccess(to: .signatureKitAndAudit),
                    signerName: $signerName,
                    signerEmail: $signerEmail,
                    includeAuditPage: $includeAuditPage
                ) {
                    isConfirmingFinalize = false
                    Task { await finalize() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView()
                    .environment(subscriptions)
            }
            .task { await load() }
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.amber)
            Text("Unrolling \(live.title)…")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pages

    private var pagesScroller: some View {
        ScrollView {
            VStack(spacing: 26) {
                ForEach(pages.indices, id: \.self) { pageIndex in
                    pageCanvas(pageIndex)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .scaleEffect(zoom)
            .animation(Theme.snap, value: zoom)
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = min(2.5, max(1, pinchBase * value.magnification))
                }
                .onEnded { _ in pinchBase = zoom }
        )
        .onTapGesture(count: 2) {
            withAnimation(Theme.snap) {
                zoom = zoom > 1.02 ? 1 : 1.6
                pinchBase = zoom
            }
        }
    }

    private func pageCanvas(_ pageIndex: Int) -> some View {
        PageSigningCanvas(
            pageIndex: pageIndex,
            image: pages[pageIndex],
            stamps: placements.filter { $0.data.pageIndex == pageIndex },
            imagesById: imagesById,
            zoom: zoom,
            isArmed: armedProfileId != nil,
            armedProfileId: armedProfileId,
            selectedStampId: $selectedStampId,
            onPlace: { profileId, point in
                place(profileId: profileId, pageIndex: pageIndex, at: point)
            },
            onMove: { stampId, delta, pageSize in
                move(stampId: stampId, delta: delta, pageSize: pageSize)
            },
            onResize: { stampId, factor in
                resize(stampId: stampId, factor: factor)
            },
            onRotate: { stampId, degrees in
                rotate(stampId: stampId, degrees: degrees)
            },
            onDelete: { stampId in
                delete(stampId: stampId)
            }
        )
    }

    // MARK: - Signature Kit bar

    private var kitBar: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SIGNATURE KIT")
                    .font(Theme.mono(.caption, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    autoDateOn.toggle()
                    Haptics.selection()
                } label: {
                    Label("Auto-date", systemImage: autoDateOn ? "calendar.badge.checkmark" : "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(autoDateOn ? Theme.amber : Theme.textTertiary)
                }
                .accessibilityLabel(autoDateOn ? "Auto-date is on — today's date is added under each signature" : "Auto-date is off")
                Button {
                    Haptics.selection()
                    isManagingKit = true
                } label: {
                    Label("Manage", systemImage: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    isDrawingNew = true
                    armedProfileId = nil
                } label: {
                    Label("Draw New", systemImage: "pencil.tip.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(profiles) { profile in
                        KitChip(
                            profile: profile,
                            image: imagesById[profile.id],
                            isArmed: armedProfileId == profile.id
                        ) {
                            toggleArm(profile)
                        }
                        .draggable(profile.id.uuidString)
                    }
                }
                .padding(.vertical, 2)
            }

            if armedProfileId != nil {
                Text("Tap any page to drop the stamp — or drag a chip onto the page.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.amberBright)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                Haptics.impact()
                isConfirmingFinalize = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                    Text(placements.isEmpty
                         ? "Place a stamp to sign"
                         : "Sign & Finalize · \(placements.count) stamp\(placements.count == 1 ? "" : "s")")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(placements.isEmpty ? Theme.textTertiary : Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: placements.isEmpty
                                    ? [Theme.surfaceHigh, Theme.surface]
                                    : [Theme.amberBright, Theme.amber],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(placements.isEmpty)
            .animation(Theme.snap, value: placements.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(Theme.snap, value: armedProfileId)
    }

    // MARK: - Overlays

    private var finalizeOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.amber.opacity(0.25), lineWidth: 3)
                        .frame(width: 84, height: 84)
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.amber)
                }
                Text("Stamping, hashing & syncing…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("SHA-256 audit trail is being sealed on-device.")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(30)
            .cardSurface(cornerRadius: 24)
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Color(hex: "3FB0A0"))
                    .symbolEffect(.bounce, value: didFinalize)
                Text("Document signed")
                    .font(Theme.display(.title3))
                    .foregroundStyle(Theme.textPrimary)
                Text("Signatures burned in · audit trail sealed")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(30)
            .cardSurface(cornerRadius: 24)
            .padding(.horizontal, 40)
        }
        .task {
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        }
        .transition(.opacity)
    }

    // MARK: - Data loading

    private func load() async {
        var sourceURL: URL? = live.localURL
        if sourceURL == nil {
            sourceURL = await PDFManager.shared.existingURL(documentId: live.id)
        }
        guard let sourceURL else {
            isLoading = false
            return
        }

        async let renderedPages = PDFSignerService.shared.pageImages(for: sourceURL)
        async let savedProfiles = SignatureStorageService.shared.loadProfiles()

        pages = await renderedPages

        var kit = await savedProfiles
        // Session-only dynamic stamps.
        if let datePNG = StampFactory.dateStampPNG() {
            kit.append(SignatureProfile(
                id: StampFactory.dateStampID,
                title: Date.now.formatted(date: .abbreviated, time: .omitted),
                type: .dateStamp,
                pngData: datePNG
            ))
        }
        if let flagPNG = StampFactory.signHerePNG() {
            kit.append(SignatureProfile(
                id: StampFactory.flagID,
                title: "Sign Here flag",
                type: .customText,
                pngData: flagPNG
            ))
        }
        profiles = kit
        rebuildImageCache()
        isLoading = false
    }

    /// Re-syncs saved profiles after the Signature Manager closes, keeping
    /// the session-only dynamic stamps at the end of the kit.
    private func reloadSavedProfiles() async {
        let saved = await SignatureStorageService.shared.loadProfiles()
        let session = profiles.filter {
            $0.id == StampFactory.dateStampID || $0.id == StampFactory.flagID
        }
        profiles = saved + session
        rebuildImageCache()

        // A deleted profile can no longer be armed for placement.
        if let armed = armedProfileId, !profiles.contains(where: { $0.id == armed }) {
            armedProfileId = nil
        }
    }

    private func rebuildImageCache() {
        var cache: [UUID: UIImage] = [:]
        for profile in profiles {
            if let image = UIImage(data: profile.pngData) {
                cache[profile.id] = image
            }
        }
        imagesById = cache
    }

    private func addProfile(_ profile: SignatureProfile) {
        // The multi-profile signature kit is a Pro capability.
        let savedCount = profiles.filter {
            $0.id != StampFactory.dateStampID && $0.id != StampFactory.flagID
        }.count
        if let allowance = subscriptions.signatureProfileAllowance, savedCount >= allowance {
            Haptics.warning()
            isShowingPaywall = true
            return
        }

        Task {
            try? await SignatureStorageService.shared.save(profile)
            profiles.insert(profile, at: 0)
            rebuildImageCache()
            armedProfileId = profile.id
            Haptics.success()
        }
    }

    // MARK: - Placement mutations

    private func toggleArm(_ profile: SignatureProfile) {
        Haptics.selection()
        armedProfileId = armedProfileId == profile.id ? nil : profile.id
    }

    /// Drops `profileId` centered on `point` (page-local points) with a spring.
    private func place(profileId: UUID, pageIndex: Int, at point: CGPoint) {
        guard let image = imagesById[profileId],
              let profile = profiles.first(where: { $0.id == profileId }),
              pageIndex < pages.count
        else { return }

        let pageSize = pages[pageIndex].size
        let normalized = CGPoint(x: point.x / pageSize.width, y: point.y / pageSize.height)

        // Default footprint: 30% of the page width, aspect-correct.
        let stampAspect = image.size.width / max(image.size.height, 1)
        let pageAspect = pageSize.width / pageSize.height
        let widthNorm: CGFloat = profile.type == .initials ? 0.12 : 0.30
        let heightNorm = widthNorm * pageAspect / stampAspect

        let rect = CGRect(
            x: normalized.x - widthNorm / 2,
            y: normalized.y - heightNorm / 2,
            width: widthNorm,
            height: heightNorm
        ).clampedToPage

        let stamp = PlacedStamp(data: PlacementData(
            pageIndex: pageIndex,
            rect: rect,
            profileId: profileId,
            profileTitle: profile.title
        ))

        withAnimation(Theme.flight) {
            placements.append(stamp)
            selectedStampId = stamp.id
        }

        if autoDateOn, profile.type == .signature || profile.type == .initials {
            dateCompanions[stamp.id] = appendAutoDate(below: rect, pageIndex: pageIndex)
        }

        // Every placement lands in the confirmation step first — the user
        // adjusts or removes it before moving on.
        confirmStampId = stamp.id

        Haptics.impact(.medium)
        // Tap-to-place is single-shot; dragging can continue from the kit.
        if armedProfileId == profileId { armedProfileId = nil }
    }

    /// Drops the session date stamp centered just below a freshly placed
    /// signature. It stays a regular, movable stamp the user can adjust.
    /// Returns the new stamp's id so it can travel with its signature.
    @discardableResult
    private func appendAutoDate(below signatureRect: CGRect, pageIndex: Int) -> UUID? {
        guard let dateImage = imagesById[StampFactory.dateStampID],
              pageIndex < pages.count
        else { return nil }

        let pageSize = pages[pageIndex].size
        let pageAspect = pageSize.width / pageSize.height
        let stampAspect = dateImage.size.width / max(dateImage.size.height, 1)

        // Scale with the signature so a small initial gets a small date.
        let widthNorm = min(0.22, max(0.10, signatureRect.width * 0.6))
        let heightNorm = widthNorm * pageAspect / stampAspect
        let rect = CGRect(
            x: signatureRect.midX - widthNorm / 2,
            y: signatureRect.maxY + 0.008,
            width: widthNorm,
            height: heightNorm
        ).clampedToPage

        let title = profiles.first(where: { $0.id == StampFactory.dateStampID })?.title
            ?? Date.now.formatted(date: .abbreviated, time: .omitted)
        let stamp = PlacedStamp(data: PlacementData(
            pageIndex: pageIndex,
            rect: rect,
            profileId: StampFactory.dateStampID,
            profileTitle: title
        ))

        withAnimation(Theme.flight) {
            placements.append(stamp)
        }
        return stamp.id
    }

    // MARK: - Placement confirmation

    private var confirmStamp: PlacedStamp? {
        guard let id = confirmStampId else { return nil }
        return placements.first { $0.id == id }
    }

    /// Floating card shown after each placement: keep adjusting, remove, or
    /// confirm the stamp's position.
    private var placementConfirmationCard: some View {
        HStack(spacing: 12) {
            if let stamp = confirmStamp, let image = imagesById[stamp.data.profileId] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 30)
                    .padding(5)
                    .background { RoundedRectangle(cornerRadius: 8).fill(Theme.paper) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Confirm placement")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Drag, pinch or rotate the stamp — then lock it in.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                removeConfirmedStamp()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "E2664F"))
                    .frame(width: 38, height: 38)
                    .background { Circle().fill(Theme.surfaceHigh) }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Remove stamp")

            Button {
                confirmPlacement()
            } label: {
                Text("Looks Good")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1206"))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background { Capsule().fill(Theme.amber) }
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .accessibilityLabel("Confirm stamp placement")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func confirmPlacement() {
        guard confirmStampId != nil else { return }
        withAnimation(Theme.snap) {
            confirmStampId = nil
            selectedStampId = nil
        }
        Haptics.success()
    }

    private func removeConfirmedStamp() {
        guard let id = confirmStampId else { return }
        withAnimation(Theme.snap) {
            placements.removeAll { $0.id == id || $0.id == dateCompanions[id] }
            if selectedStampId == id { selectedStampId = nil }
            confirmStampId = nil
        }
        dateCompanions[id] = nil
        Haptics.warning()
    }

    private func move(stampId: UUID, delta: CGSize, pageSize: CGSize) {
        guard let index = placements.firstIndex(where: { $0.id == stampId }) else { return }
        var rect = placements[index].data.rect
        rect.origin.x += delta.width / pageSize.width
        rect.origin.y += delta.height / pageSize.height
        placements[index].data.rect = rect.clampedToPage
    }

    private func resize(stampId: UUID, factor: CGFloat) {
        guard let index = placements.firstIndex(where: { $0.id == stampId }) else { return }
        var rect = placements[index].data.rect
        let clamped = min(1.15, max(0.05, rect.width * factor)) / rect.width
        rect.size.width *= clamped
        rect.size.height *= clamped
        placements[index].data.rect = rect.clampedToPage
    }

    private func rotate(stampId: UUID, degrees: Double) {
        guard let index = placements.firstIndex(where: { $0.id == stampId }) else { return }
        placements[index].data.rotationDegrees += degrees
    }

    private func delete(stampId: UUID) {
        guard let index = placements.firstIndex(where: { $0.id == stampId }) else { return }
        withAnimation(Theme.snap) {
            _ = placements.remove(at: index)
            if selectedStampId == stampId { selectedStampId = nil }
            if confirmStampId == stampId { confirmStampId = nil }
        }
        // Keep companion bookkeeping in sync whichever half is deleted.
        dateCompanions[stampId] = nil
        if let owner = dateCompanions.first(where: { $0.value == stampId })?.key {
            dateCompanions[owner] = nil
        }
        Haptics.warning()
    }

    // MARK: - Finalize

    private func finalize() async {
        guard !placements.isEmpty, !isFinalizing else { return }
        isFinalizing = true
        selectedStampId = nil
        confirmStampId = nil

        let name = signerName.trimmingCharacters(in: .whitespaces)
        let email = signerEmail.trimmingCharacters(in: .whitespaces)

        let success = await store.finalizeSignature(
            for: live,
            placements: placements.map(\.data),
            profiles: profiles,
            signerName: name.isEmpty ? "IntelliDoc User" : name,
            signerEmail: email.isEmpty ? "on-device@scanvault" : email,
            includeAuditPage: includeAuditPage
        )

        isFinalizing = false
        if success {
            Haptics.success()
            withAnimation(Theme.soft) { didFinalize = true }
        }
    }
}

extension StampFactory {
    /// Stable session IDs for the generated kit items.
    static let dateStampID = UUID()
    static let flagID = UUID()
}

nonisolated extension CGRect {
    /// Keeps a stamp fully on the page while dragging — a stamp hanging over
    /// the edge is easy to miss and would burn half outside the PDF page.
    var clampedToPage: CGRect {
        let margin: CGFloat = 0.015
        return CGRect(
            x: min(max(origin.x, margin), 1 - width - margin),
            y: min(max(origin.y, margin), 1 - height - margin),
            width: width,
            height: height
        )
    }
}

// MARK: - Page canvas

/// A single page with its stamps, supporting tap-to-place, drag-and-drop and
/// direct manipulation of each stamp.
private struct PageSigningCanvas: View {
    let pageIndex: Int
    let image: UIImage
    let stamps: [PlacedStamp]
    let imagesById: [UUID: UIImage]
    let zoom: CGFloat
    let isArmed: Bool
    var armedProfileId: UUID?
    @Binding var selectedStampId: UUID?

    let onPlace: (UUID, CGPoint) -> Void
    let onMove: (UUID, CGSize, CGSize) -> Void
    let onResize: (UUID, CGFloat) -> Void
    let onRotate: (UUID, Double) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.18))

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 7)

                ForEach(stamps) { stamp in
                    if let stampImage = imagesById[stamp.data.profileId] {
                        StampOverlay(
                            stamp: stamp,
                            image: stampImage,
                            zoom: zoom,
                            pageSize: geo.size,
                            isSelected: selectedStampId == stamp.id,
                            onSelect: {
                                withAnimation(Theme.snap) {
                                    selectedStampId = selectedStampId == stamp.id ? nil : stamp.id
                                }
                            },
                            onMove: { onMove(stamp.id, $0, geo.size) },
                            onResize: { onResize(stamp.id, $0) },
                            onRotate: { onRotate(stamp.id, $0) },
                            onDelete: { onDelete(stamp.id) }
                        )
                    }
                }

                if isArmed {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let armed = armedProfileId {
                    onPlace(armed, location)
                } else {
                    selectedStampId = nil
                }
            }
            .dropDestination(for: String.self) { items, point in
                guard let idText = items.first,
                      let profileId = UUID(uuidString: idText)
                else { return false }
                onPlace(profileId, point)
                return true
            }
        }
        .aspectRatio(image.size, contentMode: .fit)
    }
}

// MARK: - Stamp overlay

/// A placed stamp with drag-to-move, pinch-to-resize, rotate and delete handles.
private struct StampOverlay: View {
    let stamp: PlacedStamp
    let image: UIImage
    let zoom: CGFloat
    let pageSize: CGSize
    let isSelected: Bool

    let onSelect: () -> Void
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onRotate: (Double) -> Void
    let onDelete: () -> Void

    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnify: CGFloat = 1
    @State private var lastRotation: Angle = .zero

    private var frame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: stamp.data.rect.width * pageSize.width,
            height: stamp.data.rect.height * pageSize.height
        )
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: frame.width, height: frame.height)
            .rotationEffect(.degrees(stamp.data.rotationDegrees))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    deleteHandle
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .gesture(manipulationGestures)
            .position(
                x: stamp.data.rect.midX * pageSize.width,
                y: stamp.data.rect.midY * pageSize.height
            )
            .animation(Theme.snap, value: isSelected)
    }

    private var deleteHandle: some View {
        Button {
            onDelete()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 24, height: 24)
                .background { Circle().fill(Theme.amber) }
                .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .offset(x: 15, y: -15)
        .accessibilityLabel("Remove \(stamp.data.profileTitle)")
    }

    /// Drag moves, pinch resizes, twist rotates — all at once if needed.
    /// Translations are divided by the canvas zoom so movement tracks the
    /// finger at any magnification.
    private var manipulationGestures: some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let delta = CGSize(
                    width: (value.translation.width - lastDrag.width) / zoom,
                    height: (value.translation.height - lastDrag.height) / zoom
                )
                lastDrag = value.translation
                onMove(delta)
            }
            .onEnded { _ in lastDrag = .zero }

        let magnify = MagnifyGesture()
            .onChanged { value in
                onResize(value.magnification / lastMagnify)
                lastMagnify = value.magnification
            }
            .onEnded { _ in lastMagnify = 1 }

        let rotate = RotateGesture()
            .onChanged { value in
                onRotate(value.rotation.degrees - lastRotation.degrees)
                lastRotation = value.rotation
            }
            .onEnded { _ in lastRotation = .zero }

        return drag
            .simultaneously(with: magnify.simultaneously(with: rotate))
    }
}

// MARK: - Kit chip

private struct KitChip: View {
    let profile: SignatureProfile
    let image: UIImage?
    var isArmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else {
                        Image(systemName: profile.type.symbolName)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 86, height: 52)

                Text(profile.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isArmed ? Theme.amberBright : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(width: 98)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isArmed ? Theme.amber.opacity(0.12) : Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isArmed ? Theme.amber : Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(profile.title), \(profile.type.label)")
    }
}

// MARK: - Finalize confirmation

/// Audit summary shown before the document is flattened and hashed.
private struct FinalizeSummarySheet: View {
    let documentTitle: String
    let placements: [PlacedStamp]
    let imagesById: [UUID: UIImage]
    var auditTrailUnlocked: Bool = true

    @Binding var signerName: String
    @Binding var signerEmail: String
    @Binding var includeAuditPage: Bool

    let onFinalize: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var uniquePages: Int {
        Set(placements.map(\.data.pageIndex)).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        signerFields
                        placementSummary
                        auditToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Confirm & Seal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                if !auditTrailUnlocked {
                    includeAuditPage = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(documentTitle, systemImage: "doc.text.fill")
                .font(Theme.display(.headline))
                .foregroundStyle(Theme.textPrimary)
            Text("\(placements.count) stamp\(placements.count == 1 ? "" : "s") across \(uniquePages) page\(uniquePages == 1 ? "" : "s")")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var signerFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SIGNER OF RECORD")
                .font(Theme.mono(.caption, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)

            TextField("Full name", text: $signerName)
                .textContentType(.name)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background { RoundedRectangle(cornerRadius: 12).fill(Theme.surface) }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1) }

            TextField("email@example.com", text: $signerEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background { RoundedRectangle(cornerRadius: 12).fill(Theme.surface) }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1) }
        }
    }

    private var placementSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLACED STAMPS")
                .font(Theme.mono(.caption, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)

            ForEach(placements) { stamp in
                HStack(spacing: 12) {
                    if let image = imagesById[stamp.data.profileId] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 54, height: 30)
                            .padding(5)
                            .background { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.92)) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stamp.data.profileTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Page \(stamp.data.pageIndex + 1)")
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: "3FB0A0"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 12).fill(Theme.surface) }
            }
        }
    }

    private var auditToggle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $includeAuditPage) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Attach Certificate of Completion")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if !auditTrailUnlocked {
                            Text("PRO")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color(hex: "1A1206"))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(Theme.amber) }
                        }
                    }
                    Text(auditTrailUnlocked
                         ? "A signed audit page is appended with the SHA-256 verification hash, timestamps, device and stamp previews."
                         : "Unlock Pro to seal the SHA-256 audit trail page into the document.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.amber)
            .disabled(!auditTrailUnlocked)
            .padding(14)
            .background { RoundedRectangle(cornerRadius: 14).fill(Theme.surface) }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1) }

            Button {
                Haptics.impact()
                onFinalize()
            } label: {
                Label("Stamp, Hash & Sync", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        Capsule().fill(LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .leading, endPoint: .trailing))
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.top, 4)

            Text("Signatures are burned into the page pixels — they can never be moved or extracted from the exported PDF.")
                .font(Theme.mono(.caption2))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 10)
        }
    }
}

#Preview {
    PDFSigningEditorView(document: ScannedDocument.mockList[4])
        .environment(VaultStore.mock())
        .preferredColorScheme(.dark)
}
