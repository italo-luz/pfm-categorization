# Spec de Implementação — PFM v2 (consolidado, card-ready)
## Épico → Features → PBIs (com DoR embutido) → Tasks

> **Substitui** o documento "Parte 1". Aqui estão **todos** os PBIs das duas trilhas, cada um pronto para virar card no Azure DevOps.
> **Template de cada PBI:** *Objetivo* · **🔒 Definições para o refinamento (DoR)** — o que precisa ser fechado para o card entrar na sprint (contrato/schema/decisão, já com minha sugestão) · *Como implementar* (design + pseudocódigo/DDL) · *Critério de aceite (DoD)* · *Casos de teste / edge cases* · *Tasks* · *Depende de / Consumido por*.
> **`SUGESTÃO`** = proposto por mim sem a informação real; é exatamente o que o refinamento valida.
> **Legenda:** 👤 Você (plataforma) · 👥 Time (ETL/serving/cargas) · 🔀 costura entre trilhas.

---

## Convenções compartilhadas (referência — citada pelos PBIs; não é card)

Estas definições valem para vários PBIs. Onde um PBI depende de uma delas, ele cita "(ver Convenções)".

- **Enum `decision_source`:** `user_override | user_rule | mcc | cnae | biller | p2p_default | outros_fallback`.
- **Faixas de confiança (estáticas na v1) `SUGESTÃO`:**

  | decision_source | confidence | flagged_for_review |
  |---|---|---|
  | user_override | 0.99 | não |
  | user_rule | 0.95 | não |
  | biller | 0.95 | não |
  | mcc/cnae — ambiguity LOW | 0.90 | não |
  | mcc/cnae — ambiguity MED | 0.70 | não |
  | p2p_default (Outros esperado) | 0.60 | não |
  | outros_fallback (ambíguo/desconhecido) | 0.30 | **sim** |

  `ambiguity=HIGH` **não afirma** → vira `outros_fallback` (flag=sim).
- **Ranges de id de categoria (id compartilhado plataforma↔serving) `SUGESTÃO`:** `1–999` = as 14 globais (seed idêntico dos dois lados); `≥100000` = categorias de usuário (atribuídas pela plataforma). Permite o `categorize` devolver o `id` direto e o ETL gravar `ExpenseCategoryId` sem lookup.
- **Correlação macro↔fina:** `OriginalTransactionId` (já existe no serving).
- **Idempotência de negócio:** `(source, source_event_id)`.
- **Versionamento:** `seed_version` / `rules_version` / `taxonomy_version` em toda decisão (reprocesso reprodutível).

---

## Épico

**PFM v2 — Categorização Multi-Fonte, Fina e Personalizada.** Categorizar todos os meios de pagamento (cartão, PIX, TED, boletos, utilities) em 14 categorias finas para a tela de gastos, com o usuário podendo recategorizar/criar regras e categorias, mantendo a macro-categorização (extrato) intacta. Plataforma isolada consultada pelo `pfm-etl`.

**Mapa de dependências (ondas):**
- **Onda 1 (destrava):** fechar no refinamento os DoR dos PBIs de fronteira — `categorize` (F1-PBI-1), `recategorize` (F3-PBI-2), canônico (F6-PBI-1), taxonomia/ids (F5-PBI-2 ↔ Convenções), DDL do serving (F5-PBI-1).
- **Onda 2 (paralelo):** 👤 F1+F2+F3 · 👥 F5+F6 (F6 contra mock da plataforma). F4 quando F3-PBI-2 existir.
- **Onda 3 (integração + histórico):** troca do mock pelo serviço real · F7 (Etapa 6) por último.

---

# TRILHA A — PLATAFORMA DE CATEGORIZAÇÃO (👤)

## Feature F1 — Serviço, Cascata e Baseline
Microserviço (monólito modular) que expõe `categorize`, roda a cascata determinística e grava lineage. **Invariante: sempre responde com categoria** (pior caso `outros_fallback`). Arquitetura interna: `Api → CascadeOrchestrator → (OverlayModule, BaselineModule) → KbGateway/Stores`, tudo in-process, KB cacheada.

