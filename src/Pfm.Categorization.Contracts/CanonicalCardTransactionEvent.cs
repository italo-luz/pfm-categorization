    namespace Pfm.Categorization.Contracts;

/// <summary>
/// Evento CANÔNICO de transação de cartão — o contrato (PBI-02).
///
/// É a fronteira entre a etapa de ingestão/idempotência e o Categorization Service.
/// NÃO é o evento bruto do core de cartão: campos sensíveis e operacionais foram removidos
/// (ver "campos intencionalmente ausentes" no README).
///
/// Premissas travadas (RFC): só transações LIQUIDADAS/idempotentes chegam aqui; chargeback é
/// tratado fora deste pipeline. Por isso este contrato NÃO modela ciclo de vida/estorno.
///
/// Os campos de "merchant resolvido" começam nulos e são preenchidos pelo Merchant Resolution
/// Service (estágio seguinte), antes da cascata. No JSON, campos nulos são omitidos.
///
/// Convenção: PascalCase em C#, snake_case no JSON (ver CanonicalJson / SnakeCaseLowerNamingPolicy).
/// </summary>
public sealed class CanonicalCardTransactionEvent
{
    // ------------------------------------------------------------------
    // Identidade / versionamento / auditoria
    // ------------------------------------------------------------------

    /// <summary>Versão do schema deste evento. Ver SchemaConstants.CanonicalEventSchemaVersion.</summary>
    public string SchemaVersion { get; set; } = SchemaConstants.CanonicalEventSchemaVersion;

    /// <summary>Chave de idempotência. A deduplicação é feita por este campo NO CONSUMIDOR (não na partição).</summary>
    public string TransactionUuid { get; set; } = "";

    /// <summary>Identificador da compra. Para auditoria/rastreio. NÃO usar como feature de ML.</summary>
    public long PurchaseId { get; set; }

    // ------------------------------------------------------------------
    // Contexto de conta (SENSÍVEL)
    // ------------------------------------------------------------------

    /// <summary>
    /// Conta do portador. SENSÍVEL. Usado como chave de partição (localidade) e, no futuro,
    /// para lookup de override/personalização. NÃO usar como feature no modelo GLOBAL.
    /// </summary>
    public long AccountId { get; set; }

    // ------------------------------------------------------------------
    // Merchant (BRUTO — ainda a ser resolvido)
    // ------------------------------------------------------------------

    /// <summary>
    /// Descriptor bruto do estabelecimento, como vem do adquirente.
    /// Ex.: "MONTAGNER CIA LTDA       CAMPINAS     BR" ou "PAGSEGURO *LOJA DA MARIA".
    /// Alto poder preditivo, mas precisa ser RESOLVIDO (unwrap de adquirente + normalização).
    /// </summary>
    public string MerchantRaw { get; set; } = "";

    /// <summary>ID do estabelecimento fornecido pelo adquirente. Alto poder preditivo (lookup direto).</summary>
    public long MerchantId { get; set; }

    /// <summary>Código adicional do estabelecimento (opcional).</summary>
    public string? MerchantCode { get; set; }

    // ------------------------------------------------------------------
    // Merchant (RESOLVIDO — preenchido pelo Merchant Resolution Service; nulo na origem)
    // ------------------------------------------------------------------

    /// <summary>Assinatura canônica: hash(merchant_resolvido | mcc | país). Preenchido a jusante.</summary>
    public string? MerchantSignature { get; set; }

    /// <summary>Nome do merchant após normalização/unwrap. Preenchido a jusante.</summary>
    public string? MerchantResolvedName { get; set; }

    /// <summary>Cidade extraída do descriptor. Preenchido a jusante.</summary>
    public string? MerchantCity { get; set; }

    /// <summary>País extraído do descriptor (ex.: "BR"). Preenchido a jusante.</summary>
    public string? MerchantCountry { get; set; }

    /// <summary>Indica se o descriptor é de um agregador/gateway (PagSeguro, MP...). Preenchido a jusante.</summary>
    public bool? IsAggregator { get; set; }

    // ------------------------------------------------------------------
    // MCC
    // ------------------------------------------------------------------

    /// <summary>Merchant Category Code (ISO 18245). Muito alto poder preditivo. Base de regra/feature/prior.</summary>
    public int Mcc { get; set; }

