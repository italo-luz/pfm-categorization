# HANDOFF.md — PFM v2: Categorização Multi-Fonte, Fina e Personalizada

> Documento de retomada de sessão. Se você está lendo isto numa conversa nova: leia inteiro antes de continuar o trabalho. As seções "Restrições" e "Decisões" não são sugestões — são o que já foi fechado e não deve ser revisitado sem motivo novo.

---

## 1. Objetivo atual

Evoluir o PFM (Personal Financial Manager) de um banco digital, hoje limitado a **categorização macro** de transações do **core banking** (via `operationId` → transferência, salário, fatura, investimento, etc.), para também categorizar **gastos em 14 categorias finas** (Supermercado, Restaurantes, Transporte, Saúde, Lazer, etc.) cobrindo **todos os meios de pagamento**: cartão, PIX, TED, boletos e concessionárias/utilities.

A categorização fina é entregue por uma **Plataforma de Categorização isolada** (novo microserviço), consultada pelo `pfm-etl` existente. O usuário pode **recategorizar** transações e **criar categorias/regras próprias**, e essas correções alimentam a evolução futura do sistema (ML/RL/LLM), que está **fora do escopo desta entrega**.

**Onde estamos no processo:** RFC fechada e aprovada → plano de execução quebrado em Épico/Features/PBIs → PBIs em processo de detalhamento card-ready para entrarem no Azure DevOps → refinamento de detalhes de contrato em andamento (ver §7, próximos passos).

**Fase atual do trabalho:** detalhamento fino do contrato `categorize` (F1-PBI-1) — nomenclatura de campos de correlação/idempotência acabou de ser fechada (ver §3).

---

## 2. Arquivos produzidos (nesta ordem lógica)

| Arquivo | Conteúdo | Status |
|---|---|---|
| `rfc-v1-mcc-first-multifonte-personalizacao.md` | RFC arquitetural completa (v1 do produto = "v2 do PFM") | ✅ Aprovada, é a fonte de verdade da arquitetura |
| `rfc-v1-DIFF-integracao-serving.md` | Diff aditivo aplicado à RFC (integração com o serving) | ✅ Já incorporado ao arquivo da RFC acima |
| `one-page-alta-gestao-categorizacao-pfm.md` | Resumo executivo para gestão não-técnica | ✅ Pronto, não depende do resto |
| `plano-execucao-pfm-v2-epico-features-pbis.md` | Primeira quebra em Épico → Features → PBIs (nível raso) | ⚠️ Superado pelo arquivo abaixo — manter só como histórico |
| `spec-pfm-v2-parte1-prereqs-plataforma.md` | Primeira tentativa de spec detalhado (só pré-requisitos + trilha plataforma) | ⚠️ **Superado** pelo arquivo abaixo — não usar |
| `spec-pfm-v2-completo-pbis-card-ready.md` | **Documento vivo atual.** Todos os PBIs (F1–F7) card-ready, com DoR (definições de refinamento) embutido em cada card | ✅ **É o documento a atualizar e usar daqui para frente** |

**Regra prática:** para tudo que for continuar, parta de `rfc-...md` (arquitetura) + `spec-pfm-v2-completo-pbis-card-ready.md` (backlog). Os dois arquivos de spec "Parte 1" e o plano raso ficam só como histórico de como se chegou até aqui — não retrabalhar a partir deles.

---

## 3. Decisões arquiteturais tomadas (não revisitar sem motivo novo)

### 3.1 Estratégia geral
- **Inversão consciente de prioridade:** a v1 do produto sacrifica acurácia (cartão categorizado só por MCC) em troca de velocidade, custo baixo e cobertura total de meios de pagamento desde o dia 1. A inteligência (ML, embeddings, LLM, Reinforcement Learning) é **adiada para v3**, não removida — os componentes adiados têm slot reservado na arquitetura.
- **O fallback da v1 é o usuário, não uma LLM.** Baixa confiança/ambiguidade → `Outros` + flag de correção na UI, não uma chamada de IA. Por isso a UX de correção é tratada como **infraestrutura**, não detalhe de produto.
- **Gold Eval Set formal foi descartado na v1** (custo de rotulagem humana). No lugar, **telemetria passiva** (taxa de correção por fonte/categoria, `% Outros`, distribuição) mede o baseline de graça, a partir do próprio loop de feedback. O gold set formal é pré-requisito do v3 (ML), não da v1.
- **Personalização foi antecipada** da Fase 3 (plano original) para a v1, o que **obrigou a antecipar também a resolução de entidade** (é o que faz um override "grudar" na próxima transação da mesma entidade).