### F1-PBI-1 — Esqueleto do serviço + endpoint `categorize` + observabilidade 🔀
**Objetivo:** subir o serviço e o endpoint (contrato) para o time integrar já (mesmo com cascata stub).
**🔒 Definições para o refinamento (DoR) — Contrato `categorize` `SUGESTÃO`:**
`POST /v1/categorize` (síncrono, ETL→plataforma, sem PII):
```jsonc
// Request
{
  "request_id": "uuid",                 // idempotência da CHAMADA (retry)
  "source": "card",                     // card|pix|ted|boleto|utility
  "source_event_id": "514382642",       // idempotência de NEGÓCIO
  "correlation_id": "guid",             // == OriginalTransactionId
  "occurred_at": "2024-03-04T16:38:00Z",
  "amount": 32.50, "currency": "BRL",
  "user_scope": { "trading_account": 2165226, "brand": 1 },  // sem PAN/card_id/account_id
  "entity": { "type": "pj", "merchant_id": "2485725", "document": null, "biller_id": null },
  "signals": { "mcc": 5812, "cnae": null, "installment": 1, "iof_amount": 0 }
}
// Response 200
{
  "request_id": "uuid",
  "expense_category": { "id": 5, "code": "restaurantes" },   // id compartilhado (ver Convenções)
  "decision_source": "mcc", "confidence": 0.90,
  "flagged_for_review": false, "is_user_category": false,
  "versions": { "seed": "mcc-2026-01", "taxonomy": "pfm-fina-v1", "rules": "u-2026-01" },
  "explain": { "mcc": 5812, "ambiguity": "LOW" }             // opcional
}
```
Regras a validar: **sempre 200 com categoria** (inclusive `Outros`); 5xx só em falha total. Timeout alvo p99<150ms; ETL usa timeout 300ms + circuit breaker + fallback `Outros`. Idempotência determinística por `(source, source_event_id, seed_version)`. Erros: 400/422/503. `⬜ A DEFINIR:` campos exatos de `user_scope` (privacidade).
**Como implementar:** camadas Api/Domínio/Infra. `CascadeOrchestrator` stub retornando `outros_fallback`. Log estruturado por `request_id`, trace, métricas (latência, contagem por decision_source).
```text
POST /v1/categorize:
  validar(req) -> 400 se inválido; 422 se source/entidade insuficiente
  ctx = ContextBuilder.build(req)      # normaliza, amount_bucket, entity_key
  decision = cascade.decide(ctx)       # stub: outros_fallback
  persist(decision)                    # F1-PBI-4 (stub: no-op)
  return map(decision)                 # response PR
```
**DoD:** serviço sobe; endpoint responde 200 conforme contrato (stub→Outros flag=sim); `/health`; métricas; testes de contrato verdes.
**Casos de teste:** válido→200 Outros; sem `source`→400; source inválido→422; latência medida.
**Tasks:** [ ] bootstrap (camadas/DI/config) · [ ] `ContextBuilder` · [ ] endpoint + validação/mapeamento · [ ] health/log/trace/metrics · [ ] testes de contrato + latência.
**Consumido por:** F6-PBI-1 (ETL chama).

### F1-PBI-2 — Cascade Orchestrator (plugável, precedência) 👤
**Objetivo:** orquestrar estágios em ordem, parar no primeiro que afirma; deferral sempre resolve.
**🔒 DoR:** ordem fixa dos estágios `[UserOverride, UserRule, Baseline]` + passo 4 (deferral). Interface `ICategoryStage`.
**Como implementar:**
```text
stages = [ UserOverrideStage, UserRuleStage, BaselineStage ]
decide(ctx):
  for s in stages: r = s.Try(ctx); if r.affirms: return r.decision
  return Decision(OUTROS, outros_fallback, 0.30, flagged=true)
```
Overlay stubs (no-op) para F3 preencher.
**DoD:** precedência override>regra>baseline>Outros comprovada; deferral sempre resolve.
**Casos de teste:** só baseline afirma→baseline; override+baseline→override; ninguém→outros_fallback; ordem coberta.
**Tasks:** [ ] `ICategoryStage`/`StageResult` · [ ] orquestrador short-circuit + passo 4 · [ ] overlay stubs · [ ] testes de precedência.

### F1-PBI-3 — Baseline Categorizer por fonte 👤
**Objetivo:** decidir por fonte (MCC/CNAE/biller) + P2P→Outros.
**🔒 DoR:** ver Convenções (faixas/ambiguity). Interface `KbGateway` (F2-PBI-5).
**Como implementar:**
```text
BaselineStage.Try(ctx):
  switch ctx.source:
    card: kb=mccKB.get(ctx.signals.mcc); return kb? applyAmbiguity(kb,"mcc") : defer()
    pix|ted|boleto:
      if ctx.entity.type==CPF: return affirm(OUTROS,"p2p_default",0.60,flag=false)
      cnae = ctx.signals.cnae ?? cnpjCnae.get(ctx.entity.document)?.cnae
      kb = cnae? cnaeKB.get(cnae):null; return kb? applyAmbiguity(kb,"cnae") : defer()
    utility: b=billerRegistry.get(ctx.entity.biller_id); return b? affirm(b.cat,"biller",0.95):defer()
applyAmbiguity(kb,src): LOW→affirm(kb.cat,src,0.90); MED→affirm(kb.cat,src,0.70); HIGH→defer()
```
**DoD:** cada fonte resolve; desconhecido→defer; HIGH→defer; P2P→Outros(flag=não); biller→0.95.
**Casos de teste:** 5812 LOW→restaurantes 0.90; 5999 HIGH→Outros flag=sim; PIX CNPJ supermercado→supermercado; PIX CPF→Outros p2p; PIX PJ sem CNAE→defer; ENEL→0.95; boleto arrecadação→biller; boleto cobrança→cnae.
**Tasks:** [ ] switch por fonte · [ ] resolução CNAE (direto→CNPJ) · [ ] `applyAmbiguity` · [ ] P2P→Outros · [ ] fixtures/testes por fonte.

### F1-PBI-4 — Decision Store + reprocessamento 👤
**Objetivo:** persistir toda decisão com lineage; reprocesso reprodutível.
**🔒 DoR — DDL do Decision Store `SUGESTÃO`:**
```sql
CREATE TABLE plat.CategorizationDecision (
  DecisionId BIGINT IDENTITY PRIMARY KEY,
  Source VARCHAR(16) NOT NULL, SourceEventId VARCHAR(64) NOT NULL,
  OriginalTxnId UNIQUEIDENTIFIER NULL, TradingAccount BIGINT NOT NULL, Brand SMALLINT NOT NULL,
  ExpenseCategoryId INT NOT NULL, DecisionSource VARCHAR(24) NOT NULL,
  Confidence DECIMAL(4,3) NOT NULL, FlaggedForReview BIT NOT NULL,
  SeedVersion VARCHAR(32) NULL, RulesVersion VARCHAR(32) NULL, TaxonomyVersion VARCHAR(32) NULL,
  SignalsJson NVARCHAR(MAX) NULL, CreatedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT UQ_Decision UNIQUE (Source, SourceEventId, SeedVersion)   -- idempotência/reprocesso
);
```
**Como implementar:** gravar no fim da cascata; `UNIQUE` garante idempotência; reprocesso = recomputar com nova `seed_version` gerando nova linha (não sobrescreve histórico).
**DoD:** decisão gravada com lineage+versões; reexecução mesma versão não duplica; nova versão gera nova linha reproduzível.
**Casos de teste:** grava/lê; reprocesso idempotente; reprocesso nova versão; consulta por `OriginalTxnId`.
**Tasks:** [ ] repositório · [ ] gravação · [ ] rotina de reprocessamento por versão · [ ] testes idempotência.

