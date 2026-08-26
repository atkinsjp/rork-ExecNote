//
//  WelcomePage.swift
//  IntelliDoc
//

import UIKit

/// Draws the single-page "Welcome to IntelliDoc" sheet that seeds a brand-new
/// vault. It is a genuine rendered page, so it flows through the same PDF,
/// thumbnail and PDFKit pipeline as a real scan.
nonisolated enum WelcomePage {
    static func render() -> UIImage {
        let size = CGSize(width: 1_224, height: 1_584)

        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext

            UIColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            UIColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 26))

            let title = "IntelliDoc"
            title.draw(
                at: CGPoint(x: 120, y: 170),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 92, weight: .bold),
                    .foregroundColor: UIColor(white: 0.08, alpha: 1),
                ]
            )

            "Your paper, filed and safe.".draw(
                at: CGPoint(x: 124, y: 292),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 40, weight: .regular),
                    .foregroundColor: UIColor(white: 0.42, alpha: 1),
                ]
            )

            UIColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1).setFill()
            cg.fill(CGRect(x: 124, y: 380, width: 180, height: 6))

            let steps: [(String, String)] = [
                ("01", "Tap the amber Scan button and let the camera find the page edges."),
                ("02", "Reorder, rotate or drop pages in the review carousel."),
                ("03", "Name the scan and choose the folder it should fly into."),
                ("04", "Every page is read on device, so search finds words inside your scans."),
                ("05", "Lock sensitive folders behind Face ID from the folder menu."),
            ]

            var y: CGFloat = 470
            for (index, step) in steps {
                index.draw(
                    at: CGPoint(x: 124, y: y),
                    withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold),
                        .foregroundColor: UIColor(red: 0.78, green: 0.53, blue: 0.17, alpha: 1),
                    ]
                )
                step.draw(
                    with: CGRect(x: 216, y: y - 4, width: size.width - 340, height: 160),
                    options: [.usesLineFragmentOrigin],
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 34, weight: .regular),
                        .foregroundColor: UIColor(white: 0.18, alpha: 1),
                    ],
                    context: nil
                )
                y += 150
            }

            UIColor(white: 0.82, alpha: 1).setFill()
            cg.fill(CGRect(x: 124, y: size.height - 220, width: size.width - 248, height: 2))

            "Delete this page whenever you like — swipe it away from any list."
                .draw(
                    at: CGPoint(x: 124, y: size.height - 180),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                        .foregroundColor: UIColor(white: 0.55, alpha: 1),
                    ]
                )
        }
    }
}
