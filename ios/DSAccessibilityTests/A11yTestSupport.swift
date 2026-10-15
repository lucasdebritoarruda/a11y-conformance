//
//  A11yTestSupport.swift
//  Infraestrutura genérica dos testes de acessibilidade do design system.
//  Não precisa ser editado: o que é específico do seu DS fica em A11yDSAdapter.swift.
//
//  Compatível com deployment target iOS 12. As variações de modo escuro e alto
//  contraste só são testadas quando o simulador roda iOS 13+.
//

import UIKit
import XCTest

// MARK: - Tipos usados pelo adapter

/// Par de cores que aparecem juntas na UI (texto sobre fundo, borda sobre fundo...).
struct A11yColorPair {
    let name: String
    let foreground: UIColor
    /// Precisa ser opaco. Se o fundo real for semitransparente, declare a cor resultante.
    let background: UIColor
    /// Use A11yContrast.normalText, .largeText, .nonText ou o valor da sua documentação.
    let minimum: Double
}

/// Token de tipografia: `makeFont` recebe o trait de tamanho de texto e devolve a fonte do token.
struct A11yTypographySample {
    let name: String
    let makeFont: (UITraitCollection) -> UIFont
    /// Quanto o token precisa crescer entre o tamanho padrão (Large) e o maior (AX XXXL).
    /// 2.0 = WCAG 1.4.4 (texto redimensionável até 200%).
    /// Títulos muito grandes escalam proporcionalmente menos no próprio sistema; ajuste por token.
    var minimumScale: CGFloat = 2.0
}

/// Um estado do componente que precisa ser anunciado ao VoiceOver.
struct A11yStateCheck {
    let name: String
    /// Coloca o componente no estado (ex.: `{ ($0 as? UIControl)?.isEnabled = false }`).
    let apply: (UIView) -> Void
    /// Traits que devem estar presentes nesse estado (ex.: .notEnabled, .selected).
    var expectTraits: UIAccessibilityTraits = []
    /// accessibilityValue esperado nesse estado (ex.: "1" para um UISwitch ligado).
    var expectValue: String? = nil
}

enum A11yLayout {
    /// Largura fixa: para componentes que ocupam a largura da tela (cards, células, campos).
    case fill(width: CGFloat)
    /// Tamanho intrínseco, limitado a uma largura máxima: botões, chips, ícones.
    case intrinsic(maxWidth: CGFloat)
}

/// Contrato de acessibilidade esperado de um componente do DS.
struct A11yComponentSpec {
    let name: String
    /// Cria o componente já com conteúdo realista. Use os textos MAIS LONGOS plausíveis,
    /// para que o teste de corte em tamanhos grandes de fonte seja significativo.
    let make: () -> UIView
    /// Traits obrigatórios no estado padrão (ex.: .button, .header).
    var expectedTraits: UIAccessibilityTraits = []
    /// Componentes interativos têm a área de toque verificada.
    var isInteractive: Bool = false
    /// true: o componente é UM elemento para o VoiceOver (botão, toggle, campo).
    /// false: é um container cujos filhos são os elementos (card com título + botão).
    var isSingleElement: Bool = true
    /// Exige accessibilityLabel não vazio no elemento.
    var requiresLabel: Bool = true
    var minimumTouchTarget: CGFloat = 44
    /// Qual objeto o VoiceOver foca. Padrão: a própria view.
    var element: (UIView) -> NSObject = { $0 }
    /// Qual view recebe o toque. Padrão: o elemento, se for uma UIView; senão, a view raiz.
    var touchTarget: ((UIView) -> UIView)? = nil
    var states: [A11yStateCheck] = []
    var layout: A11yLayout = .intrinsic(maxWidth: 320)
}

// MARK: - Contraste (WCAG 2.x, critérios 1.4.3 e 1.4.11)

enum A11yContrast {
    /// 1.4.3: texto comum.
    static let normalText = 4.5
    /// 1.4.3: texto grande (≥ 18pt, ou ≥ 14pt em negrito).
    static let largeText = 3.0
    /// 1.4.11: bordas de campos, ícones, indicadores de estado e de foco.
    static let nonText = 3.0

