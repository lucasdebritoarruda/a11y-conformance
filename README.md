# Conformidade de acessibilidade: auditoria do DS e adoção (iOS · UIKit · mínimo iOS 12)

Duas peças que se complementam:

1. **Auditoria do design system**: testes que verificam se tokens e componentes do DS são acessíveis.
2. **Adoção**: script que mede quanto dos módulos de feature usa o DS e lista, com arquivo e linha, tudo o que contorna o DS.

```
a11y-conformance/
├── ios/
│   ├── Shared/
│   │   └── A11yReport.swift              → nos DOIS targets de teste
│   ├── DSAccessibilityTests/             → target de unit test (hospedado pelo app de catálogo)
│   │   ├── A11yDSAdapter.swift           ← o ÚNICO arquivo que você edita
│   │   ├── A11yTestSupport.swift
│   │   ├── DSContrastTests.swift
│   │   ├── DSTypographyTests.swift
│   │   └── DSComponentContractTests.swift
│   └── DSCatalogUITests/                 → target de UI test do app de catálogo
│       └── DSCatalogAuditUITests.swift
└── scripts/
    ├── a11y_adoption.py
    └── a11y_adoption.config.json
```

---

## Parte 1: auditoria do DS

### 1.1 Onde colocar os testes

Crie (ou use) um **target de unit test hospedado pelo app de catálogo/demo do DS** (Host Application = app de catálogo). Os testes de componente colocam views numa `UIWindow` e forçam traits de tamanho de texto. Isso se comporta de forma confiável num processo de app, e não num teste "lógico" sem host.

Adicione ao target:
- tudo de `ios/DSAccessibilityTests/`
- `ios/Shared/A11yReport.swift`

O deployment target pode continuar em iOS 12. Os testes usam `#available` onde necessário.

### 1.2 Preencha o adapter

Em `A11yDSAdapter.swift`:

O adapter já vem montado para o FDSKit: `@testable import FDSKit`, cores em `DSColor.<token>.uiColor` e tipografia via `DSLabel(textStyle: DSTextStyle)`.

O que falta preencher (marcado com `TODO`):

- **`textStyles`**: a lista de todos os estilos de texto, com nome e escala mínima. Como `DSTextStyle` é uma classe, não dá para enumerá-los automaticamente, então mantenha a lista em dia quando um estilo novo for criado. Títulos muito grandes podem usar escala mínima de 1.7 em vez de 2.0.
- **`colorPairs`**: troque os nomes ilustrativos pelos pares reais (texto/fundo, borda/fundo, texto do botão/fundo do botão).
- **`supportsDarkMode`**: deixe `false` se o app força o modo claro.
- **`components`**: já testa o `DSLabel` em todos os estilos de `textStyles`, com texto longo. Acrescente os demais componentes no formato dos exemplos comentados.

A tipografia é medida **através do `DSLabel`**: o teste hospeda um label de cada estilo em cada tamanho de texto e lê a fonte que ele realmente usa. Isso valida o token e também se o `DSLabel` liga `adjustsFontForContentSizeCategory`.

Enquanto uma lista estiver vazia, o teste correspondente falha com "Preencha A11yDSAdapter...".

**O que cada teste verifica:**

| Teste | Verifica |
|---|---|
| `DSContrastTests` | Razão de contraste WCAG por par, em claro e claro + alto contraste (iOS 13+) e, se suportado, escuro e escuro + alto contraste |
| `DSTypographyTests` | O token cresce em todas as 12 categorias de Dynamic Type e chega a `minimumScale` (2× por padrão, WCAG 1.4.4) |
| `DSComponentContractTests` | Elemento acessível, label, traits, área de toque ≥ 44 pt (inclusive áreas expandidas via `point(inside:)`), estados anunciados (traits/valor), `adjustsFontForContentSizeCategory` em todos os textos, fonte que cresce e texto sem corte em AX XXXL |

### 1.3 Audit do catálogo (UI test)

`DSCatalogAuditUITests` roda `performAccessibilityAudit()` da Apple em cada tela do catálogo, em três configurações: padrão, XXXL e XXXL + escuro.

- **Precisa de simulador iOS 17+ para rodar.** Em simuladores mais antigos, o teste é pulado, não falha. O app continua com mínimo iOS 12.
- Adicione `A11yReport.swift` também a este target.
- Ajuste a lista `screens` e as funções `openScreen`/`goBack` à navegação do catálogo.
- Para o modo escuro funcionar, o app de catálogo precisa ler a variável `A11Y_FORCE_DARK`. No `AppDelegate` (ou `SceneDelegate`), depois de criar a window:

```swift
if #available(iOS 13.0, *), ProcessInfo.processInfo.environment["A11Y_FORCE_DARK"] == "1" {
    window?.overrideUserInterfaceStyle = .dark
}
```

- Exceções conscientes vão em `isKnownIssue`, com justificativa.

### 1.4 Rodando e coletando o relatório

Cada suíte grava um JSON (`contraste.json`, `tipografia.json`, `componentes.json`, `catalogo-audit.json`) e também o anexa ao `.xcresult`.

```bash
TEST_RUNNER_A11Y_REPORT_DIR="$PWD/a11y-report/ds" \
xcodebuild test \
  -workspace App.xcworkspace -scheme DSCatalog \
  -destination 'platform=iOS Simulator,name=<iPhone disponível>,OS=<17 ou mais>' \
  -only-testing:DSAccessibilityTests -only-testing:DSCatalogUITests
```

