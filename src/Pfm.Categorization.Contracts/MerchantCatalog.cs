using Pfm.Categorization.Contracts;

namespace Pfm.Categorization.SyntheticData;

/// <summary>Informação de MCC usada para gerar eventos coerentes (MCC ⇄ descrição ⇄ grupo).</summary>
public sealed record MccInfo(int Mcc, string Description, int GroupId, string GroupDescription);

/// <summary>Template de merchant: nome-base + um MCC típico daquele estabelecimento.</summary>
public sealed record MerchantTemplate(string Name, MccInfo Mcc);

/// <summary>Merchant internacional com a categoria esperada explícita (ensina: internacional ≠ Viagem).</summary>
public sealed record IntlMerchant(string Name, MccInfo Mcc, string ExpectedCategory, string CountryIso);

/// <summary>
/// Catálogo de dados sintéticos. MCCs são reais (ISO 18245); os grupos (mcc_group_id) são uma
/// convenção interna do gerador (na vida real o grupo é específico do emissor).
///
/// Os nomes de merchant são exemplos realistas do varejo brasileiro, em MAIÚSCULAS como
/// costumam vir nos descriptors.
/// </summary>
public static class MerchantCatalog
{
    // ---------------- MCCs por categoria ----------------
    private static readonly MccInfo Mcc_Restaurante   = new(5812, "EATING PLACES AND RESTAURANTS", 14, "Eating/Drinking");
    private static readonly MccInfo Mcc_FastFood       = new(5814, "FAST FOOD RESTAURANTS",         14, "Eating/Drinking");
    private static readonly MccInfo Mcc_Supermercado   = new(5411, "GROCERY STORES SUPERMARKETS",    8, "Retail Stores");
    private static readonly MccInfo Mcc_Posto          = new(5541, "SERVICE STATIONS",              16, "Automobiles/Vehicles");
    private static readonly MccInfo Mcc_PostoAuto      = new(5542, "AUTOMATED FUEL DISPENSERS",     16, "Automobiles/Vehicles");
    private static readonly MccInfo Mcc_Taxi           = new(4121, "TAXICABS AND RIDESHARES",        4, "Transportation");
    private static readonly MccInfo Mcc_Transito       = new(4111, "LOCAL/SUBURBAN COMMUTER TRANSPORT", 4, "Transportation");
    private static readonly MccInfo Mcc_Farmacia       = new(5912, "DRUG STORES AND PHARMACIES",    12, "Health");
    private static readonly MccInfo Mcc_Hospital       = new(8062, "HOSPITALS",                     12, "Health");
    private static readonly MccInfo Mcc_Faculdade      = new(8220, "COLLEGES AND UNIVERSITIES",     11, "Education");
    private static readonly MccInfo Mcc_Escola         = new(8211, "ELEMENTARY/SECONDARY SCHOOLS",  11, "Education");
    private static readonly MccInfo Mcc_Corretora      = new(6211, "SECURITY BROKERS DEALERS",      10, "Financial");
    private static readonly MccInfo Mcc_Telecom        = new(4814, "TELECOMMUNICATION SERVICES",     9, "Services");
    private static readonly MccInfo Mcc_Utilities      = new(4900, "UTILITIES ELECTRIC GAS WATER",   9, "Services");
    private static readonly MccInfo Mcc_Casa           = new(5200, "HOME SUPPLY WAREHOUSE STORES",   8, "Retail Stores");
    private static readonly MccInfo Mcc_Moveis         = new(5712, "FURNITURE AND HOME FURNISHINGS", 8, "Retail Stores");
    private static readonly MccInfo Mcc_Cinema         = new(7832, "MOTION PICTURE THEATERS",       13, "Entertainment");
    private static readonly MccInfo Mcc_DigitalMedia   = new(5815, "DIGITAL GOODS MEDIA",           13, "Entertainment");
    private static readonly MccInfo Mcc_Eletronicos    = new(5732, "ELECTRONICS STORES",             8, "Retail Stores");
    private static readonly MccInfo Mcc_Software        = new(5734, "COMPUTER SOFTWARE STORES",      8, "Retail Stores");
    private static readonly MccInfo Mcc_Vestuario      = new(5651, "FAMILY CLOTHING STORES",         8, "Retail Stores");
    private static readonly MccInfo Mcc_Calcados       = new(5661, "SHOE STORES",                    8, "Retail Stores");
    private static readonly MccInfo Mcc_Aerea          = new(4511, "AIRLINES AIR CARRIERS",          3, "Travel");
    private static readonly MccInfo Mcc_Hotel          = new(7011, "LODGING HOTELS RESORTS",         3, "Travel");
    private static readonly MccInfo Mcc_Locadora       = new(7512, "AUTOMOBILE RENTAL AGENCY",       3, "Travel");
    private static readonly MccInfo Mcc_Agencia        = new(4722, "TRAVEL AGENCIES",                3, "Travel");