    static func ratio(_ a: UIColor, _ b: UIColor) -> Double? {
        guard let la = relativeLuminance(a), let lb = relativeLuminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func relativeLuminance(_ color: UIColor) -> Double? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func channel(_ value: CGFloat) -> Double {
            let v = min(max(Double(value), 0), 1) // corta valores de extended sRGB
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Compõe uma cor semitransparente sobre um fundo opaco.
    static func flatten(_ foreground: UIColor, over background: UIColor) -> UIColor? {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        guard foreground.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
              background.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return nil }
        return UIColor(red: fr * fa + br * (1 - fa),
                       green: fg * fa + bg * (1 - fa),
                       blue: fb * fa + bb * (1 - fa),
                       alpha: 1)
    }

    static func alpha(of color: UIColor) -> CGFloat? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return color.getRed(&r, green: &g, blue: &b, alpha: &a) ? a : nil
    }
}

// MARK: - Aparências (claro, escuro, alto contraste)

struct A11yAppearance {
    let name: String
    let traits: UITraitCollection

    /// Escuro e alto contraste só existem a partir do iOS 13.
    static func all(includeDark: Bool) -> [A11yAppearance] {
        var list = [A11yAppearance(name: "claro", traits: UITraitCollection(userInterfaceStyle: .light))]
        if #available(iOS 13.0, *) {
            list.append(A11yAppearance(name: "claro+altoContraste", traits: UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: .light),
                UITraitCollection(accessibilityContrast: .high),
            ])))
            if includeDark {
                list.append(A11yAppearance(name: "escuro", traits: UITraitCollection(userInterfaceStyle: .dark)))
                list.append(A11yAppearance(name: "escuro+altoContraste", traits: UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: .dark),
                    UITraitCollection(accessibilityContrast: .high),
                ])))
            }
        }
        return list
    }
}

/// Resolve uma cor dinâmica para a aparência pedida. No iOS 12 as cores não variam.
func a11yResolved(_ color: UIColor, for traits: UITraitCollection) -> UIColor {
    if #available(iOS 13.0, *) {
        return color.resolvedColor(with: traits)
    }
    return color
}

// MARK: - Dynamic Type

enum A11yContentSize {
    static let ordered: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]
    static let standard: UIContentSizeCategory = .large
    static let largest: UIContentSizeCategory = .accessibilityExtraExtraExtraLarge
}

// MARK: - Hospedagem de componentes

/// Coloca um componente numa janela, dentro de um view controller com tamanho de texto forçado,
/// e faz o layout. É o que permite testar Dynamic Type e área de toque sem UI test.
final class A11yHost {
    let window: UIWindow
    let view: UIView
    private let parent = UIViewController()
    private let child = UIViewController()

    init(_ view: UIView, category: UIContentSizeCategory, layout: A11yLayout) {
        self.view = view
        self.window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 3000))

        window.rootViewController = parent
        parent.addChild(child)
        child.view.frame = parent.view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)

        view.translatesAutoresizingMaskIntoConstraints = false
        child.view.addSubview(view)
        var constraints = [
            view.leadingAnchor.constraint(equalTo: child.view.leadingAnchor, constant: 16),
            view.topAnchor.constraint(equalTo: child.view.topAnchor, constant: 16),
        ]
        switch layout {
        case .fill(let width):
            constraints.append(view.widthAnchor.constraint(equalToConstant: width))
        case .intrinsic(let maxWidth):
            constraints.append(view.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth))
        }
        NSLayoutConstraint.activate(constraints)

        window.isHidden = false
        relayout()
    }

    /// Chame depois de mudar o estado do componente.
    func relayout() {
        view.setNeedsLayout()
        window.layoutIfNeeded()
    }

    deinit {
        window.isHidden = true
    }
}

/// Mede a fonte que um label REALMENTE usa num tamanho de texto, hospedando-o numa janela.
/// Útil quando os tokens de fonte só são acessíveis por um componente (ex.: DSLabel + DSTextStyle):
/// o teste mede o comportamento real, incluindo adjustsFontForContentSizeCategory.
func a11yRenderedFont(of makeLabel: () -> UILabel, category: UIContentSizeCategory) -> UIFont {
    let label = makeLabel()
    if (label.text ?? "").isEmpty {
        label.text = "Texto de exemplo"
    }
    let host = A11yHost(label, category: category, layout: .intrinsic(maxWidth: 320))
    return withExtendedLifetime(host) { label.font }
}

