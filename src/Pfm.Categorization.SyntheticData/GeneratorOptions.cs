using System.Globalization;

namespace Pfm.Categorization.SyntheticData;

/// <summary>
/// Opções do gerador. Tudo parametrizável via linha de comando: <c>--chave valor</c>.
///
/// A <see cref="Seed"/> é o que torna a massa REPRODUTÍVEL: mesma seed => exatamente a mesma massa.
/// Isso é higiene básica de engenharia de dados — você quer poder regerar o mesmo dataset.
/// </summary>
public sealed class GeneratorOptions
{
    /// <summary>Quantidade de eventos a gerar.</summary>
    public int Count { get; set; } = 10_000;

    /// <summary>Semente do gerador aleatório (reprodutibilidade).</summary>
    public int Seed { get; set; } = 42;

    /// <summary>Diretório de saída dos arquivos .jsonl.</summary>
    public string OutDir { get; set; } = "./out";

    /// <summary>Se true, grava JSON indentado (debug). Padrão false (JSON Lines, 1 evento por linha).</summary>
    public bool Indented { get; set; } = false;

    // --- Proporções (0..1). O restante vira cenário "normal/clean". ---

    /// <summary>Fração de casos difíceis/ambíguos (marketplace, catch-all, posto+conveniência).</summary>
    public double HardCaseRatio { get; set; } = 0.15;

    /// <summary>Fração de descriptors com prefixo de adquirente/gateway (PAGSEGURO*, MP*, ...).</summary>
    public double AcquirerPrefixRatio { get; set; } = 0.25;

    /// <summary>Fração de transações internacionais (moeda estrangeira + IOF).</summary>
    public double InternationalRatio { get; set; } = 0.08;

    /// <summary>Fração de compras parceladas (installment > 1).</summary>
    public double InstallmentRatio { get; set; } = 0.20;

    /// <summary>Fração de eventos que NÃO deveriam passar (status != liquidada) — para testar o filtro.</summary>
    public double ShouldBeFilteredRatio { get; set; } = 0.03;

    public static GeneratorOptions Parse(string[] args)
    {
        var o = new GeneratorOptions();
        for (int i = 0; i + 1 < args.Length; i += 2)
        {
            var key = args[i].TrimStart('-').ToLowerInvariant();
            var val = args[i + 1];
            switch (key)
            {
                case "count":         o.Count = int.Parse(val, CultureInfo.InvariantCulture); break;
                case "seed":          o.Seed = int.Parse(val, CultureInfo.InvariantCulture); break;
                case "out":           o.OutDir = val; break;
                case "indented":      o.Indented = bool.Parse(val); break;
                case "hard":          o.HardCaseRatio = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "acquirer":      o.AcquirerPrefixRatio = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "international":  o.InternationalRatio = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "installment":   o.InstallmentRatio = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "filtered":      o.ShouldBeFilteredRatio = double.Parse(val, CultureInfo.InvariantCulture); break;
            }
        }
        return o;
    }
}