### 3.2 Duas taxonomias coexistindo (decisão fechada, não unificar)
- **Macro-categorização** (transferência, salário, fatura, investimento) — vem do `operationId` do **core banking**, processada no `pfm-etl` **inalterada**. É o que aparece no **extrato**.
- **Categorização fina** (as 14 categorias) — produzida pela **Plataforma de Categorização**, para eventos **sem** `operationId` (cartão, PIX, TED, boleto, utility detalhados). É o que aparece na **tela de gastos**.
- **P2P (PIX/TED para CPF) → `Outros`** na taxonomia fina. **Não** existe categoria fina "Transferências" — decisão deliberada para não canibalizar a macro-categoria "transferência" que já existe.
- Divergência aceita por design: a mesma transação PIX pode aparecer como "transferência" no extrato e "Outros" na tela de gastos.

### 3.3 Roteamento no ETL
- O `pfm-etl` é um **roteador**: evento com `operationId` (hoje só o core banking) → segue no fluxo macro existente, inalterado. Evento **sem** `operationId` (cartão, PIX, TED, boleto, utility) → chama a Plataforma de Categorização via `categorize`.
- A chamada à plataforma é **síncrona mas não é dependência dura**: timeout + circuit breaker + fallback para `Outros` se a plataforma cair. A queda da plataforma nunca paralisa o PFM.

### 3.4 Ancoragem de override — decisão consciente contra o MCC
- Override do usuário no **cartão** é ancorado em **`merchant_id`** (vem no evento, granularidade por estabelecimento), **não em MCC**. Motivo: ancorar em MCC faria a correção de *um* estabelecimento vazar para *todos* do mesmo tipo — especialmente grave no MCC 5999 ("varejo diverso"), um balde de centenas de lojas sem relação.
- Override em **PIX/TED/boleto** é ancorado em **CNPJ** (já é granularidade por estabelecimento).
- Hierarquia da cascata: **override do estabelecimento específico** (`merchant_id`/CNPJ) **vence** **regra do tipo** (`MCC`/`CNAE`) **vence** **baseline**. Mesmo modelo mental para cartão e PIX.
- Regras do usuário (nível 2) na v1 são **só** `código → categoria pré-definida` (MCC/CNAE → categoria), sem condição de valor, sem lógica composta.

### 3.5 Baseline determinístico por fonte
| Fonte | Chave de entidade | "Código de atividade" | Fonte do código |
|---|---|---|---|
| Cartão | `merchant_id` | MCC | próprio evento |
| PIX / TED (PJ) | CNPJ | CNAE | lookup CNPJ→CNAE (base Receita) |
| Boleto (cobrança) | CNPJ do beneficiário | CNAE | código de barras → CNPJ → CNAE |
| Utilities | biller/segmento | — | Biller Registry (quase determinístico, confiança alta) |
| PIX/TED P2P (CPF) | — | — | → `Outros` direto (`p2p_default`) |

`ambiguity_level` (LOW/MED/HIGH) por MCC/CNAE decide se o baseline **afirma** a categoria ou **defere** para `Outros` + flag de correção. HIGH nunca afirma.

### 3.6 Sem Lifecycle Service / máquina de estado
Hoje só se ingerem **eventos finais** (sem "volta"), então não há necessidade de Lifecycle Service. Fica adiado para quando (se) entrarem estados intermediários. Parcela de cartão é tratada por **regra básica de deduplicação**, não por serviço. ⚠️ **Depende de confirmar** se o parcelado chega como 1 evento (compra cheia) ou N eventos (um por parcela) — ver §6, pendência aberta.

