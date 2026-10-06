using System.Drawing;
using H.NotifyIcon;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VitaPresence;

namespace VitaPresence.App;

public sealed partial class SettingsWindow : Window
{
    private readonly AppSession _session = new();
    private readonly Icon _appIcon;
    private readonly Icon _attentionIcon;
    private bool _quitting;
    private bool _sized;
    private bool _loading = true;
    private string _profileKey = "";

    public SettingsWindow()
    {
        InitializeComponent();
        Title = "VitaPresence Settings";
        _appIcon = new Icon(Asset("AppIcon.ico"));
        _attentionIcon = new Icon(Asset("Attention.ico"));
        Tray.Icon = _appIcon;
        Tray.LeftClickCommand = new RelayCommand(Show);
        SettingsItem.Command = new RelayCommand(Show);
        ConnectItem.Command = new RelayCommand(() => _session.Toggle());
        QuitItem.Command = new RelayCommand(() => _ = QuitAsync());
        _session.Post = action => DispatcherQueue.TryEnqueue(() => action());
        _session.Changed += Refresh;
        AppWindow.SetIcon(Asset("AppIcon.ico"));
        AppWindow.Closing += OnClosing;
        Activated += OnActivated;
        LoadControls();
        Refresh();
        _loading = false;
        if (_session.Settings.ConnectOnLaunch) _session.Start();
    }

