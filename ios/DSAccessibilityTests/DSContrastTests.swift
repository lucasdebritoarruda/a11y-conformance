//
//  DSContrastTests.swift
//  Verifica a razão de contraste WCAG de cada par de cores declarado no adapter,
//  em cada aparência suportada (claro, escuro, alto contraste).
//

import UIKit
import XCTest

final class DSContrastTests: XCTestCase {

    func testColorPairsMeetMinimumContrast() {
        let pairs = A11yDSAdapter.colorPairs
        guard !pairs.isEmpty else {
            return XCTFail("Preencha A11yDSAdapter.colorPairs")
        }

        let report = A11yReport(suite: "contraste")

        for appearance in A11yAppearance.all(includeDark: A11yDSAdapter.supportsDarkMode) {
            for pair in pairs {
                let foreground = a11yResolved(pair.foreground, for: appearance.traits)
                let background = a11yResolved(pair.background, for: appearance.traits)

                guard let backgroundAlpha = A11yContrast.alpha(of: background), backgroundAlpha >= 0.999 else {
                    report.check(false, subject: pair.name, criterion: appearance.name,
                                 detail: "fundo semitransparente ou não convertível para RGB: declare o fundo opaco real")
                    continue
                }
                guard let flat = A11yContrast.flatten(foreground, over: background),
                      let ratio = A11yContrast.ratio(flat, background) else {
                    report.check(false, subject: pair.name, criterion: appearance.name,
                                 detail: "cor não convertível para RGB (pattern image?)")
                    continue
                }

                report.check(ratio >= pair.minimum, subject: pair.name, criterion: appearance.name,
                             detail: String(format: "%.2f:1 (mínimo %.1f:1)", ratio, pair.minimum))
            }
        }

        report.write()
    }
}
