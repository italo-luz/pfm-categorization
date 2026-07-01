using Pfm.Categorization.Contracts;
using Pfm.Categorization.SyntheticData;

// -----------------------------------------------------------------------------
// Gerador de massa sintética (PBI-03)
//
// Uso:
//   dotnet run --project src/Pfm.Categorization.SyntheticData -- --count 10000 --seed 42 --out ./out
//
// Gera DOIS arquivos JSON Lines (1 evento por linha) em --out:
//   synthetic_labeled_events.jsonl    -> com rótulo verdadeiro (seu arnês de medição)
//   synthetic_canonical_events.jsonl  -> só o evento canônico (o que o pipeline recebe)
// -----------------------------------------------------------------------------

var opt = GeneratorOptions.Parse(args);
Directory.CreateDirectory(opt.OutDir);

string labeledPath   = Path.Combine(opt.OutDir, "synthetic_labeled_events.jsonl");
string canonicalPath = Path.Combine(opt.OutDir, "synthetic_canonical_events.jsonl");

var generator = new EventGenerator(opt);

// Contadores para o resumo de sanidade (verificar a distribuição que você gerou).
var perCategory = new Dictionary<string, int>();
var perScenario = new Dictionary<string, int>();
int total = 0, hard = 0, intl = 0, filtered = 0, acquirer = 0, installments = 0;

using (var labeled = new StreamWriter(labeledPath, append: false))
using (var canonical = new StreamWriter(canonicalPath, append: false))
{
    foreach (var le in generator.Generate())
    {
        // JSON Lines: nunca indentado aqui (1 objeto por linha).
        labeled.WriteLine(CanonicalJson.Serialize(le, indented: false));
        canonical.WriteLine(CanonicalJson.Serialize(le.Event, indented: false));

        total++;
        Bump(perCategory, le.ExpectedCategory);
        Bump(perScenario, le.Scenario);
        if (le.IsHard) hard++;
        if (le.Scenario == "international") intl++;
        if (le.Scenario == "filtered") filtered++;
        if (le.Scenario == "acquirer_prefixed") acquirer++;
        if (le.Event.Installment > 1) installments++;
    }
}

// -----------------------------------------------------------------------------
// Resumo de sanidade no console (sempre confira a distribuição da sua massa)
// -----------------------------------------------------------------------------
Console.WriteLine();
Console.WriteLine("=== Massa sintética gerada ===");
Console.WriteLine($"Seed: {opt.Seed}  (mesma seed => mesma massa)");
Console.WriteLine($"Total: {total}");
Console.WriteLine($"Arquivos:");
Console.WriteLine($"  {labeledPath}");
Console.WriteLine($"  {canonicalPath}");
Console.WriteLine();
Console.WriteLine($"Difíceis (is_hard):       {hard,6}  ({Pct(hard, total)})");
Console.WriteLine($"Internacionais:           {intl,6}  ({Pct(intl, total)})");
Console.WriteLine($"Devem ser filtrados:      {filtered,6}  ({Pct(filtered, total)})");
Console.WriteLine($"Com prefixo de adquirente:{acquirer,6}  ({Pct(acquirer, total)})");
Console.WriteLine($"Parcelados:               {installments,6}  ({Pct(installments, total)})");

Console.WriteLine();
Console.WriteLine("--- Por categoria esperada ---");
foreach (var kv in perCategory.OrderByDescending(k => k.Value))
    Console.WriteLine($"  {kv.Key,-15} {kv.Value,6}  ({Pct(kv.Value, total)})");

Console.WriteLine();
Console.WriteLine("--- Por cenário ---");
foreach (var kv in perScenario.OrderByDescending(k => k.Value))
    Console.WriteLine($"  {kv.Key,-18} {kv.Value,6}  ({Pct(kv.Value, total)})");

Console.WriteLine();
Console.WriteLine("Dica: synthetic_canonical_events.jsonl é o que você joga no esqueleto do pipeline.");
Console.WriteLine("      synthetic_labeled_events.jsonl é só para MEDIR (o pipeline nunca vê o rótulo).");

return;

static void Bump(Dictionary<string, int> d, string k) => d[k] = d.TryGetValue(k, out var v) ? v + 1 : 1;
static string Pct(int n, int total) => total == 0 ? "0%" : $"{100.0 * n / total:0.0}%";
