//
//  A11yDSAdapter.swift
//  O ÚNICO arquivo que você precisa editar: conecta os testes genéricos
//  aos tokens e componentes do seu design system.
//
//  Padrões do FDSKit usados aqui:
//  - Cores: DSColor.<token>.uiColor
//  - Tipografia: DSLabel(textStyle: DSTextStyle), com DSTextStyle sendo uma classe
//    (por isso os estilos são listados à mão em `textStyles`)
//
//  Itens marcados com TODO precisam dos nomes reais dos seus tokens.
//

import UIKit
@testable import FDSKit

enum A11yDSAdapter {

    /// O app suporta modo escuro? Se o Info.plist força o modo claro, use false.
    static let supportsDarkMode = true

    // MARK: - 1. Pares de cor
    //
    // Liste os pares que de fato aparecem juntos na UI: cada combinação de
    // texto/ícone/borda + fundo que o DS prevê. Não é "todas contra todas".
    // Os nomes abaixo (exceto secondary00) são ilustrativos: troque pelos seus tokens.
    //
    // Mínimos: A11yContrast.normalText (4.5), .largeText (3.0), .nonText (3.0),
    // ou o valor da documentação interna, se for mais rígido.

    static var colorPairs: [A11yColorPair] {
        [
            A11yColorPair(name: "textPrimary / background",
                          foreground: DSColor.textPrimary.uiColor,
                          background: DSColor.background.uiColor,
                          minimum: A11yContrast.normalText),
            A11yColorPair(name: "textSecondary / background",
                          foreground: DSColor.textSecondary.uiColor,
                          background: DSColor.background.uiColor,
                          minimum: A11yContrast.normalText),
            A11yColorPair(name: "secondary00 / background (ícones e bordas)",
                          foreground: DSColor.secondary00.uiColor,
                          background: DSColor.background.uiColor,
                          minimum: A11yContrast.nonText),
            // Texto sobre o fundo do botão primário:
            // A11yColorPair(name: "onPrimary / primary",
            //               foreground: DSColor.onPrimary.uiColor,
            //               background: DSColor.primary00.uiColor,
            //               minimum: A11yContrast.normalText),
        ]
    }

    // MARK: - 2. Tipografia (via DSLabel)
    //
    // Como os tokens de fonte são consumidos pelo DSLabel, o teste mede a fonte
    // que o DSLabel REALMENTE usa em cada tamanho de texto. Isso valida o token
    // e também se o DSLabel liga adjustsFontForContentSizeCategory.

    /// Todos os estilos de texto do DS. Como DSTextStyle é uma classe, não dá para
    /// enumerá-los automaticamente: mantenha esta lista em dia quando um estilo for criado.
    ///
    /// `minimumScale`: quanto o estilo precisa crescer do tamanho padrão ao maior.
    /// 2.0 = WCAG 1.4.4. Títulos muito grandes podem usar algo como 1.7.
    ///
    /// TODO: troque pelos estilos reais. Se forem instâncias criadas por init em vez de
    /// propriedades estáticas, monte-as aqui do mesmo jeito que o app monta.
    static let textStyles: [(name: String, style: DSTextStyle, minimumScale: CGFloat)] = [
        ("title", DSTextStyle.title, 2.0),
        ("body", DSTextStyle.body, 2.0),
        ("caption", DSTextStyle.caption, 2.0),
    ]

    static var typographyTokens: [A11yTypographySample] {
        textStyles.map { entry in
            A11yTypographySample(
                name: entry.name,
                makeFont: { traits in
                    a11yRenderedFont(of: { DSLabel(textStyle: entry.style) },
                                     category: traits.preferredContentSizeCategory)
                },
                minimumScale: entry.minimumScale
            )
        }
    }

    // MARK: - 3. Componentes
    //
    // Um spec por componente (ou por variação relevante). Use textos longos e
    // realistas: é o que torna o teste de corte em XXXL significativo.

    static var components: [A11yComponentSpec] {
        var specs: [A11yComponentSpec] = []

        // DSLabel: um spec por estilo, com texto longo, numa coluna de 320 pt.
        // Pega estilos com numberOfLines fixo que cortam texto em tamanhos grandes.
        for entry in textStyles {
            specs.append(A11yComponentSpec(
                name: "DSLabel (\(entry.name))",
                make: {
                    let label = DSLabel(textStyle: entry.style)
                    label.text = "Texto longo de exemplo para verificar quebra de linha em tamanhos grandes"
                    return label
                },
                layout: .fill(width: 320)
            ))
        }

        // Títulos devem ser anunciados como cabeçalho (WCAG 1.3.1). Se o DS
        // define o trait no estilo, descomente para cobrar:
        // specs.append(A11yComponentSpec(
        //     name: "DSLabel (title) é cabeçalho",
        //     make: { DSLabel(textStyle: DSTextStyle.title) },
        //     expectedTraits: .header
        // ))

        // Outros componentes: exemplos do formato.
        // specs.append(A11yComponentSpec(
        //     name: "DSButton (primário)",
        //     make: { DSButton(title: "Continuar para o pagamento", style: .primary) },
        //     expectedTraits: .button,
        //     isInteractive: true,
        //     states: [
        //         A11yStateCheck(name: "desabilitado",
        //                        apply: { ($0 as? UIControl)?.isEnabled = false },
        //                        expectTraits: .notEnabled),
        //     ]
        // ))
        //
        // specs.append(A11yComponentSpec(
        //     name: "DSIconButton",
        //     make: { DSIconButton(icon: .close, accessibilityLabel: "Fechar") },
        //     expectedTraits: .button,
        //     isInteractive: true
        // ))
        //
        // // Linha com título + UISwitch: o switch é o elemento focado.
        // specs.append(A11yComponentSpec(
        //     name: "DSToggleRow",
        //     make: { DSToggleRow(title: "Receber notificações de promoções e novidades") },
        //     isInteractive: true,
        //     element: { ($0 as! DSToggleRow).switchControl },
        //     states: [
        //         A11yStateCheck(name: "ligado",
        //                        apply: { ($0 as! DSToggleRow).isOn = true },
        //                        expectValue: "1"),
        //     ],
        //     layout: .fill(width: 320)
        // ))
        //
        // // Container: os filhos é que são os elementos acessíveis.
        // specs.append(A11yComponentSpec(
        //     name: "DSCard",
        //     make: { DSCard(title: "Resumo do pedido", subtitle: "Entrega prevista em dias úteis") },
        //     isSingleElement: false,
        //     requiresLabel: false,
        //     layout: .fill(width: 320)
        // ))

        return specs
    }
}
