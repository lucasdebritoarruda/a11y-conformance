//
//  DSCatalogAuditUITests.swift
//  Roda o audit de acessibilidade da Apple (performAccessibilityAudit) em cada tela
//  do app de catálogo do DS, em várias combinações de tamanho de texto e aparência.
//
//  - Exige simulador com iOS 17+ para RODAR. O app continua com mínimo iOS 12;
//    em simuladores mais antigos o teste é pulado (XCTSkip), não falha.
//  - Adicione também A11yReport.swift a este target.
//  - Ajuste `screens`, `openScreen` e `goBack` à navegação do seu catálogo.
//  - Para o modo escuro, o app de catálogo precisa ler A11Y_FORCE_DARK (ver README).
//

import XCTest

final class DSCatalogAuditUITests: XCTestCase {

    private struct RunConfig {
        let name: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let configs: [RunConfig] = [
        RunConfig(name: "padrão",
                  arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"],
                  environment: [:]),
        RunConfig(name: "XXXL",
                  arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                  environment: [:]),
        RunConfig(name: "XXXL+escuro",
                  arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                  environment: ["A11Y_FORCE_DARK": "1"]),
    ]

    /// TODO: accessibilityIdentifier (ou texto) do item que abre cada tela no catálogo.
    private let screens = [
        "catalog.buttons",
        "catalog.textFields",
        "catalog.toggles",
        "catalog.cards",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    func testCatalogScreensPassAccessibilityAudit() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("performAccessibilityAudit exige iOS 17+ no simulador")
        }

        let report = A11yReport(suite: "catalogo-audit")

        for config in configs {
            let app = XCUIApplication()
            app.launchArguments += config.arguments
            for (key, value) in config.environment {
                app.launchEnvironment[key] = value
            }
            app.launch()

            for screen in screens {
                let subject = "\(screen) [\(config.name)]"

                guard openScreen(screen, in: app) else {
                    report.check(false, subject: subject, criterion: "navegação",
                                 detail: "não encontrou o item '\(screen)' no catálogo")
                    continue
                }

                var issuesByType: [String: [String]] = [:]
                do {
                    try app.performAccessibilityAudit(for: .all) { issue in
                        if self.isKnownIssue(issue, screen: screen) { return true }
                        let type = Self.typeName(issue.auditType)
                        issuesByType[type, default: []].append(Self.describe(issue))
                        return true // já vai para o relatório (que falha o teste); evita falha duplicada
                    }
                } catch {
                    report.check(false, subject: subject, criterion: "execução do audit", detail: "\(error)")
                }

                for (_, type) in Self.auditTypes {
                    let issues = issuesByType[type] ?? []
                    report.check(issues.isEmpty, subject: subject, criterion: type,
                                 detail: issues.isEmpty ? "ok" : issues.joined(separator: " | "))
                }
                if let other = issuesByType["outro"], !other.isEmpty {
                    report.check(false, subject: subject, criterion: "outro", detail: other.joined(separator: " | "))
                }

                goBack(in: app)
            }

            app.terminate()
        }

        report.write()
    }

    // MARK: - Navegação (ajuste ao seu catálogo)

    private func openScreen(_ identifier: String, in app: XCUIApplication) -> Bool {
        let item = app.descendants(matching: .any)[identifier].firstMatch
        guard item.waitForExistence(timeout: 3) else { return false }
        item.tap()
        return true
    }

    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    // MARK: - Exceções conhecidas

    /// Devolva true para issues aceitos conscientemente (ex.: falso positivo documentado).
    /// Mantenha a lista curta e com justificativa: ela é parte da auditoria.
    @available(iOS 17.0, *)
    private func isKnownIssue(_ issue: XCUIAccessibilityAuditIssue, screen: String) -> Bool {
        // Exemplo:
        // if screen == "catalog.cards", issue.auditType == .contrast,
        //    issue.element?.label == "Imagem decorativa" { return true }
        return false
    }

    // MARK: - Formatação

    @available(iOS 17.0, *)
    private static var auditTypes: [(XCUIAccessibilityAuditType, String)] {
        [
            (.contrast, "contraste"),
            (.dynamicType, "dynamicType"),
            (.textClipped, "textoCortado"),
            (.hitRegion, "areaDeToque"),
            (.sufficientElementDescription, "descricao"),
            (.elementDetection, "deteccao"),
            (.trait, "traits"),
        ]
    }

    @available(iOS 17.0, *)
    private static func typeName(_ type: XCUIAccessibilityAuditType) -> String {
        auditTypes.first { type.contains($0.0) }?.1 ?? "outro"
    }

    @available(iOS 17.0, *)
    private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element.map { el -> String in
            if !el.label.isEmpty { return "\"\(el.label)\"" }
            if !el.identifier.isEmpty { return "#\(el.identifier)" }
            return "elemento sem label"
        } ?? "?"
        return "\(issue.compactDescription) (\(element))"
    }
}
