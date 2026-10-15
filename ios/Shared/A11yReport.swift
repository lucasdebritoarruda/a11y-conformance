//
//  A11yReport.swift
//  Coleta os resultados das verificações e grava um JSON por suíte.
//  Adicione este arquivo AOS DOIS targets: DSAccessibilityTests e DSCatalogUITests.
//
//  Onde o JSON é gravado:
//  - Na pasta indicada pela variável de ambiente A11Y_REPORT_DIR.
//    Via xcodebuild, exporte TEST_RUNNER_A11Y_REPORT_DIR=/caminho/absoluto:
//    o Xcode repassa a variável ao processo de teste sem o prefixo TEST_RUNNER_.
//  - Sem a variável, no diretório temporário do simulador (o caminho é impresso no log).
//  - Sempre também como anexo no .xcresult (útil em device físico ou CI sem acesso ao disco).
//

import Foundation
import XCTest

struct A11yResult: Codable {
    let subject: String
    let criterion: String
    let passed: Bool
    let detail: String
}

final class A11yReport {
    let suite: String
    private(set) var results: [A11yResult] = []

    init(suite: String) {
        self.suite = suite
    }

    /// Registra o resultado e falha o teste quando `passed` é falso.
    func check(_ passed: Bool,
               subject: String,
               criterion: String,
               detail: String,
               file: StaticString = #file,
               line: UInt = #line) {
        results.append(A11yResult(subject: subject, criterion: criterion, passed: passed, detail: detail))
        if !passed {
            XCTFail("[\(suite)] \(subject) › \(criterion): \(detail)", file: file, line: line)
        }
    }

    func write() {
        let payload = Payload(suite: suite,
                              generatedAt: ISO8601DateFormatter().string(from: Date()),
                              results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        guard let data = try? encoder.encode(payload) else {
            print("[a11y] não foi possível serializar o relatório \(suite)")
            return
        }

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "a11y-\(suite).json"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Relatório de acessibilidade: \(suite)") { activity in
            activity.add(attachment)
        }

        let directory: URL
        if let path = ProcessInfo.processInfo.environment["A11Y_REPORT_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("a11y-report", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let url = directory.appendingPathComponent("\(suite).json")
            try data.write(to: url, options: .atomic)
            print("[a11y] relatório gravado em \(url.path)")
        } catch {
            print("[a11y] não foi possível gravar o relatório em disco: \(error)")
        }
    }

    private struct Payload: Codable {
        let suite: String
        let generatedAt: String
        let results: [A11yResult]
    }
}
