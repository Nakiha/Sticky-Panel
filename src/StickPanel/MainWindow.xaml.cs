using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using StickPanel.Models;
using StickPanel.Services;
using Windows.Graphics;
using Windows.System;
using WinRT.Interop;

namespace StickPanel;

public sealed partial class MainWindow : Window
{
    private readonly ObservableCollection<TaskItem> _tasks = [];
    private readonly PanelStateStore _stateStore = new();
    private readonly DispatcherTimer _saveTimer;
    private AppWindow? _appWindow;
    private bool _isRestoring = true;

    public MainWindow()
    {
        InitializeComponent();

        SystemBackdrop = new DesktopAcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleDragRegion);

        TaskList.ItemsSource = _tasks;
        _tasks.CollectionChanged += Tasks_CollectionChanged;

        _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        _saveTimer.Tick += SaveTimer_Tick;

        ConfigureWindow();
        RestoreState();
        Closed += MainWindow_Closed;
        _isRestoring = false;
        UpdateSummary();
    }

    private void ConfigureWindow()
    {
        var windowHandle = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _appWindow.Title = "Stick Panel";
        _appWindow.Changed += AppWindow_Changed;

        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = true;
            presenter.IsResizable = true;
        }

        _appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
    }

    private void RestoreState()
    {
        var state = _stateStore.Load();
        PanelTitleBox.Text = state.Title;

        foreach (var item in state.Tasks)
        {
            Subscribe(item);
            _tasks.Add(item);
        }

        TopmostButton.IsChecked = state.AlwaysOnTop;
        ApplyTopmost(state.AlwaysOnTop);

        var width = Math.Clamp(state.Width, 300, 1200);
        var height = Math.Clamp(state.Height, 300, 1400);
        _appWindow?.Resize(new SizeInt32(width, height));

        if (state.X != int.MinValue && state.Y != int.MinValue)
        {
            var requestedPosition = new PointInt32(state.X, state.Y);
            var area = DisplayArea.GetFromPoint(requestedPosition, DisplayAreaFallback.Nearest);
            var workArea = area.WorkArea;
            var x = Math.Clamp(state.X, workArea.X, workArea.X + Math.Max(0, workArea.Width - width));
            var y = Math.Clamp(state.Y, workArea.Y, workArea.Y + Math.Max(0, workArea.Height - height));
            _appWindow?.Move(new PointInt32(x, y));
        }
    }

    private void ApplyTopmost(bool isTopmost)
    {
        if (_appWindow?.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = isTopmost;
        }
    }

    private void AddTask(string text)
    {
        var cleanedText = text.Trim();
        if (cleanedText.Length == 0) return;

        var task = new TaskItem { Text = cleanedText };
        Subscribe(task);
        _tasks.Add(task);
        NewTaskBox.Text = string.Empty;
        ScheduleSave();

        TaskList.UpdateLayout();
        TaskList.ScrollIntoView(task);
    }

    private void Subscribe(TaskItem item) => item.PropertyChanged += Task_PropertyChanged;

    private void Unsubscribe(TaskItem item) => item.PropertyChanged -= Task_PropertyChanged;

    private void Task_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        UpdateSummary();
        ScheduleSave();
    }

    private void Tasks_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        UpdateSummary();
    }

    private void UpdateSummary()
    {
        if (TaskCountText is null) return;

        var remaining = _tasks.Count(task => !task.IsDone);
        var finished = _tasks.Count - remaining;
        TaskCountText.Text = _tasks.Count == 0
            ? "No tasks"
            : $"{remaining} left  ·  {finished} done";

        EmptyState.Opacity = _tasks.Count == 0 ? 0.62 : 0;
        ClearCompletedButton.IsEnabled = finished > 0;
    }

    private PanelState CaptureState()
    {
        var position = _appWindow?.Position ?? new PointInt32(int.MinValue, int.MinValue);
        var size = _appWindow?.Size ?? new SizeInt32(390, 520);

        return new PanelState
        {
            Title = PanelTitleBox.Text.Trim(),
            Tasks = _tasks.ToList(),
            AlwaysOnTop = TopmostButton.IsChecked == true,
            X = position.X,
            Y = position.Y,
            Width = size.Width,
            Height = size.Height
        };
    }

    private void ScheduleSave()
    {
        if (_isRestoring) return;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void SaveNow()
    {
        _saveTimer.Stop();
        try
        {
            _stateStore.Save(CaptureState());
            SaveErrorBar.IsOpen = false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SaveErrorBar.Message = $"Keep StickPanel.exe in a writable folder. Data path: {_stateStore.DataPath}";
            SaveErrorBar.IsOpen = true;
        }
    }

    private void AddTask_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(NewTaskBox.Text)) AddTask(NewTaskBox.Text);
        NewTaskBox.Focus(FocusState.Programmatic);
    }

    private void NewTaskBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            AddTask_Click(sender, e);
        }
    }

    private void TaskTextBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (e.Key == VirtualKey.Enter && !shift)
        {
            e.Handled = true;
            NewTaskBox.Focus(FocusState.Programmatic);
        }
    }

    private void TaskTextBox_LostFocus(object sender, RoutedEventArgs e) => ScheduleSave();

    private void TaskCheckBox_Click(object sender, RoutedEventArgs e)
    {
        UpdateSummary();
        ScheduleSave();
    }

    private void DeleteTask_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: TaskItem item }) return;
        Unsubscribe(item);
        _tasks.Remove(item);
        ScheduleSave();
    }

    private void ClearCompleted_Click(object sender, RoutedEventArgs e)
    {
        foreach (var item in _tasks.Where(task => task.IsDone).ToList())
        {
            Unsubscribe(item);
            _tasks.Remove(item);
        }
        ScheduleSave();
    }

    private void TopmostButton_Changed(object sender, RoutedEventArgs e)
    {
        ApplyTopmost(TopmostButton.IsChecked == true);
        ScheduleSave();
    }

    private void AnyTextChanged(object sender, TextChangedEventArgs e) => ScheduleSave();

    private void MainRoot_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (ctrl && shift && e.Key == VirtualKey.A)
        {
            TopmostButton.IsChecked = TopmostButton.IsChecked != true;
            e.Handled = true;
        }
        else if (ctrl && e.Key == VirtualKey.Enter)
        {
            NewTaskBox.Focus(FocusState.Programmatic);
            e.Handled = true;
        }
        else if (ctrl && e.Key == VirtualKey.S)
        {
            SaveNow();
            e.Handled = true;
        }
    }

    private void SaveTimer_Tick(object? sender, object e) => SaveNow();

    private void AppWindow_Changed(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidPositionChange || args.DidSizeChange) ScheduleSave();
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        SaveNow();
        foreach (var item in _tasks) Unsubscribe(item);
    }
}
