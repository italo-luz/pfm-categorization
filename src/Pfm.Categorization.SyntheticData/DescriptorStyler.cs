namespace Pfm.Categorization.SyntheticData;

/// <summary>
/// Gera o descriptor BRUTO em diferentes estilos. É exatamente essa variação que torna o
/// Merchant Resolution Service (etapa futura) difícil — então é importante gerá-la agora,
/// para que você tenha contra o que testar a resolução.
/// </summary>
public enum DescriptorStyle
{
    /// <summary>Limpo: só o nome. Ex.: "MONTAGNER CIA".</summary>
    Clean,
    /// <summary>Padded com cidade e país, largura fixa. Ex.: "MONTAGNER CIA LTDA       CAMPINAS     BR".</summary>
    Padded,
    /// <summary>Prefixado por adquirente/gateway. Ex.: "PAGSEGURO *MONTAGNER CIA".</summary>
    AcquirerPrefixed,
}

public static class DescriptorStyler
{
    /// <summary>Monta o descriptor bruto a partir do nome-base, cidade, país e estilo.</summary>
    public static string Build(string name, string city, string countryIso, DescriptorStyle style, string? acquirerPrefix)
    {
        switch (style)
        {
            case DescriptorStyle.Clean:
                return name;

            case DescriptorStyle.AcquirerPrefixed:
                // Adquirente esconde o lojista real: o desafio central da resolução no Brasil.
                return $"{acquirerPrefix}{name}";

            case DescriptorStyle.Padded:
            default:
                // Imita o formato do evento de exemplo: nome (com sufixo) + cidade + país, com padding.
                string legalName = $"{name} LTDA";
                return $"{Pad(legalName, 25)}{Pad(city, 13)}{countryIso}";
        }
    }

    private static string Pad(string s, int width)
        => s.Length >= width ? s[..width] : s.PadRight(width);
}