// MARK: - Inspeção de views

/// Views que gerenciam o próprio texto: não descemos nelas (evita pegar labels internos do UIKit).
private func a11yManagesOwnText(_ view: UIView) -> Bool {
    view is UITextField || view is UITextView || view is UIDatePicker || view is UIPickerView
}

func a11yAllViews(_ root: UIView) -> [UIView] {
    guard !a11yManagesOwnText(root) else { return [root] }
    return [root] + root.subviews.flatMap { a11yAllViews($0) }
}

func a11yIsVisible(_ view: UIView, within root: UIView) -> Bool {
    var current: UIView? = view
    while let v = current {
        if v.isHidden || v.alpha < 0.01 { return false }
        if v === root { return true }
        current = v.superview
    }
    return true
}

/// Views de texto visíveis (UILabel, UITextField, UITextView), incluindo o titleLabel de botões.
func a11yTextViews(in root: UIView) -> [UIView] {
    a11yAllViews(root).filter { view in
        guard view is UIContentSizeCategoryAdjusting, a11yIsVisible(view, within: root) else { return false }
        if let label = view as? UILabel {
            let text = label.attributedText?.string ?? label.text ?? ""
            return !text.isEmpty
        }
        return true
    }
}

func a11yFontSize(_ view: UIView) -> CGFloat? {
    switch view {
    case let label as UILabel: return label.font?.pointSize
    case let field as UITextField: return field.font?.pointSize
    case let textView as UITextView: return textView.font?.pointSize
    default: return nil
    }
}

/// Texto que precisaria de mais altura do que o label tem (cortado ou com reticências).
func a11yIsTruncated(_ label: UILabel) -> Bool {
    let text = label.attributedText?.string ?? label.text ?? ""
    guard !text.isEmpty else { return false }
    guard label.bounds.width > 0.5 else { return true } // label espremido a largura zero
    let bounds = CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude)
    let needed = label.textRect(forBounds: bounds, limitedToNumberOfLines: 0).height
    return needed > label.bounds.height + 0.5
}

/// Verifica se um quadrado de `minimum`×`minimum` centrado na view responde ao toque.
/// Considera áreas expandidas via `point(inside:with:)`.
func a11yTouchTarget(_ view: UIView, minimum: CGFloat) -> (ok: Bool, detail: String) {
    let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    let d = minimum / 2 - 0.5
    let corners = [
        CGPoint(x: center.x - d, y: center.y - d), CGPoint(x: center.x + d, y: center.y - d),
        CGPoint(x: center.x - d, y: center.y + d), CGPoint(x: center.x + d, y: center.y + d),
    ]
    let ok = corners.allSatisfy { view.point(inside: $0, with: nil) }
    let expanded = ok && (view.bounds.width < minimum || view.bounds.height < minimum)
    let detail = String(format: "%.0f×%.0f pt", view.bounds.width, view.bounds.height)
        + (expanded ? " (área expandida via point(inside:))" : "")
    return (ok, detail)
}

func a11yDescribe(_ traits: UIAccessibilityTraits) -> String {
    let names: [(UIAccessibilityTraits, String)] = [
        (.button, "button"), (.link, "link"), (.header, "header"), (.selected, "selected"),
        (.notEnabled, "notEnabled"), (.adjustable, "adjustable"), (.image, "image"),
        (.staticText, "staticText"), (.searchField, "searchField"), (.updatesFrequently, "updatesFrequently"),
    ]
    let found = names.filter { traits.contains($0.0) }.map { $0.1 }
    return found.isEmpty ? "nenhum" : found.joined(separator: ", ")
}

func a11yDescribeView(_ view: UIView) -> String {
    let typeName = String(describing: type(of: view))
    if let label = view as? UILabel, let text = label.text, !text.isEmpty {
        return "\(typeName) \"\(text.prefix(30))\""
    }
    return typeName
}
