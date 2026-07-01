namespace Pfm.Categorization.Contracts;

/// <summary>
/// Taxonomia GLOBAL de categorias do PFM para transações de CARTÃO (14 categorias).
///
/// Importante: esta taxonomia é independente da taxonomia do fluxo de "operationId"
/// (PIX/TED/transferências), que é outro produto e fica em outra tela. Não há sobreposição.
///
/// Produto é o dono da DEFINIÇÃO de cada categoria. O código apenas referencia os nomes.
/// Mudanças na lista devem subir TaxonomyVersion (ver SchemaConstants).
///
/// Usar as constantes (e não strings soltas) garante uma única fonte da verdade entre
/// o gerador, o Categorization Service e o que for persistido.
/// </summary>
public static class PfmCategories
{
    public const string Supermercado = "Supermercado";
    public const string Educacao     = "Educação";
    public const string Investimentos = "Investimentos";
    public const string Transporte   = "Transporte";
    public const string Restaurantes = "Restaurantes";
    public const string Servicos     = "Serviços";
    public const string Saude        = "Saúde";
    public const string Casa         = "Casa";
    public const string Lazer        = "Lazer";
    public const string Combustivel  = "Combustível";
    public const string Eletronicos  = "Eletrônicos";
    public const string Vestuario    = "Vestuário";
    public const string Viagem       = "Viagem";
    public const string Outros       = "Outros";

    /// <summary>Marcador para eventos sintéticos que NÃO deveriam ser categorizados (devem ser filtrados).</summary>
    public const string NotApplicable = "N/A";

    /// <summary>As 14 categorias válidas, na ordem do problema original.</summary>
    public static readonly IReadOnlyList<string> All = new[]
    {
        Supermercado, Educacao, Investimentos, Transporte, Restaurantes,
        Servicos, Saude, Casa, Lazer, Combustivel, Eletronicos,
        Vestuario, Viagem, Outros
    };

    public static bool IsValid(string category) => All.Contains(category);
}
