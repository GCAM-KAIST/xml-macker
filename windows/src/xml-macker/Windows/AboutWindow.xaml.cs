using System.Diagnostics;
using System.Windows;
using System.Windows.Navigation;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

public partial class AboutWindow : Window
{
    public AboutWindow(string version)
    {
        InitializeComponent();
        ProductText.Text = $"xml-macker  v{version}";
        Acrylic.Apply(this, ThemeManager.Active.IsDark);
    }

    private void Link_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }

    private void Ok_Click(object sender, RoutedEventArgs e) => Close();
}