    // Catch-all / ambíguos
    private static readonly MccInfo Mcc_MiscRetail     = new(5999, "MISCELLANEOUS RETAIL",          99, "Misc");
    private static readonly MccInfo Mcc_DeptStore      = new(5311, "DEPARTMENT STORES",              8, "Retail Stores");

    /// <summary>Merchants "normais" por categoria (caso fácil, descriptor coerente com o MCC).</summary>
    public static readonly IReadOnlyDictionary<string, MerchantTemplate[]> ByCategory =
        new Dictionary<string, MerchantTemplate[]>
        {
            [PfmCategories.Restaurantes] = new[]
            {
                new MerchantTemplate("MONTAGNER CIA", Mcc_Restaurante),
                new MerchantTemplate("OUTBACK STEAKHOUSE", Mcc_Restaurante),
                new MerchantTemplate("MADERO", Mcc_Restaurante),
                new MerchantTemplate("HABIBS", Mcc_FastFood),
                new MerchantTemplate("GIRAFFAS", Mcc_FastFood),
                new MerchantTemplate("COCO BAMBU", Mcc_Restaurante),
            },
            [PfmCategories.Supermercado] = new[]
            {
                new MerchantTemplate("CARREFOUR", Mcc_Supermercado),
                new MerchantTemplate("PAO DE ACUCAR", Mcc_Supermercado),
                new MerchantTemplate("ASSAI ATACADISTA", Mcc_Supermercado),
                new MerchantTemplate("EXTRA SUPERMERCADO", Mcc_Supermercado),
                new MerchantTemplate("DIA SUPERMERCADO", Mcc_Supermercado),
            },
            [PfmCategories.Combustivel] = new[]
            {
                new MerchantTemplate("POSTO IPIRANGA", Mcc_Posto),
                new MerchantTemplate("POSTO SHELL", Mcc_Posto),
                new MerchantTemplate("POSTO BR", Mcc_PostoAuto),
                new MerchantTemplate("AUTO POSTO ALE", Mcc_Posto),
            },
            [PfmCategories.Transporte] = new[]
            {
                new MerchantTemplate("UBER", Mcc_Taxi),
                new MerchantTemplate("99 APP", Mcc_Taxi),
                new MerchantTemplate("METRO SP", Mcc_Transito),
                new MerchantTemplate("ESTAPAR ESTACIONAMENTO", Mcc_Transito),
            },
            [PfmCategories.Saude] = new[]
            {
                new MerchantTemplate("DROGARIA SAO PAULO", Mcc_Farmacia),
                new MerchantTemplate("DROGASIL", Mcc_Farmacia),
                new MerchantTemplate("DROGA RAIA", Mcc_Farmacia),
                new MerchantTemplate("HOSPITAL ALBERT EINSTEIN", Mcc_Hospital),
            },
            [PfmCategories.Educacao] = new[]
            {
                new MerchantTemplate("UNINOVE", Mcc_Faculdade),
                new MerchantTemplate("ANHANGUERA", Mcc_Faculdade),
                new MerchantTemplate("COLEGIO OBJETIVO", Mcc_Escola),
            },
            [PfmCategories.Investimentos] = new[]
            {
                new MerchantTemplate("XP INVESTIMENTOS", Mcc_Corretora),
                new MerchantTemplate("RICO INVESTIMENTOS", Mcc_Corretora),
                new MerchantTemplate("CLEAR CORRETORA", Mcc_Corretora),
            },
            [PfmCategories.Servicos] = new[]
            {
                new MerchantTemplate("VIVO", Mcc_Telecom),
                new MerchantTemplate("CLARO", Mcc_Telecom),
                new MerchantTemplate("ENEL SP", Mcc_Utilities),
                new MerchantTemplate("SABESP", Mcc_Utilities),
            },
            [PfmCategories.Casa] = new[]
            {
                new MerchantTemplate("LEROY MERLIN", Mcc_Casa),
                new MerchantTemplate("TOK STOK", Mcc_Moveis),
                new MerchantTemplate("TELHANORTE", Mcc_Casa),
            },
            [PfmCategories.Lazer] = new[]
            {
                new MerchantTemplate("CINEMARK", Mcc_Cinema),
                new MerchantTemplate("CINEPOLIS", Mcc_Cinema),
                new MerchantTemplate("KINOPLEX", Mcc_Cinema),
            },
            [PfmCategories.Eletronicos] = new[]
            {
                new MerchantTemplate("FAST SHOP", Mcc_Eletronicos),
                new MerchantTemplate("KABUM", Mcc_Eletronicos),
                new MerchantTemplate("KALUNGA", Mcc_Software),
            },
            [PfmCategories.Vestuario] = new[]
            {
                new MerchantTemplate("RENNER", Mcc_Vestuario),
                new MerchantTemplate("C E A MODAS", Mcc_Vestuario),
                new MerchantTemplate("RIACHUELO", Mcc_Vestuario),
                new MerchantTemplate("NETSHOES", Mcc_Calcados),
            },
            [PfmCategories.Viagem] = new[]
            {
                new MerchantTemplate("LATAM AIRLINES", Mcc_Aerea),
                new MerchantTemplate("GOL LINHAS AEREAS", Mcc_Aerea),
                new MerchantTemplate("HOTEL IBIS", Mcc_Hotel),
                new MerchantTemplate("LOCALIZA RENT A CAR", Mcc_Locadora),
                new MerchantTemplate("CVC VIAGENS", Mcc_Agencia),
            },
        };

