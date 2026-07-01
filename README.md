# PFM Cartão — Contrato do Evento Canônico + Gerador de Massa Sintética

Primeira entrega de código da Fase 1: **PBI-02 (contrato do evento canônico)** e **PBI-03 (gerador de massa sintética)**.

Estes dois andam juntos de propósito. O contrato é a **fonte única da verdade** do evento que atravessa o pipeline; o gerador produz eventos **conformes a esse contrato** para você desenvolver e testar **sem depender do dump real**. Por isso os dois ficam em C#/.NET e compartilham a mesma definição — se o gerador estivesse em outra linguagem, o schema viveria duplicado e divergiria, que é exatamente o que um contrato existe para evitar.

---

## 1. Pré-requisitos

- **.NET SDK 8.0+** (`dotnet --version` deve mostrar 8.x ou superior).
- Nenhum pacote NuGet externo. Tudo é biblioteca padrão — zero fricção de `restore`.

---

## 2. Estrutura

```
pfm-categorization/
├─ .gitignore
├─ sample_output.jsonl                      # exemplo ilustrativo da saída
├─ README.md
└─ src/
   ├─ Pfm.Categorization.Contracts/         # FONTE DA VERDADE (class library)
   │  ├─ PfmCategories.cs                    # as 14 categorias
   │  ├─ SchemaConstants.cs                  # versões + valores de domínio (BRL=986, etc.)
   │  ├─ CanonicalCardTransactionEvent.cs    # ⭐ o contrato (PBI-02)
   │  ├─ SnakeCaseLowerNamingPolicy.cs       # PascalCase -> snake_case
   │  └─ CanonicalJson.cs                    # serialização canônica compartilhada
   │
   └─ Pfm.Categorization.SyntheticData/      # o gerador (console, PBI-03)
      ├─ SyntheticLabeledEvent.cs            # envelope de teste (evento + rótulo verdadeiro)
      ├─ GeneratorOptions.cs                 # opções (count, seed, proporções)
      ├─ MerchantCatalog.cs                  # merchants/MCCs por categoria + cenários
      ├─ DescriptorStyler.cs                 # descriptors sujos (padded, prefixo de adquirente)
      ├─ EventGenerator.cs                   # motor de geração (determinístico por seed)
      └─ Program.cs                          # CLI + escrita dos .jsonl + resumo
```

**Por que dois projetos, e não um?** Porque o `Contracts` vai ser **referenciado também pelo Categorization Service** depois. Mantê-lo isolado garante que o gerador e o serviço de produção falem exatamente o mesmo contrato. O gerador é descartável; o contrato é para a vida toda.

---

## 3. Montando do zero (o "desde o git init")

Se quiser entender a estrutura montando você mesmo, os arquivos `.cs`/`.csproj` deste repositório foram pensados para encaixar exatamente nestes comandos:

```bash
# 1. repositório
git init pfm-categorization
cd pfm-categorization

# 2. solução
dotnet new sln -n PfmCategorization

# 3. biblioteca de contratos (fonte da verdade)
dotnet new classlib -n Pfm.Categorization.Contracts -o src/Pfm.Categorization.Contracts

# 4. console do gerador
dotnet new console -n Pfm.Categorization.SyntheticData -o src/Pfm.Categorization.SyntheticData

# 5. referência: o gerador usa os contratos
dotnet add src/Pfm.Categorization.SyntheticData/Pfm.Categorization.SyntheticData.csproj \
  reference src/Pfm.Categorization.Contracts/Pfm.Categorization.Contracts.csproj

# 6. registrar os dois projetos na solução
dotnet sln add src/Pfm.Categorization.Contracts/Pfm.Categorization.Contracts.csproj
dotnet sln add src/Pfm.Categorization.SyntheticData/Pfm.Categorization.SyntheticData.csproj
```

