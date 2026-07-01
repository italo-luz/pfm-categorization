using Pfm.Categorization.Contracts;

namespace Pfm.Categorization.SyntheticData;

/// <summary>
/// Motor de geração. Determinístico dado o <see cref="GeneratorOptions.Seed"/>.
///
/// Para cada evento: sorteia um CENÁRIO (mutuamente exclusivo), escolhe merchant+MCC coerentes,
/// aplica modificadores ORTOGONAIS (prefixo de adquirente, parcelamento) e preenche o evento
/// canônico. Os campos de "merchant resolvido" ficam NULOS de propósito — quem preenche é o
/// Merchant Resolution Service (etapa futura).
/// </summary>
public sealed class EventGenerator
{
    private readonly GeneratorOptions _opt;
    private readonly Random _rng;
    private readonly DateTimeOffset _windowEnd = new(2024, 12, 31, 0, 0, 0, TimeSpan.Zero);
    private const int WindowDays = 180;

    public EventGenerator(GeneratorOptions opt)
    {
        _opt = opt;
        _rng = new Random(opt.Seed); // seed fixa => massa reprodutível
    }

    public IEnumerable<SyntheticLabeledEvent> Generate()
    {
        for (int i = 0; i < _opt.Count; i++)
            yield return GenerateOne();
    }

    private SyntheticLabeledEvent GenerateOne()
    {
        double roll = _rng.NextDouble();

        // Cenários mutuamente exclusivos, por faixas acumuladas.
        double tFiltered = _opt.ShouldBeFilteredRatio;
        double tIntl     = tFiltered + _opt.InternationalRatio;
        double tHard     = tIntl + _opt.HardCaseRatio;

        if (roll < tFiltered) return BuildFiltered();
        if (roll < tIntl)     return BuildInternational();
        if (roll < tHard)     return BuildHard();
        return BuildNormal();
    }

    // ---------------- Cenário: normal/clean ----------------
    private SyntheticLabeledEvent BuildNormal()
    {
        string category = Pick(MerchantCatalog.NormalCategories);
        var tpl = Pick(MerchantCatalog.ByCategory[category]);

        var (style, prefix) = PickDomesticStyle();
        string descriptor = DescriptorStyler.Build(tpl.Name, Pick(MerchantCatalog.Cities), "BR", style, prefix);

        var ev = NewDomesticEvent(tpl, descriptor, category);
        return Wrap(ev, category, ScenarioFor(style), isHard: false);
    }

    // ---------------- Cenário: difícil (marketplace / posto+conveniência / catch-all) ----------------
    private SyntheticLabeledEvent BuildHard()
    {
        int sub = _rng.Next(3);
        MerchantTemplate tpl;
        string expected;
        string scenario;

        switch (sub)
        {
            case 0:
                tpl = Pick(MerchantCatalog.Marketplaces);
                expected = PfmCategories.Outros; // marketplace genérico, sem item-level
                scenario = "marketplace";
                break;
            case 1:
                tpl = Pick(MerchantCatalog.FuelConvenience);
                expected = PfmCategories.Combustivel; // melhor chute, mas pode ser conveniência
                scenario = "fuel_convenience";
                break;
            default:
                tpl = Pick(MerchantCatalog.CatchAll);
                expected = PfmCategories.Outros; // MCC 5999
                scenario = "catch_all";
                break;
        }

        var (style, prefix) = PickDomesticStyle();
        string descriptor = DescriptorStyler.Build(tpl.Name, Pick(MerchantCatalog.Cities), "BR", style, prefix);

        var ev = NewDomesticEvent(tpl, descriptor, expected);
        return Wrap(ev, expected, scenario, isHard: true);
    }

