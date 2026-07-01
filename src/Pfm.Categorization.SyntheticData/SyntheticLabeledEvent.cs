using Pfm.Categorization.Contracts;

namespace Pfm.Categorization.SyntheticData;

/// <summary>
/// Artefato de TESTE: envelopa o evento canônico com o rótulo verdadeiro e o cenário gerado.
///
/// ATENÇÃO: expected_category e scenario NÃO existem no contrato real nem em produção.
/// Servem só para (1) medir a acurácia do pipeline contra uma verdade conhecida e
/// (2) depurar por cenário. O pipeline NUNCA deve enxergar o rótulo.
///
/// Por isso o gerador escreve DOIS arquivos:
///  - synthetic_labeled_events.jsonl   (com rótulo) -> seu arnês de medição
///  - synthetic_canonical_events.jsonl (sem rótulo) -> o que o pipeline realmente recebe
/// </summary>
public sealed class SyntheticLabeledEvent
{
    /// <summary>O evento canônico, idêntico ao que o pipeline receberá.</summary>
    public required CanonicalCardTransactionEvent Event { get; set; }

    /// <summary>Categoria verdadeira (porque nós geramos). "N/A" para eventos que devem ser filtrados.</summary>
    public required string ExpectedCategory { get; set; }

    /// <summary>Tag do cenário (clean, acquirer_prefixed, international, marketplace, fuel_convenience, catch_all, filtered).</summary>
    public required string Scenario { get; set; }

    /// <summary>Dica de dificuldade: true em casos intrinsecamente ambíguos (marketplace, catch-all, posto+conveniência).</summary>
    public bool IsHard { get; set; }
}
