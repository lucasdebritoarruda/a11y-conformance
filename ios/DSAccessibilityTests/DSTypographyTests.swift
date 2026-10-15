//
//  DSTypographyTests.swift
//  Verifica se cada token de tipografia acompanha o Dynamic Type:
//  cresce em todas as categorias e chega à escala mínima no maior tamanho.
//

import UIKit
import XCTest

final class DSTypographyTests: XCTestCase {

    func testTokensScaleWithDynamicType() {
        let tokens = A11yDSAdapter.typographyTokens
        guard !tokens.isEmpty else {
            return XCTFail("Preencha A11yDSAdapter.typographyTokens")
        }

        let report = A11yReport(suite: "tipografia")

        for token in tokens {
            let sizes: [CGFloat] = A11yContentSize.ordered.map {
                token.makeFont(UITraitCollection(preferredContentSizeCategory: $0)).pointSize
            }
            let base = token.makeFont(UITraitCollection(preferredContentSizeCategory: A11yContentSize.standard)).pointSize
            let largest = sizes.last ?? base
            let scale = base > 0 ? largest / base : 0

            let monotonic = zip(sizes, sizes.dropFirst()).allSatisfy { $0.0 <= $0.1 }
            report.check(monotonic, subject: token.name, criterion: "cresce em todas as categorias",
                         detail: sizes.map { String(format: "%.0f", $0) }.joined(separator: " → "))

            report.check(scale >= token.minimumScale, subject: token.name, criterion: "escala mínima",
                         detail: String(format: "%.0fpt → %.0fpt (%.2fx; mínimo %.1fx)",
                                        base, largest, scale, token.minimumScale))
        }

        report.write()
    }
}