### F1-PBI-5 — Confiança estática + deferral + resiliência da KB 👤
**Objetivo:** aplicar faixas (Convenções) e garantir "nunca 5xx por causa de KB".
**🔒 DoR:** faixas configuráveis (ver Convenções); política de cache/refresh da KB.
**Como implementar:** faixas de config; se `KbGateway` falhar/vazia → **defer** (não lança) → `outros_fallback`. KB em cache com refresh; falha de refresh mantém último cache.
**DoD:** faixas aplicadas; KB down→Outros flag=sim (não 5xx); cache com fallback.
**Casos de teste:** KB derrubada→Outros (não 5xx); confiança bate a tabela; refresh falho mantém cache.
**Tasks:** [ ] config faixas · [ ] `KbGateway` cache/refresh/fallback · [ ] garantir "nunca lança por KB" · [ ] testes resiliência.

### F1-PBI-6 — Entity keying trivial 👤
**Objetivo:** derivar `entity_key`/`entity_type` (base do override), sem NLP.
**🔒 DoR:** regra por fonte: key = merchant_id (card) | CNPJ (pix/ted/boleto) | biller_id (utility); type = pj/cpf/unknown.
**Como implementar:** no `ContextBuilder`; normalização mínima (trim/upper).
**DoD:** key/type corretos por fonte; sem id→unknown (não quebra; baseline defere).
**Casos de teste:** card→merchant_id; pix PJ→CNPJ/pj; pix CPF→cpf; utility→biller_id; sem id→unknown.
**Tasks:** [ ] derivação por fonte · [ ] normalização mínima · [ ] testes.

## Feature F2 — Bases de Conhecimento (Seeds) — 👤 você **ou** delegado (`⬜ decisão sua`)
Dado versionado por `seed_version`; construção: mapa curado + refino de `ambiguity` com a distribuição histórica quando houver telemetria. F1 consome via `KbGateway`.

### F2-PBI-1 — MCC KB 👤/⬜
**Objetivo:** `mcc → categoria + prior + ambiguity`.
**🔒 DoR — DDL `SUGESTÃO`:**
```sql
CREATE TABLE plat.MccKB (Mcc INT PRIMARY KEY, ExpenseCategoryId INT NOT NULL,
  Prior DECIMAL(4,3) NOT NULL, AmbiguityLevel VARCHAR(4) NOT NULL, SeedVersion VARCHAR(32) NOT NULL);
-- (5812,5,0.90,'LOW',...) (5999,14,0.30,'HIGH',...)
```
+ política dos genéricos (5999, 5311 depto, 5541 posto) = `HIGH`/`MED`. Cobertura mínima: top-N MCCs por volume.
**Como implementar:** lista oficial MCC → mapear 14 + prior + ambiguity; seed idempotente por versão.
**DoD:** MCCs relevantes mapeados; genéricos=HIGH; cobertura top-N; versionado.
**Casos de teste:** 5812→restaurantes LOW; 5999→outros HIGH; 5541→combustível MED; inexistente→null.
**Tasks:** [ ] obter/mapear lista · [ ] política genéricos · [ ] seed versionado + validação amostral · [ ] teste cobertura.

### F2-PBI-2 — CNAE KB 👤/⬜
Análogo ao F2-PBI-1 (DDL `plat.CnaeKB` idêntico com `Cnae VARCHAR(9) PK`). CNAE é mais granular → menos ambiguidade. **DoD/testes/tasks** análogos.

### F2-PBI-3 — CNPJ→CNAE (base Receita) 👤/⬜
**Objetivo:** tabela `CnpjCnae` para resolver CNAE por CNPJ.
**🔒 DoR — DDL + fonte:**
```sql
CREATE TABLE plat.CnpjCnae (Cnpj CHAR(14) PRIMARY KEY, Cnae VARCHAR(9) NOT NULL, UpdatedAt DATETIME2(3) NOT NULL);
```
`⬜ A DEFINIR:` cadência de atualização da base Receita.
**Como implementar:** ingestão bulk da base pública (dezenas de milhões de linhas); PK por CNPJ.
**DoD:** carregada e consultável por CNPJ; processo de atualização definido.
**Casos de teste:** CNPJ conhecido→CNAE; ausente→null; performance do lookup.
**Tasks:** [ ] pipeline bulk · [ ] índice/PK · [ ] cadência · [ ] teste lookup/volume.

### F2-PBI-4 — Biller Registry 👤/⬜
**🔒 DoR — DDL `SUGESTÃO`:** `plat.BillerRegistry (BillerId VARCHAR(32) PK, ExpenseCategoryId INT, Confidence DECIMAL(4,3) DEFAULT 0.95, SeedVersion VARCHAR(32))`. Energia/água/gás→Casa/Serviços; telecom→Serviços.
**DoD/testes/tasks:** billers principais mapeados; lookup por biller_id; validação.