O prefixo `TEST_RUNNER_` é removido pelo Xcode antes de repassar a variável ao processo de teste. Rodando pelo Xcode, defina `A11Y_REPORT_DIR` nas variáveis de ambiente do scheme (Test → Arguments). Sem a variável, o JSON vai para o diretório temporário do simulador, e o caminho aparece no log.

> Os testes Swift foram escritos para Xcode 15+ (exigido pelo audit do iOS 17) mas não puderam ser compilados no ambiente onde foram gerados. Espere ajustes pequenos na primeira compilação, principalmente nos inits dos seus componentes dentro do adapter.

---

## Parte 2: adoção

### 2.1 Configuração

Copie `scripts/a11y_adoption.config.json` para o repositório. Ele já vem configurado para o seu DS:

- **Cor**: `DSColor.<token>` (inclui `.uiColor`) conta como token.
- **Fonte**: cada `DSLabel(...)` criado conta como token, assim como `DSTextStyle.<estilo>.font` (ajuste o nome da propriedade se for outro).
- **`ds_label_class: "DSLabel"`**: `UILabel` cru nos módulos vira bypass ("Label fora do DS"), e a cobertura de Dynamic Type passa a contar `DSLabel` como coberto.

Ajuste os caminhos e, se precisar, as demais chaves:

| Chave | Para quê |
|---|---|
| `modules_root` | Pasta (ou lista de pastas) cujas subpastas são os módulos |
| `modules` | Alternativa: mapa explícito `{"Login": "Features/Login/Sources"}` |
| `design_system_paths` | Código do DS: o script descobre os componentes ali e não varre essas pastas |
| `exclude_globs` | O que ignorar (testes, Pods, código gerado...) |
| `ds_interactive_extra` | Componentes interativos que **não** herdam de `UIControl` (ex.: uma `UIView` com um `UISwitch` dentro). Confira a lista "Componentes do DS detectados" no relatório |
| `ds_label_class` | Se o DS tem um label próprio que já nasce com Dynamic Type (ex.: `"DSLabel"`). Com isso, `UILabel` cru vira bypass e a cobertura de Dynamic Type fica mais precisa |
| `font_token_patterns` / `color_token_patterns` | Regex de **uso** dos seus tokens (ex.: `\bDSColor\.\w+`, `\bUIFont\.ds\w+`) |
| `xib_named_colors_are_tokens` | Se cor do Asset Catalog em XIB conta como token |
| `extra_patterns` / `disabled_patterns` | Para adicionar ou desligar padrões de bypass sem mexer no script |

### 2.2 Rodando

```bash
python3 scripts/a11y_adoption.py \
  --root . \
  --config scripts/a11y_adoption.config.json \
  --out a11y-report \
  --ds-report a11y-report/ds          # opcional: inclui as tabelas da auditoria do DS
```

Saídas em `a11y-report/`:
- `adoption.md`: auditoria do DS (se informada), componentes detectados, resumo por módulo, bypasses por categoria, ranking de arquivos e achados com `arquivo:linha` (ou `arquivo.xib#idDoObjeto`)
- `adoption.json`: os mesmos dados completos, para CI e histórico

### 2.3 Métricas

- **Adoção de interativos** = componentes interativos do DS ÷ (DS + interativos nativos, em código e XIB)
- **Aderência de fonte / cor** = usos de token ÷ (tokens + fontes/cores fora do token)
- **Dynamic Type**: exata em XIB; em código é estimativa (labels criados × `adjustsFontForContentSizeCategory = true`). Se a flag é aplicada por um helper, a estimativa fica baixa. Nesse caso, use `ds_label_class` ou adicione o helper em `extra_patterns` → `swift` → `adjusts_true`.

### 2.4 Exceções

Use exceções para casos intencionais. Elas saem da conta, mas continuam listadas em "Permitidos".

- **Swift/ObjC**: comentário na mesma linha ou na linha anterior:
  ```swift
  let help = UIButton(type: .system) // a11y-ok: link de ajuda legado, migração no Q1
  ```
- **XIB/storyboard, ou um arquivo inteiro**: em `a11y-allowlist.txt`, na raiz:
  ```
  # caminho#idDoObjeto   motivo
  Modules/Checkout/Checkout.xib#btn-3   botão de cupom, será migrado
  Modules/Legacy/OldScreen.swift:42     motivo
  Modules/Legacy/OldScreen.swift        arquivo inteiro
  ```

### 2.5 CI

```bash
python3 scripts/a11y_adoption.py ... --fail-under-adoption 0.8 --fail-under-font 0.9 --fail-under-color 0.9
```

O script retorna código 1 abaixo dos limites. Comece com os valores atuais como piso, para impedir regressão, e suba aos poucos.

### 2.6 Limites conhecidos

- A detecção é por regex, sobre código já sem comentários e strings. Casos indiretos (factories, extensões que criam controles) podem escapar. Para precisão maior, o próximo passo é SwiftSyntax.
- Em XIB, `backgroundColor` fica fora por padrão (quase toda view tem um branco default). Inclua em `xib_color_keys` se quiser.
- O script mede **uso** do DS, não se a tela ficou acessível. Os arquivos do ranking são a lista de trabalho para a revisão por IA, o audit em telas reais e o teste manual.