    // ---------------- Cenário: internacional ----------------
    private SyntheticLabeledEvent BuildInternational()
    {
        var m = Pick(MerchantCatalog.International);
        // Internacionais costumam vir "limpos" (e-commerce), sem prefixo de adquirente local.
        string descriptor = DescriptorStyler.Build(m.Name, "", m.CountryIso, DescriptorStyle.Clean, null);

        decimal amount = RandomAmount(m.ExpectedCategory);
        int currency = PickForeignCurrency();
        decimal fx = (decimal)(4.8 + _rng.NextDouble() * 1.4); // ~4.8..6.2
        decimal iof = Math.Round(amount * 0.0438m, 2);          // IOF de cartão internacional (~4,38%)

        var purchase = RandomPurchaseDate();
        var ev = new CanonicalCardTransactionEvent
        {
            TransactionUuid = Guid.NewGuid().ToString(),
            PurchaseId = RandomId(),
            AccountId = RandomAccountId(),
            MerchantRaw = descriptor,
            MerchantId = RandomId(),
            MerchantCode = RandomMerchantCode(),
            Mcc = m.Mcc.Mcc,
            MccDescription = m.Mcc.Description,
            MccGroupId = m.Mcc.GroupId,
            MccGroupDescription = m.Mcc.GroupDescription,
            TransactionTypeId = "318",
            TransactionTypeDescription = "Compra internacional",
            Status = "Processada",
            StatusId = SchemaConstants.StatusIdSettled,
            EntryMode = "0810",
            Origin = "VSN",
            ResolutionOrigin = "BII",
            IsTokenizedTransaction = _rng.NextDouble() < 0.3,
            Amount = amount,
            Installment = 1,
            AmountFirstInstallment = amount,
            AmountNextInstallment = amount,
            IofAmount = iof,
            CurrencyCode = currency,
            ExchangeRate = Math.Round(fx, 3),
            PurchaseDate = purchase,
            ProcessingDate = purchase.AddDays(1),
            AuthorizationDate = purchase.AddMinutes(-_rng.Next(1, 120)),
        };

        return Wrap(ev, m.ExpectedCategory, "international", isHard: false);
    }

    // ---------------- Cenário: deve ser filtrado (status != liquidada) ----------------
    private SyntheticLabeledEvent BuildFiltered()
    {
        string category = Pick(MerchantCatalog.NormalCategories);
        var tpl = Pick(MerchantCatalog.ByCategory[category]);
        string descriptor = DescriptorStyler.Build(tpl.Name, Pick(MerchantCatalog.Cities), "BR", DescriptorStyle.Padded, null);

        var ev = NewDomesticEvent(tpl, descriptor, category);
        // Sobrescreve status para um valor que o filtro deve barrar.
        bool negada = _rng.NextDouble() < 0.5;
        ev.Status = negada ? "Negada" : "Cancelada";
        ev.StatusId = negada ? 0 : 3;

        // Rótulo N/A: o pipeline NÃO deveria categorizar isto (deve filtrar).
        return Wrap(ev, PfmCategories.NotApplicable, "filtered", isHard: false);
    }

    // ---------------- Construção base de evento doméstico ----------------
    private CanonicalCardTransactionEvent NewDomesticEvent(MerchantTemplate tpl, string descriptor, string categoryForAmount)
    {
        decimal amount = RandomAmount(categoryForAmount);
        int installment = MaybeInstallment();
        var purchase = RandomPurchaseDate();

        return new CanonicalCardTransactionEvent
        {
            TransactionUuid = Guid.NewGuid().ToString(),
            PurchaseId = RandomId(),
            AccountId = RandomAccountId(),
            MerchantRaw = descriptor,
            MerchantId = RandomId(),
            MerchantCode = RandomMerchantCode(),
            Mcc = tpl.Mcc.Mcc,
            MccDescription = tpl.Mcc.Description,
            MccGroupId = tpl.Mcc.GroupId,
            MccGroupDescription = tpl.Mcc.GroupDescription,
            TransactionTypeId = installment > 1 ? "320" : "318",
            TransactionTypeDescription = installment > 1 ? "Parcelado sem juros - Visa" : "A vista sem juros - Visa",
            Status = "Processada",
            StatusId = SchemaConstants.StatusIdSettled,
            EntryMode = _rng.NextDouble() < 0.5 ? "0510" : "0710",
            Origin = "VSN",
            ResolutionOrigin = "BII",
            IsTokenizedTransaction = _rng.NextDouble() < 0.25,
            Amount = amount,
            Installment = installment,
            AmountFirstInstallment = Math.Round(amount / installment, 2),
            AmountNextInstallment = Math.Round(amount / installment, 2),
            IofAmount = 0m,
            CurrencyCode = SchemaConstants.CurrencyCodeBrl,
            ExchangeRate = 1m,
            PurchaseDate = purchase,
            ProcessingDate = purchase.AddDays(1),
            AuthorizationDate = purchase.AddMinutes(-_rng.Next(1, 120)),
        };
    }