### 3.7 Modelo de dados do serving (schema `serving`, existente)
- **Um fato, duas dimensões de categoria** — não duplicar a `FactTransaction`. Adicionar `ExpenseCategoryId` (fina) como segunda dimensão na mesma linha, ao lado do `CategoryId` (macro) existente.
- `CategoryId` (macro) passa a ser **nullable**: compras de cartão viram **linhas fina-only** (sem contraparte no extrato — a fatura agregada já existe separadamente). Membership de tela por presença de coluna: `CategoryId IS NOT NULL` → aparece no extrato; `ExpenseCategoryId IS NOT NULL` → aparece em gastos.
- **Nova dimensão `serving.DimExpenseCategory`** (não misturar com `DimCategory`, que é macro): campo `Scope` (0=global/as 14, 1=usuário) + `OwnerClientId` (null para global). **`ExpenseCategoryId` é PK sem IDENTITY** — o id é atribuído pela **Plataforma**, não pelo serving (ver §3.9, ranges de id).
- **Correção obrigatória numa query existente:** a query de total do extrato (`TotalCredit`/`TotalDebit`/`Result`) precisa ganhar `WHERE CategoryId IS NOT NULL`, senão compras de cartão fina-only fariam o extrato contar o mesmo dinheiro duas vezes (fatura + compras individuais).
- Índices de gastos são **filtrados** (`WHERE ExpenseCategoryId IS NOT NULL`) para ficarem pequenos e rápidos, espelhando os índices macro existentes.

### 3.8 Merge macro↔fina — independente de ordem, sem coluna nova
- **Chave de correlação/merge = `OriginalTransactionId`** — já existe no serving, já é usada hoje pelo fluxo de recategorização do salário (portabilidade). **Nenhuma coluna nova de correlação é criada.**
- **PIX/TED/boleto/utility (overlap):** upsert por `OriginalTransactionId`. Se a macro chega primeiro, `UPDATE` completa a fina. Se a **fina chega primeiro**, o ETL **bufferiza** o resultado (a transação já está em `truth.TransactionEvent`; a decisão já está no Decision Store da plataforma) e aplica quando a macro chegar.
- **Cartão:** sempre `INSERT` de linha fina-only — nunca passa pelo merge, porque não tem contraparte macro no core banking.

### 3.9 Contrato de identificadores — ⚠️ decisão recém-fechada, crítica
Esta é a decisão mais recente da sessão anterior; **não reabrir sem revisar o histórico completo desta conversa sobre o assunto**, porque a nomenclatura já passou por 3 rodadas de refinamento.

- **`original_transaction_id`** (nome do campo no contrato `categorize`, ver §5): é o **id nativo da transação no sistema de origem** — não é um token sintético de correlação. Exemplo real do PFM: o PIX gera esse id, envia ao core banking para liquidar (lá é chamado `correlation_id`), e o evento chega ao PFM já com esse mesmo valor. A correlação macro↔fina é uma **consequência** de as duas pernas herdarem o mesmo id de origem — não é o propósito primário do campo.
  - Para **PIX/TED/boleto/utility**: funciona como chave de correlação real e cruzada entre fontes (é o que viabiliza o merge/backfill).
  - Para **cartão**: é só o id da compra no sistema de cartão, **sem** contraparte no core banking — a compra individual nunca passa por lá (só a fatura agregada). Coerente com "cartão = fina-only, sem merge".
  - Nome final escolhido: **`original_transaction_id`** (não `correlation_id`, não `source_transaction_id`) — consistente com a coluna `OriginalTransactionId` já existente no serving.
- **`source_event_id`**: identidade de **um evento específico** dentro daquela transação (ex.: `transaction_uuid` do cartão, `e2eid` do PIX). É a chave de **idempotência de negócio** (`UNIQUE(Source, SourceEventId, SeedVersion)` no Decision Store).
- **Por que os dois campos NUNCA devem ser colapsados em um só**, mesmo quando o valor coincide (PIX/TED/boleto/utility, onde é ~1:1): no **cartão parcelado**, `original_transaction_id` é o **mesmo** para as N parcelas (é a mesma transação), mas `source_event_id` é **distinto** por parcela (é um evento por parcela). Se os campos forem colapsados, a chave de idempotência trata as N parcelas como o mesmo evento e **descarta silenciosamente** 9 de 10 parcelas — sem erro, só perda de dado. **Regra: campos sempre separados no contrato; valores podem coincidir onde a fonte for genuinamente 1:1, mas isso não deve virar regra de schema.**
- **`request_id`**: identifica só a **tentativa de chamada HTTP** (para retry/timeout). **Não é gravado no Decision Store** — vive em log/trace, é efêmero. Se um dia precisar de idempotência de transporte (cache de resposta por chamada), é um store separado com TTL curto, nunca a tabela de decisão.

