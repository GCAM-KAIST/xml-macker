using System.Diagnostics;
using System.Windows;

namespace XMLMacker.Shared;

/// <summary>
/// The LLM send flow + plain-text share, ported from ShareSupport.swift.
/// LLM contract: the FULL payload always goes to the clipboard; the URL only ALSO pre-fills the
/// prompt when it is small enough (see <see cref="LLMTargets.Url"/> and its ≤6000 encoded gate).
/// When prefill is skipped, the plain home URL opens and the clipboard carries the payload.
/// Clipboard access (<see cref="Clipboard"/>) requires the STA UI thread, call these on the UI thread.
/// </summary>
public static class ShareService
{
    // ---- Prompt preambles (verbatim from the macOS version) ------

    /// <summary>Selection share preamble: "Here is an XML excerpt from &lt;fileName&gt;:…".</summary>
    public static string SelectionPrompt(string fileName, string xmlText)
        => $"Here is an XML excerpt from {fileName}:\n\n```xml\n{xmlText}\n```\n\n";

    /// <summary>Element share preamble: "Here is the &lt;label&gt; element (path: …) from &lt;fileName&gt;:…".</summary>
    public static string ElementPrompt(string label, string treePath, string fileName, string xmlText)
        => $"Here is the {label} element (path: {treePath}) from {fileName}:\n\n```xml\n{xmlText}\n```\n\n";

    /// <summary>Learn-mode "define everything" preamble.</summary>
    public static string LearnPrompt(string what, string fileName, string xml)
        => $"Define everything in this XML {what} from the GCAM model file {fileName}, explain what "
         + $"every tag means, what every attribute does, and what each value represents, in simple "
         + $"terms:\n\n```xml\n{xml}\n```\n";

    // ---- Delivery --------------------------------------------------------

    /// <summary>
    /// Delivers <paramref name="prompt"/> to <paramref name="target"/>: copies the full prompt to the
    /// clipboard, then opens the target URL (prefilled if under the gate, else the plain home URL) in
    /// the default browser. Returns the status message to show on screen.
    /// </summary>
    public static string DeliverPrompt(string prompt, LLMTarget target, bool alreadyOnClipboard = false)
    {
        if (!alreadyOnClipboard) TrySetClipboard(prompt);

        var url = target.Url(prompt);
        OpenUrl(url);

        // url.Query is "" when no ?q= prefill was applied (the ≤6000 gate fell back to home).
        bool prefilled = !string.IsNullOrEmpty(url.Query);
        return prefilled
            ? $"Sent to {target.DisplayName()} (full text also on the clipboard)"
            : $"Copied, click the message box in {target.DisplayName()} and press Ctrl+V";
    }

    /// <summary>
    /// Shares plain text via the system. NOTE: the Windows Share sheet
    /// (<c>DataTransferManager.ShowShareUI</c>) needs WinRT interop plus a valid HWND and is not
    /// trivially available from an unpackaged WPF app, so this falls back to the clipboard per spec.
    /// Returns a status message.
    /// </summary>
    public static string SharePlainText(string text)
    {
        return TrySetClipboard(text)
            ? "Copied to clipboard"
            : "Share failed";
    }

    // ---- Helpers ---------------------------------------------------------

    private static bool TrySetClipboard(string text)
    {
        try
        {
            Clipboard.SetText(text ?? string.Empty);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void OpenUrl(Uri url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
        }
        catch
        {
            // Browser launch is best-effort; the clipboard already carries the payload.
        }
    }
}