    // ---------------- Sorteios e helpers ----------------

    private (DescriptorStyle style, string? prefix) PickDomesticStyle()
    {
        if (_rng.NextDouble() < _opt.AcquirerPrefixRatio)
            return (DescriptorStyle.AcquirerPrefixed, Pick(MerchantCatalog.AcquirerPrefixes));
        // entre limpo e padded
        return (_rng.NextDouble() < 0.5 ? DescriptorStyle.Clean : DescriptorStyle.Padded, null);
    }

    private static string ScenarioFor(DescriptorStyle style) => style switch
    {
        DescriptorStyle.AcquirerPrefixed => "acquirer_prefixed",
        DescriptorStyle.Padded => "clean",   // padded ainda é "fácil"; agrupamos como clean
        _ => "clean",
    };

    private int MaybeInstallment()
        => _rng.NextDouble() < _opt.InstallmentRatio ? _rng.Next(2, 13) : 1;

    /// <summary>
    /// Valor com leve influência de categoria, mas com MUITA sobreposição de propósito:
    /// reforça que amount é sinal FRACO de categoria.
    /// </summary>
    private decimal RandomAmount(string category)
    {
        double baseAmount = 5 + _rng.NextDouble() * 495; // 5..500
        double mult = category switch
        {
            PfmCategories.Viagem => 2.5 + _rng.NextDouble() * 3,        // viagem costuma ser maior
            PfmCategories.Eletronicos => 1.5 + _rng.NextDouble() * 3,
            PfmCategories.Casa => 1.2 + _rng.NextDouble() * 2,
            PfmCategories.Transporte => 0.2 + _rng.NextDouble() * 0.8,  // corrida costuma ser menor
            PfmCategories.Restaurantes => 0.3 + _rng.NextDouble() * 1.2,
            _ => 0.5 + _rng.NextDouble() * 1.5,
        };
        return Math.Round((decimal)(baseAmount * mult), 2);
    }

    private DateTimeOffset RandomPurchaseDate()
    {
        int daysAgo = _rng.Next(0, WindowDays);
        int seconds = _rng.Next(0, 86_400);
        return _windowEnd.AddDays(-daysAgo).AddSeconds(seconds);
    }

    private int PickForeignCurrency()
    {
        int[] foreign = { 840 /*USD*/, 978 /*EUR*/, 826 /*GBP*/ };
        return foreign[_rng.Next(foreign.Length)];
    }

    private long RandomId() => 100_000_000L + (long)(_rng.NextDouble() * 900_000_000L);
    private long RandomAccountId() => 1_000_000L + (long)(_rng.NextDouble() * 9_000_000L);
    private string RandomMerchantCode() => _rng.Next(0, 1_000_000_000).ToString("D15");

    private T Pick<T>(IReadOnlyList<T> items) => items[_rng.Next(items.Count)];

    private static SyntheticLabeledEvent Wrap(CanonicalCardTransactionEvent ev, string expected, string scenario, bool isHard)
        => new() { Event = ev, ExpectedCategory = expected, Scenario = scenario, IsHard = isHard };
}