---

## 4. RFC — resumo (fonte completa em `rfc-v1-mcc-first-multifonte-personalizacao.md`)

**Título:** Plataforma de Categorização Multi-Fonte — v1 "MCC-first + Personalização Antecipada".

**Estrutura do documento (para navegação rápida):**
- §0–§1: resumo executivo e reframe da mudança de estratégia (vs. plano original que tinha ML na Fase 2).
- §2: escopo IN da v1 (baseline por fonte, personalização, taxonomia).
- §3: escopo OUT / adiado para v2+ (ML, embeddings, LLM, RL, Lifecycle, Gold Eval formal).
- §4: arquitetura de referência — diagrama mermaid com **workflow numerado** (passos 1–11 + F1–F4 do loop de feedback), e limites de deploy (o que é microserviço vs. módulo in-process vs. dado vs. job vs. infra — só **1 microserviço novo**: a Plataforma).
- §5: modelo de decisão / cascata.
- §6: modelo de dados essencial + **§6.2: integração com o serving do PFM** (a seção mais densa — merge, DDL, queries).
- §7: uso dos atributos por fonte.
- §8: diferença componente a componente vs. plano original (tabela de rastreabilidade).
- §9: passo a passo de implementação (a base do que virou o plano de execução).
- §10: riscos específicos desta estratégia.
- §11: como a v1 alimenta o v3 (handoff de dados para ML/RL/LLM futuros).
- §12: frases de defesa para ARB/gestão.
- Anexo: decisões fechadas × abertas.

**Status:** aprovada. Mudanças posteriores (integração com o serving) já foram incorporadas via diff — o arquivo está com a versão final consolidada.

---

## 5. Contratos já detalhados campo a campo (fechados nesta sessão)

Estes contratos estão descritos dentro dos respectivos PBIs em `spec-pfm-v2-completo-pbis-card-ready.md`, mas o `categorize` recebeu revisão adicional nesta sessão de conversa (nomenclatura, ver §3.9) que **ainda não foi propagada ao arquivo .md** — ver §7, próximos passos.

**`POST /v1/categorize`** (F1-PBI-1) — síncrono, ETL → Plataforma, sem PII:
- Request: `request_id`, `source`, `source_event_id`, `original_transaction_id` (⚠️ nome atualizado nesta sessão — no arquivo ainda consta como `correlation_id`, ver §7), `occurred_at`, `amount`, `currency`, `user_scope{trading_account, brand}`, `entity{type, merchant_id, document, biller_id}`, `signals{mcc, cnae, installment, iof_amount}`.
- Response: `request_id`, `expense_category{id, code}`, `decision_source`, `confidence`, `flagged_for_review`, `is_user_category`, `versions{seed, taxonomy, rules}`, `explain` (opcional).
- Regras: sempre 200 com categoria (inclusive Outros); 5xx só em falha total; timeout alvo p99<150ms; ETL usa timeout 300ms + circuit breaker.

**`POST /v1/recategorize`** (F3-PBI-2) — síncrono, PFM → Plataforma:
- Request: `request_id`, `user_scope`, `entity`, `target_category{kind, id, new_user_category}`, `origin`.
- Response: `override_id`, `applied`, `resolved_category`, `user_category_created`.
- Idempotência = upsert por `(trading_account, brand, entity_key)`.

**Evento `pfm.user_category.upserted`** (F3-PBI-5 → F5-PBI-4) — Plataforma → PFM, via Kafka, com **outbox pattern** para garantir entrega. Id da categoria de usuário atribuído pela Plataforma (range ≥100000).

**Convenções transversais** (referenciadas por vários PBIs, não repetidas em cada um):
- Enum `decision_source`: `user_override | user_rule | mcc | cnae | biller | p2p_default | outros_fallback`.
- Faixas de confiança estáticas por `decision_source` (0.99 override → 0.30 outros_fallback).
- Ranges de id: `1–999` = as 14 globais (seed idêntico plataforma+serving); `≥100000` = categorias de usuário.

