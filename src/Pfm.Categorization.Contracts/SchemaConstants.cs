namespace Pfm.Categorization.Contracts;

/// <summary>
/// Constantes versionadas e valores de domínio do contrato.
///
/// Estas versões viajam com a decisão no Decision Store (lineage). É o que torna o
/// reprocessamento reproduzível: dado o mesmo evento e as mesmas versões, o resultado é idêntico.
/// </summary>
public static class SchemaConstants
{
    /// <summary>Versão do contrato do evento canônico. Suba em QUALQUER mudança breaking de schema.</summary>
    public const string CanonicalEventSchemaVersion = "card-canonical-v1";

    /// <summary>Versão da taxonomia das 14 categorias (Produto é dono).</summary>
    public const string TaxonomyVersion = "pfm-card-taxonomy-v1";

    /// <summary>Código ISO 4217 numérico do Real (BRL). currency_code != 986 indica internacional.</summary>
    public const int CurrencyCodeBrl = 986;

    /// <summary>status_id de transação liquidada/processada (do evento de exemplo). Só estas seguem o pipeline.</summary>
    public const int StatusIdSettled = 2;
}