### F2-PBI-5 — Contrato de lookup das KBs (`KbGateway`) 🔀(interno)
**Objetivo:** interface estável que F1 consome (desacopla F1↔F2).
**🔒 DoR:** assinatura `KbGateway` (get MCC/CNAE/CNPJ→CNAE/biller) + `seed_version` exposta.
**DoD:** interface publicada; F1 integra sem conhecer storage; versão exposta.
**Tasks:** [ ] definir interface · [ ] implementar sobre tabelas · [ ] testes de contrato (stub→real com F1).

## Feature F3 — Personalização: Overlay, Regras e Categorias do Usuário 👤
Níveis 1–3 + `recategorize` + propagação. Plataforma = dona da verdade das categorias do usuário.

### F3-PBI-1 — Store de override + estágio na cascata (nível 1) 👤
**🔒 DoR — DDL `SUGESTÃO`:**
```sql
CREATE TABLE plat.UserOverride (OverrideId UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
  TradingAccount BIGINT NOT NULL, Brand SMALLINT NOT NULL, EntityKey VARCHAR(64) NOT NULL,
  ExpenseCategoryId INT NOT NULL, CreatedAt DATETIME2(3) DEFAULT SYSUTCDATETIME(), UpdatedAt DATETIME2(3) NULL,
  CONSTRAINT UQ_Override UNIQUE (TradingAccount, Brand, EntityKey));  -- upsert
```
**Como implementar:** `UserOverrideStage` (1º estágio) faz lookup `(account,brand,entity_key)`; afirma `user_override` 0.99.
**DoD:** override vence baseline/regra; ausência→skip; resolve categoria de usuário (is_user_category).
**Casos de teste:** override merchant_id vence MCC; override CNPJ vence CNAE; sem override→skip; aponta p/ user category.
**Tasks:** [ ] repositório (upsert) · [ ] estágio no passo 1 · [ ] testes precedência.

### F3-PBI-2 — Endpoint `recategorize` (idempotente) + feedback 🔀
**Objetivo:** gravar a correção do usuário; criar categoria de usuário se preciso; emitir propagação.
**🔒 DoR — Contrato `recategorize` `SUGESTÃO`:**
`POST /v1/recategorize`:
```jsonc
// Request
{ "request_id":"uuid",
  "user_scope":{"trading_account":2165226,"brand":1},
  "entity":{"type":"pj","merchant_id":"2485725","document":null},
  "target_category":{"kind":"global","id":9,"new_user_category":null}, // kind=user + {name:"Café"} p/ criar
  "origin":"manual_correction" }
// Response 200
{ "override_id":"uuid","applied":true,
  "resolved_category":{"id":9,"code":"lazer","is_user_category":false},
  "user_category_created":null }   // {id:100017,name:"Café"} quando cria
```
Idempotência = upsert por `(account,brand,entity_key)`. `kind=user`+`new_user_category` → cria UserCategory (id≥100000), aponta override, emite PR de propagação (F3-PBI-5). Grava FeedbackEvent sempre.
**Como implementar:**
```text
POST /v1/recategorize:
  cat = resolveTarget(req)                 # global(1..999) OU cria user category(>=100000)
  overrides.upsert(scope, entity_key, cat.id)
  feedback.append(scope, entity_key, from=vigente?, to=cat.id, origin)
  if cat.created: publish(user_category.upserted)   # F3-PBI-5
  return {override_id, resolved_category:cat, user_category_created?}
```
**DoD:** upsert idempotente; criação atribui id no range + emite evento; feedback gravado.
**Casos de teste:** recategorizar global→override atualizado; reenviar→sem duplicar; criar "Café"→UserCategory+evento+override; feedback registrado.
**Tasks:** [ ] endpoint + resolução target · [ ] upsert idempotente · [ ] criação UserCategory + publish · [ ] FeedbackEvent · [ ] testes.
**Consumido por:** front/PFM (quem chama).

### F3-PBI-3 — Regras do usuário (nível 2) 👤
**🔒 DoR — DDL `SUGESTÃO`:**
```sql
CREATE TABLE plat.UserRule (RuleId UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
  TradingAccount BIGINT NOT NULL, Brand SMALLINT NOT NULL,
  MatchKind VARCHAR(8) NOT NULL, MatchValue VARCHAR(9) NOT NULL,   -- mcc|cnae + valor
  ExpenseCategoryId INT NOT NULL, Priority INT DEFAULT 100, Active BIT DEFAULT 1,
  CONSTRAINT UQ_Rule UNIQUE (TradingAccount,Brand,MatchKind,MatchValue));
```
Só "código→categoria pré-definida". `⬜ escopo: CRUD de regra já na v1?`
**Como implementar:** `UserRuleStage` (2º estágio) match por mcc/cnae do `ctx.signals`; afirma `user_rule` 0.95.
**DoD:** regra casa por mcc/cnae; override (nível 1) vence regra; regra vence baseline.
**Casos de teste:** regra mcc=5999→Eletrônicos aplica; override do merchant vence regra; sem regra→skip.
**Tasks:** [ ] repositório (upsert) · [ ] estágio no passo 2 · [ ] CRUD mínimo (⬜) · [ ] testes precedência.

### F3-PBI-4 — Categorias do usuário (nível 3) + split global/user 👤
**🔒 DoR — DDL `SUGESTÃO`:**
```sql
CREATE TABLE plat.UserCategory (ExpenseCategoryId INT PRIMARY KEY,   -- range >=100000 (plataforma atribui)
  TradingAccount BIGINT NOT NULL, Brand SMALLINT NOT NULL, Name VARCHAR(50) NOT NULL,
  DisplayOrder INT NOT NULL, Active BIT DEFAULT 1, CreatedAt DATETIME2(3) DEFAULT SYSUTCDATETIME());
```
`⬜ decisão: v1 ou fast-follow`. Split: global(1..999) nunca alterada; user à parte, só afeta a conta.
**DoD:** categoria isolada por conta; não afeta outros; id no range; aparece só p/ o dono.
**Casos de teste:** "Café" da conta A não existe p/ B; override p/ "Café" resolve; listagem por conta = global + da conta.
**Tasks:** [ ] modelo + range · [ ] endpoint criação/edição · [ ] isolamento por conta · [ ] ⬜ decisão escopo.