Os comandos acima geram um `.sln` correto (com os GUIDs certos). Depois é só substituir os `.cs`/`.csproj` gerados pelos deste repositório (o `dotnet new classlib` cria um `Class1.cs` que você apaga). Como alternativa, se você já recebeu a pasta pronta, pule direto para o passo 4.

---

## 4. Compilar e rodar

```bash
# compilar tudo
dotnet build

# gerar 10.000 eventos com seed 42 em ./out
dotnet run --project src/Pfm.Categorization.SyntheticData -- --count 10000 --seed 42 --out ./out
```

> Note o `--` antes dos argumentos: ele separa as flags do `dotnet` das flags do **seu programa**.

### Opções

| Flag | Padrão | O que faz |
|---|---|---|
| `--count` | 10000 | Quantidade de eventos |
| `--seed` | 42 | Semente do gerador (mesma seed ⇒ mesma massa) |
| `--out` | ./out | Diretório de saída |
| `--indented` | false | JSON indentado (debug). Padrão é JSON Lines (1 evento/linha) |
| `--hard` | 0.15 | Fração de casos difíceis (marketplace, catch-all, posto+conveniência) |
| `--acquirer` | 0.25 | Fração com prefixo de adquirente (PAGSEGURO*, MP*, ...) |
| `--international` | 0.08 | Fração internacional (moeda estrangeira + IOF) |
| `--installment` | 0.20 | Fração parcelada |
| `--filtered` | 0.03 | Fração que **não** deveria passar (status ≠ liquidada) |

---

## 5. O que sai

Dois arquivos em `--out`:

| Arquivo | Conteúdo | Para quê |
|---|---|---|
| `synthetic_canonical_events.jsonl` | só o evento canônico | **É o que você joga no pipeline.** Idêntico ao que viria do Kafka pós-dedup |
| `synthetic_labeled_events.jsonl` | evento + `expected_category` + `scenario` + `is_hard` | **Só para MEDIR.** O pipeline nunca vê o rótulo |

Essa separação é o ponto pedagógico central: **a verdade (rótulo) é um artefato de teste, não faz parte do contrato.** Em produção não existe `expected_category`. Você mede a acurácia comparando a saída do pipeline (que só viu o canônico) contra o arquivo rotulado.

Formato: **JSON Lines** (um objeto JSON por linha). É o padrão para dados de evento — fácil de streamar, fácil de ler em qualquer linguagem (inclusive `pandas.read_json(lines=True)` quando o trabalho de dados em Python começar).

O console ainda imprime um **resumo de sanidade** (distribuição por categoria, por cenário, % de cada tipo). Sempre confira esse resumo: é como você verifica se a massa que gerou tem a cara que você queria.

Veja `sample_output.jsonl` para 4 linhas ilustrativas (a formatação exata dos decimais pode variar um pouco do que o `System.Text.Json` emite — o que importa aqui é o **formato dos campos**).

---

## 6. O contrato: o que está dentro e o que ficou de fora

O evento canônico **não é** o evento bruto do core de cartão. Alguns campos foram **deliberadamente removidos**:

| Campo bruto | Por que NÃO está no canônico |
|---|---|
| `pan` | Dado sensível de cartão (LGPD/PCI). Nunca propaga para a categorização |
| `card_id` | Identifica comportamento individual; não é necessário para a categoria global |
| `nsu`, `authorization_code` | Operacionais (rastreio de autorização), sem valor para categoria |
| `transaction_identification` | Operacional; `transaction_uuid` já cobre idempotência/auditoria |

O que **ficou** é o que tem valor para categorizar (merchant, MCC, valor, moeda/IOF para o sinal internacional) mais o mínimo de identidade para idempotência e auditoria (`transaction_uuid`, `purchase_id`, `account_id`). O `account_id` está marcado como **sensível**: serve de chave de partição e, no futuro, de lookup de override — mas **não** entra como feature no modelo global.

Dois detalhes de design que valem o olhar:

