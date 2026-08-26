//
//  ScanVaultWidgetBundle.swift
//  ScanVaultWidget
//

import SwiftUI
import WidgetKit

@main
struct ScanVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickScanWidget()
        VaultAccessoryWidget()
        ScanUploadActivity()
    }
}