### F3-PBI-5 — Propagação de categoria do usuário → PFM 🔀
**Objetivo:** emitir evento para o PFM projetar em `DimExpenseCategory (Scope=1)`.
**🔒 DoR — Evento `pfm.user_category.upserted` `SUGESTÃO`:**
```jsonc
{ "event_id":"uuid","op":"upsert",           // upsert|deactivate
  "user_scope":{"trading_account":2165226,"brand":1},
  "user_category":{"id":100017,"name":"Café","parent_global_category_id":null,"display_order":100,"active":true},
  "occurred_at":"..." }
```
Id atribuído pela plataforma e reusado no serving (ver Convenções).
**Como implementar:** publicar via **outbox** (não perder evento se publish falhar após commit).
**DoD:** evento publicado de forma confiável (outbox); id compartilhado; op upsert/deactivate.
**Casos de teste:** criar→1 evento; editar nome→upsert; desativar→deactivate; falha de publish→outbox reenvia.
**Tasks:** [ ] publish (outbox) · [ ] upsert/deactivate · [ ] teste entrega confiável.
**Consumido por:** F5-PBI-4 (PFM projeta).

## Feature F4 — Feedback e Telemetria 👤
Substitui o gold set formal na v1 pela telemetria passiva.

### F4-PBI-1 — Feedback Store consolidado 👤
**🔒 DoR — DDL `SUGESTÃO`:**
```sql
CREATE TABLE plat.FeedbackEvent (FeedbackId BIGINT IDENTITY PRIMARY KEY,
  TradingAccount BIGINT NOT NULL, Brand SMALLINT NOT NULL, EntityKey VARCHAR(64) NOT NULL,
  Source VARCHAR(16) NULL, FromCategoryId INT NULL, ToCategoryId INT NOT NULL,
  Origin VARCHAR(24) NOT NULL, CreatedAt DATETIME2(3) DEFAULT SYSUTCDATETIME());
```
`from` = categoria vigente antes da correção.
**Como implementar:** já gravado no `recategorize`; garantir from/to; (opcional) visão materializada de override efetivo.
**DoD:** todo recategorize gera FeedbackEvent com from/to; consultável por conta/entidade; reaproveitável como rótulo (v3).
**Casos de teste:** correção→feedback from/to corretos; consulta por conta; por entidade.
**Tasks:** [ ] preencher from (vigente) · [ ] índices de consulta · [ ] (opc) visão materializada.

### F4-PBI-2 — Telemetria passiva + dashboards 👤
**Objetivo:** métricas que medem a v1 sem gold set, e base do gatilho do v3.
**🔒 DoR:** definição das métricas: taxa de correção por fonte/categoria (feedback/decisões), `% Outros`, distribuição, `% por decision_source`, latência p50/p95/p99; limiares de alerta; **gatilho do v3** (taxa X% ou N rótulos/categoria).
**Como implementar:** derivar de `CategorizationDecision` + `FeedbackEvent`; dashboards + alertas.
**DoD:** dashboards por fonte; alerta mínimo (`% Outros`, taxa de correção); gatilho do v3 documentado.
**Casos de teste:** dashboards refletem dados sintéticos; alerta dispara no limiar; taxa de correção calculada certo.
**Tasks:** [ ] instrumentar métricas · [ ] dashboards · [ ] alertas · [ ] documentar gatilho v3.

---

# TRILHA B — PFM-ETL + SERVING + CARGAS (👥)

## Feature F5 — Modelo de Dados do Serving (PFM)
Implementa a migração já desenhada (§6.2 da RFC) + queries de gastos + projeção de categorias do usuário.

### F5-PBI-1 — Migração de schema (DimExpenseCategory + FactTransaction) 👥
**Objetivo:** aplicar a segunda dimensão de categoria no serving sem duplicar o fato.
**🔒 DoR — DDL (com correção importante vs. §6.2):**
```sql
-- ATENÇÃO: ExpenseCategoryId é PK SEM IDENTITY (id atribuído pela plataforma; ranges nas Convenções)
CREATE TABLE serving.DimExpenseCategory (
  ExpenseCategoryId INT PRIMARY KEY,           -- NÃO identity (1..999 global; >=100000 user)
  CategoryName VARCHAR(50) NOT NULL, CategoryCode VARCHAR(50) NOT NULL,
  Scope TINYINT NOT NULL,                       -- 0=global | 1=user
  OwnerClientId INT NULL, DisplayOrder INT NOT NULL,
  CreatedAt DATETIME2(3) DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_ExpCat_Owner FOREIGN KEY (OwnerClientId) REFERENCES serving.DimClient(ClientId));

ALTER TABLE serving.FactTransaction ALTER COLUMN CategoryId INT NULL;  -- macro nullable (metadados)
ALTER TABLE serving.FactTransaction ADD ExpenseCategoryId INT NULL
  CONSTRAINT FK_Fact_ExpenseCategory REFERENCES serving.DimExpenseCategory(ExpenseCategoryId);

CREATE NONCLUSTERED INDEX IDX_Fact_List_Expense_DateDesc
  ON serving.FactTransaction (ClientId, ExpenseCategoryId, OccurredAt DESC, TransactionId)
  INCLUDE (Amount, Description, DateId, OriginalTransactionId) WHERE ExpenseCategoryId IS NOT NULL;
-- + estender IDX_FactTransaction_Agg_Client_Date p/ INCLUDE ExpenseCategoryId
-- + índice de lookup por OriginalTransactionId (p/ o merge — F6-PBI-2)
```
**Como implementar:** `ALTER` de nullable é metadados (não reescreve); criar índices **online** (tabela grande/particionada); plano de rollback.
**DoD:** migração aplicada em teste; índices criados; planos de query usam os novos índices; rollback testado.
**Casos de teste:** migração + rollback; `ALTER` nullable não reescreve; build de índice online não trava.
**Tasks:** [ ] DDL DimExpenseCategory (PK não-identity) · [ ] ALTER CategoryId + ADD ExpenseCategoryId + FK · [ ] índices (filtrado + agregação + lookup OriginalTransactionId) · [ ] rollback.