- **`merchant_*` resolvido começa nulo.** `merchant_signature`, `merchant_resolved_name`, `merchant_city`, etc. são preenchidos pelo **Merchant Resolution Service** (etapa seguinte). No JSON eles simplesmente não aparecem enquanto nulos. O gerador os deixa vazios de propósito — é trabalho do próximo serviço.
- **`IsInternational()` é método, não campo.** O sinal internacional (`IOF>0` ou moeda≠BRL ou câmbio≠1) é **derivado**, não um fato de origem — e é **feature**, não regra direta de Viagem. Por isso é um método (não serializado), deixando explícito que ninguém "grava" esse sinal: ele se calcula.

---

## 7. Cenários gerados e o que cada um testa

O gerador não produz só o caso fácil. Cada cenário existe para exercitar uma parte do pipeline:

| Cenário | `is_hard` | O que ele testa / ensina |
|---|---|---|
| `clean` | não | Caminho feliz: MCC e merchant coerentes |
| `acquirer_prefixed` | não | **Merchant Resolution**: o descriptor vem mascarado (`PAGSEGURO *LOJA`). Sem unwrap, o lojista real some |
| `international` | não | **international_prior ≠ Viagem**: Steam→Lazer, OpenAI→Serviços, Udemy→Educação, AliExpress→Outros. Só Booking→Viagem |
| `marketplace` | **sim** | Ambiguidade real: `MERCADO LIVRE`/`AMAZON` em MCC genérico. Sem item-level, o melhor que dá é Outros |
| `fuel_convenience` | **sim** | Posto com loja (`SHELL SELECT`): MCC de combustível, mas a compra pode ser conveniência |
| `catch_all` | **sim** | MCC 5999 genérico → Outros. O "fundo do poço" da categorização |
| `filtered` | não | **Filtro/idempotência**: status `Negada`/`Cancelada`. O pipeline deve **barrar**, não categorizar (rótulo `N/A`) |

Repare também na **sobreposição proposital dos valores** (`amount`): viagem tende a ser maior, transporte menor, mas as faixas se cruzam de propósito. É para reforçar que **valor é sinal fraco** de categoria — quem manda é merchant + MCC.

---

## 8. Como você usa isso já agora

1. **Alimentar o esqueleto andante** do Categorization Service (próximo passo) com `synthetic_canonical_events.jsonl`, antes de existir qualquer dado real.
2. **Primeiro arnês de medição**: o `synthetic_labeled_events.jsonl` é seu Gold Eval *de brinquedo* — útil para validar o encanamento e o harness de medição enquanto o Produto não entrega o Gold Eval real.
3. **Testar o Rule Engine e a resolução** contra os cenários `acquirer_prefixed` e `international` assim que eles existirem.

---

## 9. Limites honestos (leia antes de confiar demais)

- **Sintético prova encanamento, não qualidade no mundo real.** Se o pipeline acerta 100% aqui, isso só diz que a plumbing funciona — não que vai bem em produção. O descriptor real é mais sujo e mais variado do que qualquer catálogo que eu escreva.
- **Não calibre a Merchant Resolution contra os padrões deste gerador.** Você estaria ajustando o serviço para acertar os seus próprios padrões inventados. A resolução de verdade se calibra contra o dump real.
- **As proporções são chutes plausíveis, não a distribuição real.** Quando o dump chegar (PBI-15), meça a distribuição verdadeira (% internacional, % adquirente, top MCCs) e ajuste as flags para a massa sintética ficar mais parecida com a realidade.

---

## 10. Próximo passo

O **esqueleto andante do Categorization Service**: consumir `synthetic_canonical_events.jsonl`, passar por uma cascata ainda *stub* (override → regra → merchant KB → MCC KB → Outros) e gravar a decisão com lineage no Decision Store. É a espinha dorsal de engenharia — sua zona de força — sobre a qual todo o resto se pendura.