    /// <summary>Cenário difícil: marketplaces. Categoria esperada = Outros (sem item-level não dá pra saber).</summary>
    public static readonly MerchantTemplate[] Marketplaces =
    {
        new MerchantTemplate("MERCADO LIVRE", Mcc_MiscRetail),
        new MerchantTemplate("AMAZON BR", Mcc_MiscRetail),
        new MerchantTemplate("MAGAZINE LUIZA", Mcc_DeptStore),
        new MerchantTemplate("SHOPEE", Mcc_MiscRetail),
        new MerchantTemplate("AMERICANAS", Mcc_DeptStore),
    };

    /// <summary>Cenário difícil: posto com loja de conveniência. Esperado = Combustível, mas ambíguo.</summary>
    public static readonly MerchantTemplate[] FuelConvenience =
    {
        new MerchantTemplate("POSTO SHELL SELECT", Mcc_Posto),
        new MerchantTemplate("POSTO IPIRANGA AMPM", Mcc_Posto),
        new MerchantTemplate("POSTO BR CONVENIENCIA", Mcc_PostoAuto),
    };

    /// <summary>Cenário difícil: catch-all genérico (MCC 5999). Esperado = Outros.</summary>
    public static readonly MerchantTemplate[] CatchAll =
    {
        new MerchantTemplate("COMERCIO VAREJISTA LTDA", Mcc_MiscRetail),
        new MerchantTemplate("LOJA CENTRAL", Mcc_MiscRetail),
        new MerchantTemplate("BAZAR E PRESENTES", Mcc_MiscRetail),
    };

    /// <summary>
    /// Cenário internacional: cada um com a categoria CORRETA. Repare que só BOOKING é Viagem;
    /// o resto é Lazer/Serviços/Educação/Outros — internacional ≠ Viagem.
    /// </summary>
    public static readonly IntlMerchant[] International =
    {
        new IntlMerchant("STEAM GAMES", Mcc_DigitalMedia, PfmCategories.Lazer,       "US"),
        new IntlMerchant("SPOTIFY",     Mcc_DigitalMedia, PfmCategories.Lazer,       "US"),
        new IntlMerchant("OPENAI",      Mcc_Software,     PfmCategories.Servicos,    "US"),
        new IntlMerchant("UDEMY",       Mcc_Faculdade,    PfmCategories.Educacao,    "US"),
        new IntlMerchant("BOOKING.COM", Mcc_Agencia,      PfmCategories.Viagem,      "NL"),
        new IntlMerchant("ALIEXPRESS",  Mcc_MiscRetail,   PfmCategories.Outros,      "CN"),
    };

    // ---------------- Auxiliares ----------------
    public static readonly string[] AcquirerPrefixes =
    {
        "PAGSEGURO *", "MP *", "STONE*", "CIELO*", "PAYPAL *", "IUGU*", "EC *",
    };

    public static readonly string[] Cities =
    {
        "SAO PAULO", "CAMPINAS", "RIO DE JANEIRO", "CURITIBA",
        "PORTO ALEGRE", "BELO HORIZONTE", "SALVADOR", "RECIFE",
    };

    /// <summary>Categorias "normais" elegíveis para sorteio (Outros vem só do catch-all).</summary>
    public static readonly string[] NormalCategories =
    {
        PfmCategories.Restaurantes, PfmCategories.Supermercado, PfmCategories.Combustivel,
        PfmCategories.Transporte, PfmCategories.Saude, PfmCategories.Educacao,
        PfmCategories.Investimentos, PfmCategories.Servicos, PfmCategories.Casa,
        PfmCategories.Lazer, PfmCategories.Eletronicos, PfmCategories.Vestuario,
        PfmCategories.Viagem,
    };
}