---

## 6. Épicos, Features e PBIs (visão geral — detalhe completo em `spec-pfm-v2-completo-pbis-card-ready.md`)

**Épico:** PFM v2 — Categorização Multi-Fonte, Fina e Personalizada.

**Trilha A — Plataforma de Categorização (👤 dono: você)**
- **F1 — Serviço, Cascata e Baseline:** 6 PBIs (esqueleto+endpoint, orchestrator, baseline por fonte, decision store, confiança/resiliência, entity keying).
- **F2 — Bases de Conhecimento:** 5 PBIs (MCC KB, CNAE KB, CNPJ→CNAE/Receita, Biller Registry, contrato de lookup). Dono ainda **⬜ indefinido** (você ou delegado).
- **F3 — Personalização:** 5 PBIs (override nível 1, `recategorize`+feedback, regras nível 2, categorias do usuário nível 3, propagação ao PFM).
- **F4 — Feedback e Telemetria:** 2 PBIs (Feedback Store, telemetria passiva + dashboards + gatilho do v3).

**Trilha B — PFM-ETL + Serving + Cargas (👥 dono: time)**
- **F5 — Modelo de Dados do Serving:** 4 PBIs (migração de schema, seed das 14 + ajuste da query do extrato, queries de gastos, projeção de categoria do usuário).
- **F6 — Ingestão Online Multi-Fonte:** roteador+resiliência, escrita por merge, **5 adapters por fonte** (card/pix/ted/boleto/utility, um PBI cada, template replicável), DLQ+reprocessamento.
- **F7 — Carga/Backfill de 1 ano (Etapa 6):** pipeline de reprocessamento batch, UPDATE para pix/ted/boleto/utility (dados já existem no serving), INSERT fina-only para cartão (carga real — não existia), reconciliação backfill×online.

**Ordem de execução:** Onda 1 (fundação — fechar os DoR de fronteira no refinamento) → Onda 2 (construção paralela: plataforma vs. ETL/serving, ETL pode começar contra mock da plataforma) → Onda 3 (integração real + backfill por último).

**Formato de cada PBI no arquivo .md:** Objetivo · 🔒 Definições para o refinamento (DoR, com contrato/DDL sugerido) · Como implementar (design + pseudocódigo/DDL) · Critério de aceite (DoD) · Casos de teste/edge cases · Tasks · Depende de / Consumido por.

---

## 7. Próximos passos

1. **Propagar a decisão de nomenclatura da §3.9 para o arquivo `spec-pfm-v2-completo-pbis-card-ready.md`:** trocar `correlation_id` por `original_transaction_id` no contrato do F1-PBI-1, e reforçar (com o exemplo do parcelado) a nota de que `original_transaction_id` e `source_event_id` nunca devem ser colapsados — isso ainda não foi escrito no arquivo, só decidido na conversa.
2. **Continuar o detalhamento campo a campo dos demais contratos** (o usuário está fazendo isso PBI a PBI): `recategorize` (F3-PBI-2) e o schema canônico (F6-PBI-1) foram oferecidos mas ainda não destrinchados como o `categorize` foi.
3. **Resolver os placeholders `⬜` antes/durante o refinamento com o time** (lista consolidada no fim do arquivo `spec-...card-ready.md`):
   - Payloads reais dos tópicos Kafka por fonte (pix/ted/boleto/utility — hoje só SUGESTÃO; card é real).
   - Modelos reais dos dumps de cada produto para o backfill + confirmar presença de `original_transaction_id` em cada um (crítico — sem isso o UPDATE do backfill vira casamento heurístico).
   - **Parcelado de cartão: chega como 1 evento ou N eventos?** (decide a regra de dedupe do F6, e reforça se `original_transaction_id`/`source_event_id` realmente divergem no cartão — ver §3.9).
   - Campos exatos de `user_scope` no `categorize` (privacidade — `trading_account`+`brand` bastam ou precisa hash?).
   - F2 (Bases de Conhecimento): você faz ou delega?
   - Categorias do usuário nível 3: v1 ou fast-follow? CRUD de regra (nível 2) já na v1?
   - Cadência de atualização da base CNPJ→CNAE (Receita).
   - Confirmar os números **SUGESTÃO** (faixas de confiança, ranges de id) — são propostas, não verdades.
   - Gatilho objetivo para acionar o v3 (ML/RL/LLM): taxa de correção X% ou N rótulos/categoria.
