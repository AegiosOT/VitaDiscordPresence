using Microsoft.UI.Xaml;

namespace VitaPresence.App;

public partial class App : Application
{
    private SettingsWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new SettingsWindow();
        _window.Activate();
    }
}
