using System.Text;
using System.Text.Json;

namespace Pfm.Categorization.Contracts;

/// <summary>
/// Converte nomes PascalCase de propriedades para snake_case no JSON.
/// Ex.: MccGroupId -> mcc_group_id, IofAmount -> iof_amount, TransactionUuid -> transaction_uuid.
///
/// Implementação própria (em vez de JsonNamingPolicy.SnakeCaseLower do .NET 8) para o contrato
/// não depender da versão do runtime e o comportamento ficar explícito e testável.
/// </summary>
public sealed class SnakeCaseLowerNamingPolicy : JsonNamingPolicy
{
    public static readonly SnakeCaseLowerNamingPolicy Instance = new();

    public override string ConvertName(string name)
    {
        if (string.IsNullOrEmpty(name))
            return name;

        var sb = new StringBuilder(name.Length + 8);
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (char.IsUpper(c))
            {
                // insere "_" quando há transição de minúscula/dígito para maiúscula
                if (i > 0 && (char.IsLower(name[i - 1]) || char.IsDigit(name[i - 1])))
                    sb.Append('_');
                sb.Append(char.ToLowerInvariant(c));
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}
