//
//  DSComponentContractTests.swift
//  Verifica o contrato de acessibilidade de cada componente declarado no adapter:
//  elemento acessível, label, traits, área de toque, estados anunciados e
//  comportamento com Dynamic Type (flag, crescimento da fonte e texto cortado).
//
//  Rode num target de unit test HOSPEDADO pelo app de catálogo do DS (Host Application),
//  para que janela, traits e Dynamic Type se comportem como no app real.
//

import UIKit
import XCTest

final class DSComponentContractTests: XCTestCase {

    func testComponentsAccessibilityContract() {
        let specs = A11yDSAdapter.components
        guard !specs.isEmpty else {
            return XCTFail("Preencha A11yDSAdapter.components")
        }

        let report = A11yReport(suite: "componentes")

        for spec in specs {
            XCTContext.runActivity(named: spec.name) { _ in
                checkSemantics(spec, report)
                checkStates(spec, report)
                checkDynamicType(spec, report)
            }
        }

        report.write()
    }

    // MARK: - Semântica: elemento, label, traits, área de toque

    private func checkSemantics(_ spec: A11yComponentSpec, _ report: A11yReport) {
        let host = A11yHost(spec.make(), category: A11yContentSize.standard, layout: spec.layout)
        let element = spec.element(host.view)

        if spec.isSingleElement {
            report.check(element.isAccessibilityElement, subject: spec.name, criterion: "elemento acessível",
                         detail: element.isAccessibilityElement
                            ? "ok"
                            : "isAccessibilityElement = false: o VoiceOver não foca o componente")
        } else {
            let accessible = a11yAllViews(host.view).filter {
                $0.isAccessibilityElement && a11yIsVisible($0, within: host.view)
            }
            report.check(!accessible.isEmpty, subject: spec.name, criterion: "elemento acessível",
                         detail: "\(accessible.count) elemento(s) acessível(is) interno(s)")
        }

        if spec.requiresLabel {
            let label = (element.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            report.check(!label.isEmpty, subject: spec.name, criterion: "label",
                         detail: label.isEmpty ? "accessibilityLabel vazio" : "\"\(label)\"")
        }

        if !spec.expectedTraits.isEmpty {
            let traits = element.accessibilityTraits
            report.check(traits.isSuperset(of: spec.expectedTraits), subject: spec.name, criterion: "traits",
                         detail: "esperado: \(a11yDescribe(spec.expectedTraits)) · atual: \(a11yDescribe(traits))")
        }

        if spec.isInteractive {
            let target = spec.touchTarget?(host.view) ?? (element as? UIView) ?? host.view
            let result = a11yTouchTarget(target, minimum: spec.minimumTouchTarget)
            report.check(result.ok, subject: spec.name, criterion: "área de toque",
                         detail: "\(result.detail) (mínimo \(Int(spec.minimumTouchTarget))×\(Int(spec.minimumTouchTarget)) pt)")
        }
    }

    // MARK: - Estados anunciados

    private func checkStates(_ spec: A11yComponentSpec, _ report: A11yReport) {
        guard !spec.states.isEmpty else { return }

        var problems: [String] = []
        for state in spec.states {
            let host = A11yHost(spec.make(), category: A11yContentSize.standard, layout: spec.layout)
            state.apply(host.view)
            host.relayout()
            let element = spec.element(host.view)

            if !state.expectTraits.isEmpty, !element.accessibilityTraits.isSuperset(of: state.expectTraits) {
                problems.append("\(state.name): traits esperados \(a11yDescribe(state.expectTraits)), "
                                + "atual \(a11yDescribe(element.accessibilityTraits))")
            }
            if let expected = state.expectValue, element.accessibilityValue != expected {
                problems.append("\(state.name): accessibilityValue esperado \"\(expected)\", "
                                + "atual \"\(element.accessibilityValue ?? "nil")\"")
            }
        }

        let names = spec.states.map { $0.name }.joined(separator: ", ")
        report.check(problems.isEmpty, subject: spec.name, criterion: "estados anunciados",
                     detail: problems.isEmpty ? "ok (\(names))" : problems.joined(separator: "; "))
    }

    // MARK: - Dynamic Type

    private func checkDynamicType(_ spec: A11yComponentSpec, _ report: A11yReport) {
        let normal = A11yHost(spec.make(), category: A11yContentSize.standard, layout: spec.layout)
        let huge = A11yHost(spec.make(), category: A11yContentSize.largest, layout: spec.layout)

        let normalTexts = a11yTextViews(in: normal.view)
        let hugeTexts = a11yTextViews(in: huge.view)
        guard !hugeTexts.isEmpty else { return } // componente sem texto: critérios não se aplicam

        // 1. Flag de ajuste automático
        let notAdjusting = hugeTexts.filter {
            ($0 as? UIContentSizeCategoryAdjusting)?.adjustsFontForContentSizeCategory != true
        }
        report.check(notAdjusting.isEmpty, subject: spec.name, criterion: "adjustsFontForContentSizeCategory",
                     detail: notAdjusting.isEmpty
                        ? "\(hugeTexts.count) texto(s) ok"
                        : "\(notAdjusting.count)/\(hugeTexts.count) sem a flag: "
                            + notAdjusting.map(a11yDescribeView).joined(separator: ", "))

        // 2. A fonte efetivamente cresce
        if normalTexts.count == hugeTexts.count {
            let notGrowing = zip(normalTexts, hugeTexts).filter { pair in
                guard let before = a11yFontSize(pair.0), let after = a11yFontSize(pair.1) else { return false }
                return after <= before
            }.map { $0.1 }
            report.check(notGrowing.isEmpty, subject: spec.name, criterion: "fonte cresce",
                         detail: notGrowing.isEmpty
                            ? "ok"
                            : "não cresceram: " + notGrowing.map(a11yDescribeView).joined(separator: ", "))
        } else {
            report.check(false, subject: spec.name, criterion: "fonte cresce",
                         detail: "estrutura muda entre tamanhos (\(normalTexts.count) vs \(hugeTexts.count) textos): verifique manualmente")
        }

        // 3. Nada cortado no maior tamanho
        let truncated = hugeTexts.compactMap { $0 as? UILabel }.filter(a11yIsTruncated)
        report.check(truncated.isEmpty, subject: spec.name, criterion: "sem corte em XXXL",
                     detail: truncated.isEmpty
                        ? "ok"
                        : "cortados: " + truncated.map(a11yDescribeView).joined(separator: ", "))
    }
}