4. **Criar os cards no Azure DevOps** a partir do `spec-...card-ready.md`, um PBI por card, usando o bloco DoR como checklist de entrada em refinamento.
5. **Rodar o refinamento com o time**, PBI por PBI, preenchendo os `⬜` e ajustando as `SUGESTÃO` conforme a realidade dos produtos.

---

## 8. Restrições que devem ser preservadas

Estas não são preferências — são invariantes de design que, se quebradas, comprometem decisões já validadas (algumas contra risco real de banco, como double-counting de dinheiro no extrato).

1. **Macro e fina são taxonomias separadas e devem continuar assim.** Não criar categoria fina "Transferências"; não misturar `DimCategory` (macro) com `DimExpenseCategory` (fina) na mesma tabela.
2. **A query de total do extrato precisa ter `WHERE CategoryId IS NOT NULL`** assim que compras de cartão fina-only começarem a existir no serving — sem isso, o extrato conta dinheiro em dobro (fatura + compras individuais). Não é opcional.
3. **Override do cartão é ancorado em `merchant_id`, nunca em MCC.** Ancorar em MCC vaza correção entre estabelecimentos não relacionados (grave no MCC 5999).
4. **`original_transaction_id` e `source_event_id` são campos sempre separados no contrato**, mesmo quando o valor coincide para uma fonte específica. Nunca assumir/documentar que são o mesmo campo — o cartão parcelado quebra essa suposição silenciosamente.
5. **A chamada `categorize` do ETL para a Plataforma nunca pode ser dependência dura.** Timeout + circuit breaker + fallback para `Outros` sempre. A Plataforma cair não pode paralisar o PFM.
6. **A Plataforma sempre responde com uma categoria** (nunca "não sei" sem categoria) — no pior caso, `outros_fallback` com `flagged_for_review=true`. Falha de KB interna não deve virar 5xx.
7. **Nenhuma coluna nova de correlação no serving.** O merge usa `OriginalTransactionId`, que já existe — não recriar/duplicar essa chave.
8. **Sem PII no contrato `categorize`:** nunca PAN, nunca `card_id`/`account_id` cru. Escopo de usuário só via `trading_account`+`brand`.
9. **Cartão nunca passa pelo merge macro↔fina** — é sempre `INSERT` de linha fina-only, porque não existe contraparte no core banking (a compra individual não liquida lá, só a fatura agregada).
10. **`ExpenseCategoryId` é PK sem IDENTITY no serving** — o id é atribuído e possuído pela Plataforma (ranges: 1–999 global, ≥100000 usuário) e propagado ao serving, nunca gerado localmente por ele. Quebrar isso cria split-brain de identidade entre os dois sistemas.
11. **Escopo desta entrega não inclui ML, embeddings, LLM ou Reinforcement Learning.** Esses componentes têm slot reservado na arquitetura (cascata plugável) mas não devem ser implementados agora — o objetivo da v1 é justamente gerar, via Feedback Store, o dado que eles vão precisar.
12. **Toda decisão de categorização é versionada e reprocessável** (`seed_version`/`rules_version`/`taxonomy_version`) — reprocessar não deve sobrescrever histórico, e sim gerar uma nova linha versionada no Decision Store.

---

## 9. Como retomar esta sessão

Ao continuar em uma nova conversa: (1) carregue este `HANDOFF.md`; (2) carregue `rfc-v1-mcc-first-multifonte-personalizacao.md` se a discussão for arquitetural; (3) carregue `spec-pfm-v2-completo-pbis-card-ready.md` se a discussão for sobre um PBI específico; (4) verifique a §7 (Próximos Passos) para saber exatamente onde o trabalho parou; (5) antes de propor qualquer mudança de nome/contrato/schema, confira a §8 (Restrições) e a §3.9 (nomenclatura de identificadores) — esses pontos já passaram por múltiplas rodadas de refinamento e não devem ser reabertos sem um motivo novo e explícito.