### F5-PBI-2 — Seed das 14 (Scope=0, ids fixos) + ajuste da query do extrato 👥🔀
**Objetivo:** popular as 14 com **os mesmos ids da plataforma** e corrigir o total do extrato.
**🔒 DoR:** tabela de id fixo das 14 (1..999) **igual** ao seed da plataforma (ver Convenções). Confirmar o mapeamento code↔id com F1/F0.
**Como implementar:** seed com ids explícitos; **alterar a query de total do extrato** para `WHERE CategoryId IS NOT NULL` (senão compras de cartão fina-only dobram o total).
**DoD:** seed aplicado (ids batem com a plataforma); total do extrato ganha o filtro; regressão: totais atuais não mudam.
**Casos de teste:** ids serving == ids plataforma; total do extrato inalterado p/ dados atuais; após inserir 1 compra de cartão fina-only, total do extrato **não** muda.
**Tasks:** [ ] seed 14 com ids fixos · [ ] ajustar query de total do extrato · [ ] teste de regressão do extrato.

### F5-PBI-3 — Queries de gastos (agregação + listagem) 👥
**Objetivo:** telas de gastos com performance equivalente ao extrato.
**🔒 DoR:** a agregação dirige pela dimensão (mostra baldes vazios) filtrando `WHERE Scope=0 OR OwnerClientId=@ClientId`; listagem filtra `ExpenseCategoryId IS NOT NULL` com keyset pagination (`OccurredAt DESC, TransactionId`).
**Como implementar:** espelhar as queries macro atuais, trocando `CategoryId`→`ExpenseCategoryId` e `DimCategory`→`DimExpenseCategory` (com o filtro de escopo).
**DoD:** agregação correta (global + categorias da conta); listagem paginada estável; usa os índices filtrados.
**Casos de teste:** agregação com categorias de usuário; baldes vazios aparecem; paginação keyset estável; plano usa índice filtrado.
**Tasks:** [ ] query agregação de gastos · [ ] query listagem de gastos · [ ] validar índices · [ ] teste de performance.

### F5-PBI-4 — Projeção de categorias do usuário (consome evento) 👥🔀
**Objetivo:** projetar categoria de usuário no serving a partir do evento da plataforma.
**🔒 DoR:** contrato do evento `pfm.user_category.upserted` (dono: F3-PBI-5). Resolver `OwnerClientId` a partir de `trading_account`+`brand` (via `DimClient`).
**Como implementar:** consumidor idempotente → upsert em `DimExpenseCategory (Scope=1, OwnerClientId, id da plataforma)`; op deactivate → `Active`/soft-delete.
**DoD:** upsert idempotente; id == id da plataforma; deactivate tratado; fora de ordem tolerado.
**Casos de teste:** criar→linha Scope=1; reenviar→sem duplicar; deactivate; id bate.
**Tasks:** [ ] consumidor do evento · [ ] resolver OwnerClientId · [ ] upsert Scope=1 (id externo) · [ ] testes idempotência/ordem.

## Feature F6 — Ingestão Online Multi-Fonte no PFM-ETL 👥
O `pfm-etl` consome tópicos por fonte, produz o canônico, roteia, chama a plataforma e escreve no serving por merge. Pode começar contra **mock** da plataforma (contrato F1-PBI-1).

### F6-PBI-1 — Roteador do ETL + resiliência 👥🔀
**Objetivo:** rotear macro×fina e blindar o PFM de quedas da plataforma.
**🔒 DoR — Schema canônico `SUGESTÃO`:**
```jsonc
{ "transaction_id":"guid","original_transaction_id":"guid","source":"card",
  "source_event_id":"514382642","trading_account":2165226,"brand":1,
  "transaction_type":0,"amount":32.50,"currency":"BRL","occurred_at":"...",
  "entity":{"type":"pj","merchant_id":"2485725","document":null,"biller_id":null},
  "installment":{"number":1,"count":1},"raw_signals":{"mcc":5812,"iof_amount":0},
  "operation_id":null }   // != null => fluxo MACRO (não chama plataforma)
```
Regra de roteamento: `operation_id != null` → macro (inalterado); `== null` → `categorize`. Cliente da plataforma: timeout 300ms + circuit breaker + fallback `Outros`.
**Como implementar:** consumir → construir canônico → rotear → (detalhado) chamar plataforma → enriquecer → escrever no serving (F6-PBI-2).
**DoD:** roteamento por `operation_id`; queda da plataforma → grava `Outros` e segue (não paralisa); testes de resiliência.
**Casos de teste:** evento com operation_id→macro; sem→plataforma; plataforma down→Outros; CB abre/fecha.
**Tasks:** [ ] roteamento · [ ] cliente com timeout/CB · [ ] fallback Outros · [ ] testes resiliência.

