using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Pfm.Categorization.Contracts;

/// <summary>
/// Serialização canônica do contrato. O contrato é dono do seu próprio formato JSON:
/// o gerador e o futuro Categorization Service usam ESTAS opções para nunca divergir
/// (é justamente o ponto de existir um contrato).
/// </summary>
public static class CanonicalJson
{
    public static readonly JsonSerializerOptions Options = Build(indented: false);
    public static readonly JsonSerializerOptions OptionsIndented = Build(indented: true);

    private static JsonSerializerOptions Build(bool indented) => new()
    {
        PropertyNamingPolicy = SnakeCaseLowerNamingPolicy.Instance,
        DictionaryKeyPolicy = SnakeCaseLowerNamingPolicy.Instance,
        // Campos nulos (ex.: merchant resolvido, ainda não preenchido) não vão para o JSON.
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = indented,
        // Mantém acentos legíveis ("Educação" em vez de \u00e7\u00e3o) — ok para arquivos internos.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter() }
    };

    public static string Serialize<T>(T value, bool indented = false)
        => JsonSerializer.Serialize(value, indented ? OptionsIndented : Options);

    public static T? Deserialize<T>(string json)
        => JsonSerializer.Deserialize<T>(json, Options);
}