    /// <summary>Descrição textual do MCC. Ex.: "EATING PLACES AND RESTAURANTS".</summary>
    public string? MccDescription { get; set; }

    /// <summary>Grupo do MCC (pré-agrupamento que acelera o seed). Ex.: 14.</summary>
    public int MccGroupId { get; set; }

    /// <summary>Descrição do grupo de MCC. Ex.: "Eating/Drinking".</summary>
    public string? MccGroupDescription { get; set; }

    // ------------------------------------------------------------------
    // Natureza da transação
    // ------------------------------------------------------------------

    /// <summary>Tipo de transação (id). Diferencia compra, tarifa, saque etc. Ex.: "318".</summary>
    public string? TransactionTypeId { get; set; }

    /// <summary>Descrição do tipo de transação. Ex.: "A vista sem juros - Visa".</summary>
    public string? TransactionTypeDescription { get; set; }

    /// <summary>Status textual. Ex.: "Processada".</summary>
    public string? Status { get; set; }

    /// <summary>Status numérico. 2 = liquidada (ver SchemaConstants.StatusIdSettled).</summary>
    public int StatusId { get; set; }

    /// <summary>Modo de entrada (presencial/online/aproximação). Ex.: "0510". Contexto auxiliar.</summary>
    public string? EntryMode { get; set; }

    /// <summary>Origem técnica/bandeira. Ex.: "VSN". Baixo/médio poder preditivo.</summary>
    public string? Origin { get; set; }

    /// <summary>Origem de resolução. Ex.: "BII". Operacional.</summary>
    public string? ResolutionOrigin { get; set; }

    /// <summary>Se a transação foi tokenizada (wallet/digital). Baixo poder para categoria.</summary>
    public bool IsTokenizedTransaction { get; set; }

    // ------------------------------------------------------------------
    // Valores (dinheiro -> decimal, nunca double)
    // ------------------------------------------------------------------

    /// <summary>Valor da transação (BRL). Poder preditivo BAIXO para categoria (auxiliar; não domina).</summary>
    public decimal Amount { get; set; }

    /// <summary>Número de parcelas. Relevante para CONTAGEM de gasto no PFM (fora deste pipeline), não para categoria.</summary>
    public int Installment { get; set; }

    /// <summary>Valor da primeira parcela.</summary>
    public decimal? AmountFirstInstallment { get; set; }

    /// <summary>Valor das próximas parcelas.</summary>
    public decimal? AmountNextInstallment { get; set; }

    /// <summary>
    /// IOF cobrado. SINAL FORTE de transação internacional (compõe o international_prior).
    /// Atenção: internacional NÃO implica Viagem — é feature, não regra de Viagem.
    /// </summary>
    public decimal IofAmount { get; set; }

    // ------------------------------------------------------------------
    // Moeda / câmbio (compõem o international_prior)
    // ------------------------------------------------------------------

    /// <summary>Código ISO 4217 numérico da moeda. 986 = BRL. != 986 => internacional.</summary>
    public int CurrencyCode { get; set; }

    /// <summary>Taxa de câmbio aplicada. != 1 => indício de internacional.</summary>
    public decimal ExchangeRate { get; set; }

    // ------------------------------------------------------------------
    // Datas (UTC)
    // ------------------------------------------------------------------

    /// <summary>Data/hora da compra (UTC).</summary>
    public DateTimeOffset PurchaseDate { get; set; }

    /// <summary>Data/hora de processamento (UTC). Mais operacional que semântico.</summary>
    public DateTimeOffset ProcessingDate { get; set; }

    /// <summary>Data/hora de autorização (opcional).</summary>
    public DateTimeOffset? AuthorizationDate { get; set; }

    // ------------------------------------------------------------------
    // Derivado (NÃO é fato de origem; é método, não propriedade, de propósito)
    // ------------------------------------------------------------------

    /// <summary>
    /// international_prior derivado: IOF>0 OU moeda != BRL OU câmbio != 1.
    /// Exposto como MÉTODO (não serializado) para deixar explícito que é DERIVADO,
    /// e que "internacional" é feature/sinal — não regra direta de Viagem.
    /// </summary>
    public bool IsInternational()
        => IofAmount > 0m
        || CurrencyCode != SchemaConstants.CurrencyCodeBrl
        || ExchangeRate != 1m;
}
