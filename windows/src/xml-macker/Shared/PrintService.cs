using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace XMLMacker.Shared;

/// <summary>
/// Paginated monospaced printing, the WPF port of the AppKit <c>runPrint(text, jobTitle)</c>
/// pipeline. Always black text on a white page regardless of the app theme;
/// 9 pt monospaced (Cascadia Mono, falling back to Consolas). The job title is used as the print
/// job name (the "header" the OS shows in the print queue).
/// Margins mirror the Swift original: left/right 32, top/bottom 36 (points).
/// </summary>
public static class PrintService
{
    // 9 pt → device-independent units (WPF FontSize is 1/96 inch): 9 * 96/72 = 12.
    private const double MonoFontSizeDiu = 12.0;
    private const double SideMargin = 32.0;   // left/right
    private const double TopBottomMargin = 36.0;

    private static readonly FontFamily MonoFamily = new("Cascadia Mono, Consolas, Courier New");

    /// <summary>
    /// Shows the print dialog and, if the dialog is confirmed, prints <paramref name="text"/> paginated in
    /// a monospaced black-on-white document. <paramref name="jobTitle"/> names the print job.
    /// </summary>
    public static void Print(string text, string jobTitle)
    {
        var dialog = new PrintDialog();
        if (dialog.ShowDialog() != true)
            return;

        FlowDocument doc = BuildDocument(text, dialog);
        IDocumentPaginatorSource source = doc;
        dialog.PrintDocument(source.DocumentPaginator, jobTitle ?? string.Empty);
    }

    private static FlowDocument BuildDocument(string text, PrintDialog dialog)
    {
        var doc = new FlowDocument
        {
            FontFamily = MonoFamily,
            FontSize = MonoFontSizeDiu,
            Foreground = Brushes.Black,
            Background = Brushes.White,
            PagePadding = new Thickness(SideMargin, TopBottomMargin, SideMargin, TopBottomMargin),
            ColumnWidth = double.PositiveInfinity   // single column (no newspaper columns)
        };

        // Size the page to the printable area so pagination matches the selected printer.
        double pageWidth = dialog.PrintableAreaWidth;
        double pageHeight = dialog.PrintableAreaHeight;
        if (pageWidth > 0) doc.PageWidth = pageWidth;
        if (pageHeight > 0) doc.PageHeight = pageHeight;

        var para = new Paragraph
        {
            Margin = new Thickness(0),
            // Preserve source spacing exactly (no auto line-height inflation).
            LineHeight = MonoFontSizeDiu * 1.2
        };

        // Preserve line breaks explicitly so monospaced source layout is faithful.
        string[] lines = (text ?? string.Empty).Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            para.Inlines.Add(new Run(lines[i]));
            if (i < lines.Length - 1)
                para.Inlines.Add(new LineBreak());
        }

        doc.Blocks.Add(para);
        return doc;
    }
}