### F6-PBI-2 — Escrita no serving por merge (`OriginalTransactionId`) 👥🔀
**Objetivo:** escrever a fina no fato certo, independente de ordem; cartão = insert fina-only.
**🔒 DoR:** semântica de merge + store de **buffer** (fina-antes-de-macro) + regra: overlap = upsert por `OriginalTransactionId`; card = insert fina-only; o **path macro (operationId) ganha um passo** de "checar buffer de fina". TTL/reprocesso como rede de segurança.
**Como implementar:**
```text
onDetailedResult(canonical, cat):        # após categorize
  otid = canonical.original_transaction_id
  if canonical.source == 'card':
     fact.insertFinaOnly(otid, expense=cat, macro=NULL, ...)   # compra de cartão (sem linha macro)
     return
  row = fact.findByOriginalTxnId(otid)   # overlap: pix/ted/boleto/utility
  if row: fact.update(row, expense=cat)  # macro já lá -> completa a fina
  else:   buffer.put(otid, {expense:cat})# fina chegou antes -> bufferiza

onMacroEnrich(coreBankingTxn):           # fluxo operationId (EXISTENTE + passo novo)
  otid = coreBankingTxn.original_transaction_id
  fact.upsert(otid, macro=cat_macro, ...)        # cria/atualiza com macro
  p = buffer.get(otid)
  if p: fact.update(otid, expense=p.expense); buffer.remove(otid)   # aplica fina bufferizada
```
Cartão: `original_transaction_id` = id da própria compra (sem contraparte macro).
**DoD:** upsert independente de ordem; card insere fina-only; PIX fina-primeiro é bufferizado e completado na macro; reentrega idempotente; buffer com TTL/reprocesso.
**Casos de teste:** macro-primeiro→update fina; fina-primeiro→buffer→macro aplica; card→insert fina-only; reentrega não duplica; estorno (evento final separado) entra como novo fato; buffer órfão (macro nunca vem) coberto por TTL/reprocesso.
**Tasks:** [ ] upsert por OriginalTransactionId · [ ] insert fina-only (card) · [ ] buffer + passo no path macro · [ ] TTL/reprocesso do buffer · [ ] testes das duas ordens + idempotência.

### F6-PBI-3…7 — Adapter por fonte (1 card cada: card, pix, ted, boleto, utility) 👥
> Replicar por fonte. Cada um é independente e paralelizável.
**Objetivo (por fonte):** consumir o tópico e normalizar para o canônico.
**🔒 DoR (por fonte) — Payload do tópico `SUGESTÃO` (validar o real):**
- **card:** payload real do problema (merchant_id, mcc, installment, iof, transaction_uuid→source_event_id, status). `⬜ de onde vem OriginalTransactionId`.
- **pix `SUGESTÃO`:** `{ e2eid→source_event_id, correlation_id→OriginalTransactionId (⬜ confirmar), trading_account, brand, direction, amount, counterparty:{type,document,name}, occurred_at, description }`.
- **ted `SUGESTÃO`:** como pix, id próprio→source_event_id; counterparty document (CNPJ/CPF).
- **boleto `SUGESTÃO`:** `{ boleto_id→source_event_id, correlation_id, barcode, segment:cobranca|arrecadacao, beneficiary:{document,name}, amount }`.
- **utility `SUGESTÃO`:** `{ payment_id→source_event_id, correlation_id, biller_id→entity.biller_id, biller_segment, amount }`.
`⬜ A DEFINIR (por fonte):` payload real + chave/particionamento do tópico + origem do `OriginalTransactionId`.
**Como implementar (por fonte):** consumir → mapear para canônico (PR do F6-PBI-1) → extrair sinais (código de atividade + entity_key) → idempotência por `source_event_id` → (card) regra de parcela → DLQ.
**DoD (por fonte):** consome o tópico; normaliza; extrai sinais/entity_key; idempotente; (card) parcela; DLQ.
**Casos de teste (por fonte):** happy path→canônico; duplicado→idempotente; (card) parcelado não conta N vezes (⬜ 1 evento vs N); payload inválido→DLQ.
**Tasks (por fonte):** [ ] consumidor do tópico · [ ] mapear→canônico · [ ] extrair sinais/entity_key · [ ] idempotência source_event_id · [ ] (card) regra de parcela — `⬜ 1 evento ou N?` · [ ] DLQ · [ ] testes.

### F6-PBI-8 — DLQ + reprocessamento online 👥
**🔒 DoR:** DLQ por fonte com motivo; política de replay por janela.
**DoD:** DLQ por fonte; replay por janela; métricas de lag/erro.
**Tasks:** [ ] DLQ por fonte · [ ] replay · [ ] métricas lag/erro.

## Feature F7 — Carga e Backfill de 1 Ano (Etapa 6) 👥 — por último
PIX/TED/boleto/utility = **UPDATE** dos dados que já existem no serving (vieram do core banking), por `OriginalTransactionId`. Cartão = **carga real** (INSERT fina-only), pois o PFM já nasce com 1 ano.