    private void LoadControls()
    {
        AddressBox.Text = _session.Settings.Address;
        ArtworkToggle.IsOn = _session.Settings.ShowGameArtwork;
        LiveAreaToggle.IsOn = _session.Settings.ShowLiveArea;
        ElapsedToggle.IsOn = _session.Settings.ShowElapsedTime;
        ImageBox.Text = _session.Settings.LargeImageKey;
        StateBox.Text = _session.Settings.StateText;
        OwnAppToggle.IsOn = _session.Settings.UseOwnDiscordApplication;
        ClientIdBox.Text = _session.Settings.ClientId;
        ConnectOnLaunchToggle.IsOn = _session.Settings.ConnectOnLaunch;
        LaunchAtLoginToggle.IsOn = _session.Settings.LaunchAtLogin;
        IntervalBox.Value = _session.Settings.PollInterval;
        OwnAppPanel.Visibility = OwnAppToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (_sized || Content is not FrameworkElement content || content.XamlRoot is null) return;
        _sized = true;
        var scale = content.XamlRoot.RasterizationScale;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(760 * scale), (int)(560 * scale)));
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_quitting) return;
        args.Cancel = true;
        AppWindow.Hide();
    }

    private void Show()
    {
        AppWindow.Show();
        Activate();
    }

    private async Task QuitAsync()
    {
        _quitting = true;
        await _session.StopAsync();
        Tray.Dispose();
        _appIcon.Dispose();
        _attentionIcon.Dispose();
        Close();
    }

    private void Refresh()
    {
        StatusText.Text = _session.Status;
        var connect = _session.IsActive ? "Disconnect" : "Connect";
        ConnectButton.Content = connect;
        ConnectItem.Text = connect;
        WarningText.Text = _session.Warning ?? "";
        WarningText.Visibility = string.IsNullOrEmpty(_session.Warning) ? Visibility.Collapsed : Visibility.Visible;
        ScanRing.IsActive = _session.IsScanning;
        ScanRing.Visibility = _session.IsScanning ? Visibility.Visible : Visibility.Collapsed;
        FindButton.IsEnabled = !_session.IsScanning;
        ShowIssue(AddressIssue, _session.Settings.Issues().FirstOrDefault(issue => issue.Contains("IP", StringComparison.Ordinal)));
        ShowIssue(ClientIssue, _session.Settings.Issues().FirstOrDefault(issue => issue.Contains("application", StringComparison.Ordinal)));
        ShowIssue(ImageWarning, _session.Settings.LargeImageWarning);
        RebuildProfiles();
        RebuildFound();
        Tray.Icon = _session.Attention ? _attentionIcon : _appIcon;
    }

    private void RebuildProfiles()
    {
        var key = string.Join("|", _session.Profiles.Select(profile =>
            $"{profile.Id}:{profile.LastAddress}:{profile.MacAddress}:{profile.Id == _session.SelectedId}"));
        if (key == _profileKey && ProfilesHost.Children.Count > 0) return;
        if (key == _profileKey && _session.Profiles.Count == 0 && ProfilesHost.Children.Count == 1) return;
        _profileKey = key;
        ProfilesHost.Children.Clear();
        if (_session.Profiles.Count == 0)
        {
            ProfilesHost.Children.Add(Card("No Vita saved yet", "Find it on the network. VitaPresence reconnects to it next time, including after its IP address changes."));
            return;
        }
        foreach (var profile in _session.Profiles)
            ProfilesHost.Children.Add(ProfileCard(profile));
    }

    private void RebuildFound()
    {
        FoundHost.Children.Clear();
        foreach (var vita in _session.Found)
        {
            var chosen = _session.Selected?.LastAddress == vita.IpAddress;
            var panel = new Grid { ColumnSpacing = 8 };
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new TextBlock
            {
                Text = vita.IpAddress + "  " + (vita.MacAddress?.ToString() ?? "-") + "\n" + Describe(vita.Title),
                TextWrapping = TextWrapping.Wrap,
            };
            var button = new Button { Content = chosen ? "In use" : "Use", IsEnabled = !chosen };
            button.Click += (_, _) => _session.Use(vita);
            Grid.SetColumn(button, 1);
            panel.Children.Add(text);
            panel.Children.Add(button);
            FoundHost.Children.Add(panel);
        }
    }

    private UIElement ProfileCard(VitaProfile profile)
    {
        var panel = new StackPanel { Spacing = 4 };
        var name = new TextBox { Text = profile.Name, PlaceholderText = "PS Vita" };
        name.TextChanged += (_, _) =>
        {
            profile.Name = name.Text;
            _session.Save();
        };
        var inUse = profile.Id == _session.SelectedId;
        var details = string.IsNullOrEmpty(profile.LastAddress) ? "Not seen yet" : profile.LastAddress;
        if (!string.IsNullOrEmpty(profile.MacAddress)) details += "  ·  " + profile.MacAddress;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var use = new Button { Content = inUse ? "In use" : "Use", IsEnabled = !inUse };
        use.Click += (_, _) => _session.Select(profile);
        var remove = new Button { Content = "Remove" };
        remove.Click += (_, _) => _session.Remove(profile);
        row.Children.Add(use);
        row.Children.Add(remove);
        panel.Children.Add(name);
        panel.Children.Add(new TextBlock { Text = details, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        panel.Children.Add(row);
        return new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Child = panel,
        };
    }

    private static Border Card(string title, string body)
    {
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new TextBlock
        {
            Text = body,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        return new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Child = panel,
        };
    }

    private static void ShowIssue(TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string Describe(VitaTitle title)
    {
        if (title.IsLiveArea || title.TitleId.Length == 0 || title.TitleId == title.DisplayName) return title.DisplayName;
        return title.DisplayName + " (" + title.TitleId + ")";
    }

    private void Connect_Click(object sender, RoutedEventArgs e) => _session.Toggle();

    private async void Find_Click(object sender, RoutedEventArgs e) => await _session.ScanAsync();

    private void Address_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.Address = AddressBox.Text;
        _session.Save();
        Refresh();
    }

    private void Setting_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.ShowGameArtwork = ArtworkToggle.IsOn;
        _session.Settings.ShowLiveArea = LiveAreaToggle.IsOn;
        _session.Settings.ShowElapsedTime = ElapsedToggle.IsOn;
        _session.Settings.ConnectOnLaunch = ConnectOnLaunchToggle.IsOn;
        _session.Save();
    }

    private void Launch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.LaunchAtLogin = LaunchAtLoginToggle.IsOn;
        AppSession.ApplyLaunchAtLogin(LaunchAtLoginToggle.IsOn);
        _session.Save();
    }

    private void OwnApp_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.UseOwnDiscordApplication = OwnAppToggle.IsOn;
        OwnAppPanel.Visibility = OwnAppToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
        _session.Save();
        Refresh();
    }

    private void Image_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.LargeImageKey = ImageBox.Text;
        _session.Save();
        ShowIssue(ImageWarning, _session.Settings.LargeImageWarning);
    }

    private void State_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.StateText = StateBox.Text;
        _session.Save();
    }

    private void ClientId_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        _session.Settings.ClientId = ClientIdBox.Text;
        _session.Save();
        ShowIssue(ClientIssue, _session.Settings.Issues().FirstOrDefault(issue => issue.Contains("application", StringComparison.Ordinal)));
    }

    private void Interval_Changed(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loading || double.IsNaN(args.NewValue)) return;
        _session.Settings.PollInterval = args.NewValue;
        _session.Save();
    }

    private static string Asset(string name) => Path.Combine(AppContext.BaseDirectory, "Assets", name);
}
