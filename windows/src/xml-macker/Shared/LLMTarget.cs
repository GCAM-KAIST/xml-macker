using System.Text;

namespace XMLMacker.Shared;

/// <summary>
/// The set of chat sites content can be sent to. Order = menu order
/// (ShareSupport.swift <c>LLMTarget</c>).
/// </summary>
public enum LLMTarget
{
    ChatGpt,
    Claude,
    Gemini,
    Grok,
    Perplexity,
    DeepSeek,
    Qwen,
    Glm,
    Kimi,
    Manus
}

/// <summary>
/// Display name / home URL / prefill-URL logic for <see cref="LLMTarget"/>, ported 1:1 from
/// ShareSupport.swift.
///
/// The full payload ALWAYS goes to the clipboard (done by the caller). When the payload is small
/// enough it is ALSO pre-filled via the site's <c>?q=</c> param. The gate is a strict hand-rolled
/// percent-encode of every byte outside <c>[A-Za-z0-9]</c> as <c>%XX</c> (UTF-8 bytes), and the
/// ENCODED length must be ≤ 6000 chars to use prefill.
/// </summary>
public static class LLMTargets
{
    /// <summary>Cases in menu order.</summary>
    public static readonly LLMTarget[] All =
    {
        LLMTarget.ChatGpt, LLMTarget.Claude, LLMTarget.Gemini, LLMTarget.Grok,
        LLMTarget.Perplexity, LLMTarget.DeepSeek, LLMTarget.Qwen, LLMTarget.Glm,
        LLMTarget.Kimi, LLMTarget.Manus
    };

    /// <summary>The encoded-length threshold for using URL prefill.</summary>
    public const int PrefillMaxEncodedLength = 6000;

    /// <summary>The stable raw string (matches the Swift <c>rawValue</c>, used as menu representedObject).</summary>
    public static string RawValue(this LLMTarget t) => t switch
    {
        LLMTarget.ChatGpt => "chatgpt",
        LLMTarget.Claude => "claude",
        LLMTarget.Gemini => "gemini",
        LLMTarget.Grok => "grok",
        LLMTarget.Perplexity => "perplexity",
        LLMTarget.DeepSeek => "deepseek",
        LLMTarget.Qwen => "qwen",
        LLMTarget.Glm => "glm",
        LLMTarget.Kimi => "kimi",
        LLMTarget.Manus => "manus",
        _ => "chatgpt"
    };

    /// <summary>Resolves a raw string back to a target, or null if unknown.</summary>
    public static LLMTarget? FromRawValue(string raw) => raw switch
    {
        "chatgpt" => LLMTarget.ChatGpt,
        "claude" => LLMTarget.Claude,
        "gemini" => LLMTarget.Gemini,
        "grok" => LLMTarget.Grok,
        "perplexity" => LLMTarget.Perplexity,
        "deepseek" => LLMTarget.DeepSeek,
        "qwen" => LLMTarget.Qwen,
        "glm" => LLMTarget.Glm,
        "kimi" => LLMTarget.Kimi,
        "manus" => LLMTarget.Manus,
        _ => null
    };

    /// <summary>Human-readable name shown in the Share menu.</summary>
    public static string DisplayName(this LLMTarget t) => t switch
    {
        LLMTarget.ChatGpt => "ChatGPT",
        LLMTarget.Claude => "Claude",
        LLMTarget.Gemini => "Gemini",
        LLMTarget.Grok => "Grok",
        LLMTarget.Perplexity => "Perplexity",
        LLMTarget.DeepSeek => "DeepSeek",
        LLMTarget.Qwen => "Qwen",
        LLMTarget.Glm => "GLM (Z.ai)",
        LLMTarget.Kimi => "Kimi",
        LLMTarget.Manus => "Manus",
        _ => "ChatGPT"
    };

    /// <summary>The site's base URL (opened when no prefill is used).</summary>
    public static string Home(this LLMTarget t) => t switch
    {
        LLMTarget.ChatGpt => "https://chatgpt.com/",
        LLMTarget.Claude => "https://claude.ai/new",
        LLMTarget.Gemini => "https://gemini.google.com/app",
        LLMTarget.Grok => "https://grok.com/",
        LLMTarget.Perplexity => "https://www.perplexity.ai/",
        LLMTarget.DeepSeek => "https://chat.deepseek.com/",
        LLMTarget.Qwen => "https://chat.qwen.ai/",
        LLMTarget.Glm => "https://chat.z.ai/",
        LLMTarget.Kimi => "https://www.kimi.com/",
        LLMTarget.Manus => "https://manus.im/",
        _ => "https://chatgpt.com/"
    };

    /// <summary>
    /// Builds the URL to open. If <paramref name="prefill"/> is null, too large once encoded, or the
    /// target has no known prefill param, returns the plain <see cref="Home"/> URL (the clipboard
    /// carries the payload). Otherwise appends <c>?q=&lt;encoded&gt;</c> for the sites that support it.
    /// </summary>
    public static Uri Url(this LLMTarget t, string? prefill)
    {
        if (prefill is null)
            return new Uri(t.Home());

        string encoded = PercentEncode(prefill);
        if (encoded.Length > PrefillMaxEncodedLength)
            return new Uri(t.Home());

        return t switch
        {
            LLMTarget.ChatGpt => new Uri("https://chatgpt.com/?q=" + encoded),
            LLMTarget.Claude => new Uri("https://claude.ai/new?q=" + encoded),
            LLMTarget.Grok => new Uri("https://grok.com/?q=" + encoded),
            LLMTarget.Perplexity => new Uri("https://www.perplexity.ai/search?q=" + encoded),
            // gemini, deepseek, qwen, glm, kimi, manus → no known prefill param.
            _ => new Uri(t.Home())
        };
    }

    /// <summary>
    /// Strict percent-encoder: every byte NOT in <c>[A-Za-z0-9]</c> becomes <c>%XX</c> (uppercase
    /// hex) over the UTF-8 byte representation. Stricter than <c>Uri.EscapeDataString</c> so the
    /// ≤6000 encoded-length gate matches the Swift original exactly.
    /// </summary>
    public static string PercentEncode(string s)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        var sb = new StringBuilder(bytes.Length * 3);
        foreach (byte b in bytes)
        {
            bool unreserved = (b >= (byte)'A' && b <= (byte)'Z')
                           || (b >= (byte)'a' && b <= (byte)'z')
                           || (b >= (byte)'0' && b <= (byte)'9');
            if (unreserved)
            {
                sb.Append((char)b);
            }
            else
            {
                sb.Append('%');
                sb.Append(HexUpper[(b >> 4) & 0xF]);
                sb.Append(HexUpper[b & 0xF]);
            }
        }
        return sb.ToString();
    }

    private const string HexUpper = "0123456789ABCDEF";
}