### F7-PBI-1 — Pipeline de reprocessamento em batch (idempotente) 👥
**Objetivo:** consumir dump → categorizar via plataforma → escrever no serving, de forma reexecutável.
**🔒 DoR — Modelo do dump `SUGESTÃO`:** por produto: campos + **presença de `OriginalTransactionId`** (crítico p/ overlap). `⬜ A DEFINIR:` nome/local/formato/volume/janela de cada dump.
**Como implementar:** ler dump em lotes → chamar `categorize` em batch (com throttling p/ não afogar a plataforma) → escrever no serving; idempotência por chave (`UNIQUE`/upsert).
**DoD:** batch idempotente (reexecução não duplica); controlável por janela/produto; throttling da plataforma.
**Casos de teste:** reexecução não duplica; throttling respeitado; retomada após falha.
**Tasks:** [ ] leitor de dump (lotes) · [ ] chamada batch à plataforma (throttle) · [ ] escrita serving · [ ] idempotência/retomada · [ ] ⬜ formato dos dumps.

### F7-PBI-2 — Backfill UPDATE (pix/ted/boleto/utility) 👥
**Objetivo:** completar a fina no histórico existente.
**🔒 DoR:** o dump de cada fonte **traz `OriginalTransactionId`**? (se não, vira casamento heurístico — risco a decidir).
**Como implementar:** casar dump ↔ linha histórica do serving por `OriginalTransactionId` → `UPDATE ExpenseCategoryId` em lote; medir cobertura; tratar não-casados.
**DoD:** UPDATE por OriginalTransactionId; cobertura medida; não-casados reportados.
**Casos de teste:** casa e atualiza; não-casado (dump sem linha)→relatório; linha já atualizada pelo online→não regride (ver F7-PBI-4).
**Tasks:** [ ] casamento por OriginalTransactionId · [ ] UPDATE em lote · [ ] cobertura/relatório · [ ] tratar não-casados.

### F7-PBI-3 — Carga cartão (INSERT fina-only) de 1 ano 👥
**Objetivo:** inserir as compras de cartão do último ano (sem linha macro).
**🔒 DoR:** volume real de 1 ano de cartão (pode ser **centenas de milhões** de linhas) → estratégia de **bulk load alinhado à partição** (por YearMonth), gestão de índices (desabilitar/reconstruir por partição), batelada.
**Como implementar:** ler dump de cartão → categorizar → **bulk INSERT** de linhas fina-only (`CategoryId=NULL`, `ExpenseCategoryId=cat`, `OriginalTransactionId`=id da compra); carregar por mês/partição.
**DoD:** INSERT fina-only de 1 ano; sem linha macro; performance de carga aceitável (particionada); cobertura medida.
**Casos de teste:** volume por mês; índices reconstruídos; total do extrato **não** afetado (fina-only); cobertura.
**Tasks:** [ ] ler dump cartão (1 ano) · [ ] categorizar em lote · [ ] bulk insert por partição · [ ] gestão de índices · [ ] métricas volume/cobertura.

### F7-PBI-4 — Reconciliação backfill × online (evitar dupla escrita) 👥
**Objetivo:** a carga não conflita com o que o online já gravou.
**🔒 DoR:** regra de precedência — **override do usuário nunca é sobrescrito**; linhas já categorizadas pelo online para a mesma chave não são reprocessadas/dobradas.
**Como implementar:** antes de escrever, checar existência/precedência; `UPDATE` só onde `ExpenseCategoryId IS NULL` (overlap) e sem override; relatório de cobertura por fonte.
**DoD:** sem dupla escrita; override preservado; relatório de cobertura.
**Casos de teste:** linha já com fina do online→backfill não regride; linha com override→preservado; corrida backfill×online coberta.
**Tasks:** [ ] regra de precedência (online/override vence) · [ ] evitar dupla escrita (`WHERE ExpenseCategoryId IS NULL`) · [ ] relatório de cobertura.

---

## Ordem sugerida (ondas)
1. **Refinamento dos DoR de fronteira (destrava):** F1-PBI-1 (`categorize`), F3-PBI-2 (`recategorize`), F6-PBI-1 (canônico), F5-PBI-1/2 (DDL serving + ids), F3-PBI-5 (evento de propagação).
2. **Paralelo:** 👤 F1→F2→F3→F4 · 👥 F5→F6 (contra mock).
3. **Integração + histórico:** troca mock→serviço real · F7 por último.

## Placeholders consolidados (para você preencher no refinamento)
- `⬜` De onde vem o `OriginalTransactionId` em cada tópico/dump (o que faz merge e UPDATE do backfill funcionarem). *(F6-PBI-3…7, F7-PBI-2)*
- `⬜` Payloads reais dos tópicos pix/ted/boleto/utility. *(F6-PBI-3…7)*
- `⬜` Modelos reais dos dumps + presença de correlação + volume/janela. *(F7-PBI-1)*
- `⬜` Campos de `user_scope` no `categorize` (privacidade). *(F1-PBI-1)*
- `⬜` Parcelado de cartão: 1 evento ou N? *(F6-PBI-3…7)*
- `⬜` F2 (KBs): você faz ou delega?
- `⬜` Categorias do usuário (nível 3): v1 ou fast-follow? *(F3-PBI-4)* · CRUD de regra na v1? *(F3-PBI-3)*
- `⬜` Cadência CNPJ→CNAE (Receita). *(F2-PBI-3)*
- `⬜` Confirmar números SUGERIDOS: faixas de confiança e ranges de id. *(Convenções)*
- `⬜` Precedência backfill×online e gatilho do v3. *(F7-PBI-4, F4-PBI-2)*

## Correspondência com a RFC
F1↔§4.3/§5 · F2↔§2.1 · F3↔§2.2/§6.2 · F4↔§3/§11 · F5↔§6.2 · F6↔§4.1/§4.2/§6.2 · F7↔§6.2. **Correção vs §6.2:** `DimExpenseCategory.ExpenseCategoryId` é **PK sem IDENTITY** (id atribuído pela plataforma; ver Convenções).
