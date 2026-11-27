#requires -Version 5.1
<#
  System Dashboard - floating system monitor widget (PowerShell 5.1 + WinForms).
  Build state: steps 1-6 (shell, samplers, views, CSV history, alerts, popups, full settings menu, frosted glass).
  Everything is stored in .\MonitorData next to this script.
#>
param([switch]$Child)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- launcher
# Start a hidden, detached child so closing a terminal never kills the widget.
if (-not $Child) {
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden',
                     '-File', ('"' + $PSCommandPath + '"'), '-Child')
        Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    } catch {
        try { [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-error.txt'), [string]$_) } catch { }
    }
    exit
}

# ---------------------------------------------------------------- paths
$script:Version  = '1.2.0'
$script:DataDir  = Join-Path $PSScriptRoot 'MonitorData'
if (-not (Test-Path -LiteralPath $script:DataDir)) { [void](New-Item -ItemType Directory -Path $script:DataDir -Force) }
$script:LogPath      = Join-Path $script:DataDir 'widget.log'
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:AlertsPath   = Join-Path $script:DataDir 'alerts.csv'

# ---------------------------------------------------------------- single instance
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\SystemDashboardWidget_v1', [ref]$createdNew)
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\SystemDashboardShow')
if (-not $createdNew) {
    # A copy is already running: ask it to show itself, then leave.
    try { [void]$script:ShowEvent.Set() } catch { }
    try { $script:ShowEvent.Dispose() } catch { }
    try { $script:Mutex.Dispose() } catch { }
    exit 0
}

# ---------------------------------------------------------------- native helpers (C# 5)
$script:CSharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// Which window edge / corner is under a point (client coordinates)? Returns the Windows hit-test code
// (HTLEFT 10, HTRIGHT 11, HTTOP 12, HTTOPLEFT 13, HTTOPRIGHT 14, HTBOTTOM 15, HTBOTTOMLEFT 16, HTBOTTOMRIGHT 17) or 0.
// mode 0 = not resizable, 1 = width only (left / right edges), 2 = width and height.
public static class EdgeHit
{
    public static int Test(int x, int y, int w, int h, int grip, int mode)
    {
        if (mode <= 0 || w <= 0 || h <= 0) return 0;
        int corner = grip * 2;
        bool left = x < grip, right = x >= w - grip;
        if (mode == 1)
        {
            if (left) return 10;
            if (right) return 11;
            return 0;
        }
        bool top = y < grip, bottom = y >= h - grip;
        bool cl = x < corner, cr = x >= w - corner, ct = y < corner, cb = y >= h - corner;
        if ((top && cl) || (left && ct)) return 13;
        if ((top && cr) || (right && ct)) return 14;
        if ((bottom && cl) || (left && cb)) return 16;
        if ((bottom && cr) || (right && cb)) return 17;
        if (left) return 10;
        if (right) return 11;
        if (top) return 12;
        if (bottom) return 15;
        return 0;
    }
}

public class BufferedForm : Form
{
    public bool ClickThrough = false;
    public int GripMode = 0;     // 0 none, 1 width only, 2 width and height
    public int Grip = 6;         // thickness of the resize edge in pixels
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0084 && GripMode > 0 && !ClickThrough && WindowState == FormWindowState.Normal)   // WM_NCHITTEST
        {
            long lp = m.LParam.ToInt64();
            int sx = (short)(lp & 0xFFFF);
            int sy = (short)((lp >> 16) & 0xFFFF);
            Point pt = PointToClient(new Point(sx, sy));
            int ht = EdgeHit.Test(pt.X, pt.Y, ClientSize.Width, ClientSize.Height, Grip, GripMode);
            if (ht != 0) { m.Result = (IntPtr)ht; return; }
        }
        base.WndProc(ref m);
    }
    public BufferedForm()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DoubleBuffered = true;
    }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.Style |= 0x00020000; // WS_MINIMIZEBOX so the taskbar button can minimize/restore
            if (ClickThrough) cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT
            return cp;
        }
    }
}

// Toast window: never takes focus, no taskbar button.
public class PopupForm : Form
{
    public PopupForm()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DoubleBuffered = true;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            return cp;
        }
    }
}

// Window drawn from a bitmap with per-pixel alpha: transparent where the bitmap is transparent
// (used by the taskbar widget so only the text shows). Never takes focus, no taskbar button.
public class LayeredBadgeForm : Form
{
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);

    public LayeredBadgeForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
            return cp;
        }
    }

    // bmp must be 32 bits per pixel with alpha. x, y = where the window goes on the screen.
    public void SetBitmap(Bitmap bmp, int x, int y)
    {
        if (!IsHandleCreated) return;
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBmp = IntPtr.Zero;
        IntPtr old = IntPtr.Zero;
        try
        {
            hBmp = bmp.GetHbitmap(Color.FromArgb(0));
            old = SelectObject(memDc, hBmp);
            SIZE size = new SIZE(); size.cx = bmp.Width; size.cy = bmp.Height;
            POINT src = new POINT();
            POINT dst = new POINT(); dst.x = x; dst.y = y;
            BLENDFUNCTION bf = new BLENDFUNCTION();
            bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1; // AC_SRC_ALPHA
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, 2); // ULW_ALPHA
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, screenDc);
            if (hBmp != IntPtr.Zero) { SelectObject(memDc, old); DeleteObject(hBmp); }
            DeleteDC(memDc);
        }
    }
}

public static class Native
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Rectangles of the taskbar and of its notification area (clock, tray icons, the ^ button).
    public static bool GetTaskbarRects(out Rectangle tray, out Rectangle notify)
    {
        tray = Rectangle.Empty; notify = Rectangle.Empty;
        IntPtr t = FindWindow("Shell_TrayWnd", null);
        if (t == IntPtr.Zero) return false;
        RECT r;
        if (!GetWindowRect(t, out r)) return false;
        tray = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        IntPtr n = FindWindowEx(t, IntPtr.Zero, "TrayNotifyWnd", null);
        if (n != IntPtr.Zero && GetWindowRect(n, out r)) notify = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        return true;
    }

    public static IntPtr GetTaskbarHandle() { return FindWindow("Shell_TrayWnd", null); }

    // Re-raise a topmost window above the taskbar (the taskbar rises when it is clicked).
    public static void KeepTopMost(IntPtr h)
    {
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); // NOSIZE | NOMOVE | NOACTIVATE
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    private static readonly uint OwnPid = (uint)Process.GetCurrentProcess().Id;

    // Seconds since the last keyboard or mouse input.
    public static double IdleSeconds()
    {
        LASTINPUTINFO l = new LASTINPUTINFO();
        l.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref l)) return 0;
        uint now = (uint)Environment.TickCount;
        return (now - l.dwTime) / 1000.0;
    }

    // True when another program's window covers its whole monitor (game, video, F11 browser...).
    public static bool IsFullscreenForeground()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        if (pid == OwnPid) return false;
        if (!IsWindowVisible(h) || IsIconic(h) || IsZoomed(h)) return false;
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
        RECT r;
        if (!GetWindowRect(h, out r)) return false;
        Rectangle b = Screen.FromHandle(h).Bounds;
        return r.Left <= b.Left && r.Top <= b.Top && r.Right >= b.Right && r.Bottom >= b.Bottom;
    }
}

// Thread-safe log file with self-rotation (256 KB, one .old file).
public static class WLog
{
    private static readonly object Gate = new object();
    private static bool hooked = false;
    public static string LogPath = "";

    public static void Write(string msg)
    {
        if (string.IsNullOrEmpty(LogPath)) return;
        lock (Gate)
        {
            try
            {
                FileInfo fi = new FileInfo(LogPath);
                if (fi.Exists && fi.Length > 262144)
                {
                    string old = LogPath + ".old";
                    try { if (File.Exists(old)) File.Delete(old); File.Move(LogPath, old); } catch (Exception) { }
                }
                File.AppendAllText(LogPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + msg + Environment.NewLine,
                    new UTF8Encoding(false));
            }
            catch (Exception) { }
        }
    }

    public static void HookAll()
    {
        if (hooked) return;
        hooked = true;
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += OnThreadException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandled;
    }

    private static void OnThreadException(object sender, System.Threading.ThreadExceptionEventArgs e)
    {
        Write("Application.ThreadException: " + e.Exception);
    }

    private static void OnUnhandled(object sender, UnhandledExceptionEventArgs e)
    {
        Write("AppDomain.UnhandledException (terminating=" + e.IsTerminating + "): " + e.ExceptionObject);
    }
}

// CSV appender that keeps rows in memory while the file is locked (for example open in Excel).
public class CsvAppender
{
    private readonly string header;
    private readonly List<string> pending = new List<string>();
    private string lastError = "";

    public CsvAppender(string headerLine) { header = headerLine; }
    public int PendingCount { get { return pending.Count; } }
    public string LastError { get { return lastError; } }

    public bool Write(string filePath, string line)
    {
        if (line != null)
        {
            pending.Add(line);
            if (pending.Count > 5000) pending.RemoveRange(0, pending.Count - 5000);
        }
        return Flush(filePath);
    }

    public bool Flush(string filePath)
    {
        if (pending.Count == 0) return true;
        try
        {
            bool needHeader = !File.Exists(filePath) || new FileInfo(filePath).Length == 0;
            using (FileStream fs = new FileStream(filePath, FileMode.Append, FileAccess.Write, FileShare.Read))
            using (StreamWriter sw = new StreamWriter(fs, new UTF8Encoding(false)))
            {
                if (needHeader) sw.WriteLine(header);
                for (int i = 0; i < pending.Count; i++) sw.WriteLine(pending[i]);
            }
            pending.Clear();
            lastError = "";
            return true;
        }
        catch (Exception ex)
        {
            lastError = ex.Message;
            return false;
        }
    }
}

// Reads the "GPU Engine" counters in one pass (fast). Usage = max over engine types of the summed utilization.
public class GpuReader
{
    private PerformanceCounterCategory cat;
    private PerformanceCounterCategory memCat;
    private Dictionary<string, CounterSample> prev = new Dictionary<string, CounterSample>();
    public bool Available;
    public double Usage = -1;
    public int TopPid = -1;
    public double TopPidValue = 0;
    public double VramUsedBytes = -1;

    public GpuReader()
    {
        try
        {
            if (PerformanceCounterCategory.Exists("GPU Engine"))
            {
                cat = new PerformanceCounterCategory("GPU Engine");
                Available = true;
            }
        }
        catch (Exception) { Available = false; }
        try
        {
            if (PerformanceCounterCategory.Exists("GPU Adapter Memory"))
                memCat = new PerformanceCounterCategory("GPU Adapter Memory");
        }
        catch (Exception) { memCat = null; }
    }

    private static int ParsePid(string key)
    {
        if (!key.StartsWith("pid_", StringComparison.Ordinal)) return -1;
        int e = key.IndexOf('_', 4);
        if (e < 0) return -1;
        int pid;
        if (int.TryParse(key.Substring(4, e - 4), out pid)) return pid;
        return -1;
    }

    public void Sample()
    {
        if (!Available) { Usage = -1; return; }
        InstanceDataCollectionCollection data = cat.ReadCategory();
        InstanceDataCollection coll = data["Utilization Percentage"];
        if (coll == null) { Usage = -1; return; }

        Dictionary<string, CounterSample> now = new Dictionary<string, CounterSample>();
        Dictionary<string, double> byType = new Dictionary<string, double>();
        Dictionary<int, double> byPid = new Dictionary<int, double>();
        foreach (string key in coll.Keys)
        {
            CounterSample cur = coll[key].Sample;
            now[key] = cur;
            CounterSample p;
            if (!prev.TryGetValue(key, out p)) continue;
            float v = CounterSample.Calculate(p, cur);
            if (float.IsNaN(v) || v <= 0f) continue;
            string type = "x";
            int ei = key.IndexOf("engtype_", StringComparison.Ordinal);
            if (ei >= 0) type = key.Substring(ei + 8);
            double acc;
            byType.TryGetValue(type, out acc);
            byType[type] = acc + v;
            int pid = ParsePid(key);
            if (pid >= 0)
            {
                double pa;
                byPid.TryGetValue(pid, out pa);
                byPid[pid] = pa + v;
            }
        }
        prev = now;

        double max = 0;
        foreach (KeyValuePair<string, double> kv in byType) { if (kv.Value > max) max = kv.Value; }
        Usage = Math.Min(100.0, max);

        int top = -1; double topv = 0;
        foreach (KeyValuePair<int, double> kv in byPid) { if (kv.Value > topv) { topv = kv.Value; top = kv.Key; } }
        TopPid = top; TopPidValue = topv;

        VramUsedBytes = -1;
        if (memCat != null)
        {
            try
            {
                InstanceDataCollectionCollection md = memCat.ReadCategory();
                InstanceDataCollection dc = md["Dedicated Usage"];
                if (dc != null)
                {
                    double sum = 0; bool any = false;
                    foreach (string k in dc.Keys) { sum += dc[k].RawValue; any = true; }
                    if (any) VramUsedBytes = sum;
                }
            }
            catch (Exception) { VramUsedBytes = -1; }
        }
    }
}

// Builds MonitorData\history.html / alerts.html / network.html (system history, alerts, network history, log) on a background thread.
public static class HistoryPage
{
    public static volatile string Status = "idle";
    private static readonly string[] Cols = new string[] { "cpu", "gpu", "mem", "down", "up", "disk" };
    private static readonly int[] Idx = new int[] { 1, 2, 3, 5, 6, 7 };
    private static readonly string[] NetCols = new string[] { "sig", "ndown", "nup", "rping", "iping" };
    private static readonly int[] NetIdx = new int[] { 4, 8, 9, 10, 11 };
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    public static int SlowLimit = 10;
    public static int DataLimitGB = 0;
    public static int DataResetDay = 1;

    public static void BuildAsync(string dataDir, string outPath, string template, string themeCss, string startTab)
    {
        Status = "running";
        Thread th = new Thread(delegate ()
        {
            try
            {
                string json = BuildJson(dataDir);
                string html = template.Replace("/*THEME*/", themeCss).Replace("__TAB__", startTab).Replace("__DATA__", json);
                File.WriteAllText(outPath, html, new UTF8Encoding(false));
                Status = "done";
            }
            catch (Exception ex) { Status = "error: " + ex.Message; }
        });
        th.IsBackground = true;
        th.Start();
    }

    // Local time written as if it were UTC, so the page can show the same clock time as the widget.
    private static double Epoch(DateTime d) { return (d - new DateTime(1970, 1, 1)).TotalSeconds; }

    public static string BuildJson(string dir)
    {
        DateTime now = DateTime.Now;
        StringBuilder sb = new StringBuilder(1 << 17);
        sb.Append("{\"now\":").Append(Epoch(now).ToString("0", Inv));
        sb.Append(",\"fine\":");
        AppendSeries(sb, dir, now, 1, 1440, "history", Cols, Idx, 8, false);
        sb.Append(",\"coarse\":");
        AppendSeries(sb, dir, now, 30, 2000, "history", Cols, Idx, 8, false);
        sb.Append(",\"net\":{\"fine\":");
        AppendSeries(sb, dir, now, 1, 1440, "network", NetCols, NetIdx, 12, true);
        sb.Append(",\"coarse\":");
        AppendSeries(sb, dir, now, 30, 2000, "network", NetCols, NetIdx, 12, true);
        sb.Append("}");
        sb.Append(",\"alerts\":");
        AppendCsvRows(sb, dir, "alerts.csv", 300, 5);
        sb.Append(",\"speed\":");
        AppendCsvRows(sb, dir, "speedtests.csv", 1000, 9);
        sb.Append(",\"fulls\":");
        AppendCsvRows(sb, dir, "fulltests.csv", 60, 15);
        sb.Append(",\"devEvents\":");
        AppendCsvRows(sb, dir, "device-events.csv", 150, 7);
        sb.Append(",\"fullLatest\":");
        AppendLatestFull(sb, dir);
        sb.Append(",\"outages\":");
        AppendCsvRows(sb, dir, "outages.csv", 600, 6);
        sb.Append(",\"usage\":");
        AppendRawJson(sb, Path.Combine(dir, "usage.json"), "{}");
        sb.Append(",\"scan\":");
        AppendRawJson(sb, Path.Combine(dir, "wifi-scan.json"), "null");
        sb.Append(",\"limit\":").Append(SlowLimit).Append(",\"dataLimit\":").Append(DataLimitGB).Append(",\"resetDay\":").Append(DataResetDay);
        sb.Append(",\"devices\":");
        AppendRawJson(sb, Path.Combine(dir, "devices.json"), "[]");
        sb.Append(",\"log\":");
        AppendLog(sb, dir);
        sb.Append("}");
        return sb.ToString();
    }

    private static void AppendSeries(StringBuilder sb, string dir, DateTime now, int days, int maxPoints, string prefix, string[] cols, int[] idx, int minFields, bool emitMissing)
    {
        DateTime cutoff = now.AddDays(-days);
        double start = Epoch(cutoff);
        double step = Math.Max(1.0, Math.Ceiling(days * 86400.0 / maxPoints));
        int n = (int)Math.Ceiling(days * 86400.0 / step) + 1;
        int c = cols.Length;
        double[][] sum = new double[c][];
        double[][] max = new double[c][];
        int[][] cnt = new int[c][];
        int[][] miss = new int[c][];
        for (int i = 0; i < c; i++) { sum[i] = new double[n]; max[i] = new double[n]; cnt[i] = new int[n]; miss[i] = new int[n]; }
        string[] files = Directory.GetFiles(dir, prefix + "-*.csv*");
        Array.Sort(files, StringComparer.Ordinal);
        DateTime cutMonth = new DateTime(cutoff.Year, cutoff.Month, 1);
        int rows = 0;
        foreach (string f in files)
        {
            string name = Path.GetFileName(f);
            if (name.Length < 19) continue;
            int y, m;
            if (!int.TryParse(name.Substring(8, 4), out y) || !int.TryParse(name.Substring(13, 2), out m)) continue;
            if (m < 1 || m > 12 || new DateTime(y, m, 1) < cutMonth) continue;
            try { rows += ReadFile(f, cutoff, start, step, n, sum, max, cnt, miss, idx, minFields); } catch (Exception) { }
        }
        sb.Append("{\"start\":").Append(start.ToString("0", Inv));
        sb.Append(",\"step\":").Append(step.ToString("0", Inv));
        sb.Append(",\"n\":").Append(n).Append(",\"rows\":").Append(rows);
        for (int k = 0; k < c; k++)
        {
            AppendArr(sb, cols[k], sum[k], cnt[k], false);
            AppendArr(sb, cols[k] + "M", max[k], cnt[k], true);
            if (emitMissing) { AppendMissing(sb, cols[k] + "X", miss[k]); AppendMissing(sb, cols[k] + "N", cnt[k]); }
        }
        sb.Append("}");
    }

    private static void AppendArr(StringBuilder sb, string key, double[] vals, int[] cnt, bool isMax)
    {
        sb.Append(",\"").Append(key).Append("\":[");
        for (int i = 0; i < vals.Length; i++)
        {
            if (i > 0) sb.Append(',');
            if (cnt[i] == 0) sb.Append("null");
            else sb.Append((isMax ? vals[i] : vals[i] / cnt[i]).ToString("0.##", Inv));
        }
        sb.Append(']');
    }

    // number of samples per bucket where the value was empty (for the ping columns: the ping got no answer)
    private static void AppendMissing(StringBuilder sb, string key, int[] miss)
    {
        sb.Append(",\"").Append(key).Append("\":[");
        for (int i = 0; i < miss.Length; i++) { if (i > 0) sb.Append(','); sb.Append(miss[i]); }
        sb.Append(']');
    }

    private static int ReadFile(string f, DateTime cutoff, double start, double step, int n, double[][] sum, double[][] max, int[][] cnt, int[][] miss, int[] idx, int minFields)
    {
        int rows = 0;
        using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            Stream s = fs;
            if (f.EndsWith(".gz", StringComparison.OrdinalIgnoreCase)) s = new GZipStream(fs, CompressionMode.Decompress);
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    if (line.Length < 20 || line[0] == 'T') continue;
                    string[] p = line.Split(',');
                    if (p.Length < minFields) continue;
                    DateTime t;
                    if (!DateTime.TryParseExact(p[0], "yyyy-MM-dd HH:mm:ss", Inv, DateTimeStyles.None, out t)) continue;
                    if (t < cutoff) continue;
                    int b = (int)((Epoch(t) - start) / step);
                    if (b < 0 || b >= n) continue;
                    for (int k = 0; k < idx.Length; k++)
                    {
                        double v;
                        string cell = p[idx[k]];
                        if (cell.Length == 0) { miss[k][b]++; continue; }
                        if (!double.TryParse(cell, NumberStyles.Float, Inv, out v)) continue;
                        sum[k][b] += v;
                        if (cnt[k][b] == 0 || v > max[k][b]) max[k][b] = v;
                        cnt[k][b]++;
                    }
                    rows++;
                }
            }
        }
        return rows;
    }

    private static List<string> ReadLines(string path)
    {
        List<string> lines = new List<string>();
        if (!File.Exists(path)) return lines;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
        {
            string line;
            while ((line = sr.ReadLine()) != null) lines.Add(line);
        }
        return lines;
    }

    private static List<string> SplitCsv(string line)
    {
        List<string> res = new List<string>();
        StringBuilder cur = new StringBuilder();
        bool q = false;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (q)
            {
                if (c == '"') { if (i + 1 < line.Length && line[i + 1] == '"') { cur.Append('"'); i++; } else q = false; }
                else cur.Append(c);
            }
            else if (c == '"') q = true;
            else if (c == ',') { res.Add(cur.ToString()); cur.Length = 0; }
            else cur.Append(c);
        }
        res.Add(cur.ToString());
        return res;
    }

    private static void AppendStr(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '<') sb.Append("\\u003c");
            else if (c < 32 || c == '\u2028' || c == '\u2029') sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        sb.Append('"');
    }

    // last maxRows data rows of a CSV file, as arrays of nCols strings (the header row is skipped)
    private static void AppendCsvRows(StringBuilder sb, string dir, string file, int maxRows, int nCols)
    {
        sb.Append('[');
        List<string> lines = ReadLines(Path.Combine(dir, file));
        bool first = true;
        for (int i = Math.Max(1, lines.Count - maxRows); i < lines.Count; i++)
        {
            List<string> f = SplitCsv(lines[i]);
            if (f.Count < 2) continue;
            if (!first) sb.Append(',');
            first = false;
            sb.Append('[');
            for (int j = 0; j < nCols; j++) { if (j > 0) sb.Append(','); AppendStr(sb, j < f.Count ? f[j] : ""); }
            sb.Append(']');
        }
        sb.Append(']');
    }

    // a JSON file copied into the page as is (only if it looks complete)
    private static void AppendRawJson(StringBuilder sb, string path, string fallback)
    {
        string text = fallback;
        try
        {
            if (File.Exists(path) && new FileInfo(path).Length < 600000)
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                {
                    string t = sr.ReadToEnd().Trim();
                    bool ok = t.Length > 1 && ((t[0] == '{' && t[t.Length - 1] == '}') || (t[0] == '[' && t[t.Length - 1] == ']'));
                    if (ok) text = t;
                }
            }
        }
        catch (Exception) { text = fallback; }
        sb.Append(text.Replace("<", "\\u003c"));
    }

    private static void AppendLatestFull(StringBuilder sb, string dir)
    {
        string d = Path.Combine(dir, "fulltests");
        string path = "";
        try
        {
            if (Directory.Exists(d))
            {
                string[] files = Directory.GetFiles(d, "fulltest-*.json");
                Array.Sort(files, StringComparer.Ordinal);
                if (files.Length > 0) path = files[files.Length - 1];
            }
        }
        catch (Exception) { path = ""; }
        if (path.Length == 0) sb.Append("null");
        else AppendRawJson(sb, path, "null");
    }

    private static void AppendLog(StringBuilder sb, string dir)
    {
        sb.Append('[');
        List<string> lines = ReadLines(Path.Combine(dir, "widget.log"));
        bool first = true;
        for (int i = Math.Max(0, lines.Count - 600); i < lines.Count; i++)
        {
            if (!first) sb.Append(',');
            first = false;
            AppendStr(sb, lines[i]);
        }
        sb.Append(']');
    }
}
'@

try {
    if (-not ('BufferedForm' -as [type])) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition $script:CSharp -Language CSharp
    }
} catch {
    try { Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('s') + '  FATAL Add-Type failed: ' + $_) } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
    exit 1
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[WLog]::LogPath = $script:LogPath
[WLog]::HookAll()

function Write-Log([string]$msg, [string]$level = 'info') {
    try {
        if ($level -ne 'error' -and $null -ne $script:Settings -and [string]$script:Settings['LogLevel'] -eq 'Quiet') {
            if ($msg -notmatch '^(Start v|Exit|Shutting down|ALERT|FATAL|Sampler (?!started|stopped))' -and $msg -notmatch '(?i)(fail|error|exception|unavailable|not writable|unexpected)') { return }
        }
        [WLog]::Write($msg)
    } catch { }
}

$script:LogOnceAt = @{}
function Log-Once([string]$key, [string]$msg) {
    $now = [DateTime]::UtcNow
    $last = $script:LogOnceAt[$key]
    if ($null -eq $last -or ($now - $last).TotalSeconds -gt 30) {
        $script:LogOnceAt[$key] = $now
        Write-Log ($key + ': ' + $msg) 'error'
    }
}

function Err-Text($er) {
    try {
        $ln = ''
        if ($er.InvocationInfo -and $er.InvocationInfo.Line) { $ln = $er.InvocationInfo.Line.Trim() }
        return ($er.Exception.Message + ' [line ' + $er.InvocationInfo.ScriptLineNumber + ': ' + $ln + ']')
    } catch { return [string]$er }
}

# Hide any stray console window.
try { $ch = [Native]::GetConsoleWindow(); if ($ch -ne [IntPtr]::Zero) { [void][Native]::ShowWindow($ch, 0) } } catch { }

# ---------------------------------------------------------------- DPI
[void][Native]::SetProcessDPIAware()
# Own taskbar identity so Windows does not group/show this window as powershell.exe.
try { [void][Native]::SetCurrentProcessExplicitAppUserModelID('SystemDashboard.Widget.v1') } catch { }
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }
$gTmp = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = [double]($gTmp.DpiX / 96.0)
$gTmp.Dispose()
if ($script:Scale -lt 1.0) { $script:Scale = 1.0 }
$script:Px1 = [Math]::Max(1.0, [Math]::Round($script:Scale))
$script:DpiScale = $script:Scale
function S([double]$n) { return [int][Math]::Round($n * $script:Scale) }

$script:ArrowDown = [string][char]0x2193
$script:ArrowUp   = [string][char]0x2191
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt([double]$v, [string]$f) { return $v.ToString($f, $script:Inv) }

# ---------------------------------------------------------------- settings
function New-DefaultSettings {
    return [ordered]@{
        Version            = 1
        Theme              = 'Midnight'
        CustomColor        = ''
        Glass              = $true      # used by step 6 (not active yet)
        GlassOpacity       = 0.85       # used by step 6 (not active yet)
        Expanded           = $false
        Corner             = 'TopRight'
        Screen             = ''
        AlertsEnabled      = $true
        CpuThreshold       = 90
        GpuThreshold       = 90
        MemThreshold       = 90
        SustainedSec       = 10
        CooldownSec        = 120
        RefreshMs          = 1000
        HistoryEnabled     = $true
        HistoryIntervalSec = 5
        AutoHideFullscreen = $true
        ClickThrough       = $false
        PauseWhenIdle      = $true
        IdleMinutes        = 5
        DiskFreePct        = 10         # alert when a drive has less than this % free (0 = off)
        UiScale            = 1.0
        HistoryKeepMonths  = 0          # 0 = keep everything
        HistoryCleanupMode = 'Compress'
        LogLevel           = 'Normal'
        SnapToCorner       = $false     # false = free placement
        PosX               = -99999     # last free position (-99999 = not set yet)
        PosY               = -99999
        SizeW              = 0          # expanded view: width the user chose (0 = default); in units of the UI scale
        SizeH              = 0          # expanded view: height
        SizeCW             = 0          # small view: width
        SizeCH             = 0          # small view: height
        NetView            = 'Devices'  # bottom panel of the Network tab: Devices, Nearby (Wi-Fi), Dns or Speed
        AlwaysOnTop        = $false     # false = behaves like a normal window: other programs can cover it
        AlertOutage        = $true      # internet / network outage alerts
        AlertData          = $true      # monthly data limit alerts
        AlertBattery       = $true      # low battery alerts
        BatteryLowPct      = 20
        DataLimitGB        = 0          # 0 = no limit
        DataResetDay       = 1          # day of the month the data counter starts again
        ShowTaskbarBadge   = $true      # small CPU/RAM widget on the taskbar, left of the tray area
        CloseToBackground  = $true      # x hides the dashboard and keeps it running (needs the taskbar widget)
        StartWithWindows   = $false     # record only; the real state is the Run registry value
        BadgeSide          = 'Left'     # Left = between Widgets and Start, Right = next to the tray area
        WifiEnabled        = $true      # Wi-Fi info, pings, devices, speed test, DNS Shield
        DeviceAlerts       = $true
        AutoSpeedTest      = $true
        SlowLimit          = 10
        SlowActive         = $false
        LastFastDate       = ''
        LastSpeed          = 0.0
        LastSpeedUtc       = ''
        DnsWasOn           = $false
        ExpandedTab        = 'System'
        AlertCpu           = $true      # alert types (all follow the master "Alerts enabled" switch)
        AlertGpu           = $true
        AlertRam           = $true
        AlertDisk          = $true
        AlertSpeed         = $true
        AlertDns           = $true
    }
}

$script:Themes = [ordered]@{
    Midnight = @(21, 28, 38)
    Ocean    = @(14, 34, 60)
    Forest   = @(16, 42, 34)
    Plum     = @(40, 26, 58)
    Crimson  = @(56, 22, 30)
    Graphite = @(30, 30, 32)
}

function Clamp-Num($v, $lo, $hi) { if ($v -lt $lo) { return $lo } elseif ($v -gt $hi) { return $hi } else { return $v } }

function Load-Settings {
    $s = New-DefaultSettings
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $s }
    try {
        $raw = [System.IO.File]::ReadAllText($script:SettingsPath, [System.Text.Encoding]::UTF8)
        $j = $raw | ConvertFrom-Json
        if ($null -eq $j) { return $s }
        foreach ($k in @($s.Keys)) {
            $prop = $j.PSObject.Properties[$k]
            if ($null -eq $prop -or $null -eq $prop.Value) { continue }
            try {
                $def = $s[$k]
                if ($def -is [bool]) { $s[$k] = [bool]$prop.Value }
                elseif ($def -is [int]) { $s[$k] = [int]$prop.Value }
                elseif ($def -is [double]) { $s[$k] = [double]$prop.Value }
                else { $s[$k] = [string]$prop.Value }
            } catch { }
        }
    } catch {
        Write-Log ('settings.json could not be read, using defaults: ' + $_.Exception.Message)
        return (New-DefaultSettings)
    }
    $s['RefreshMs']          = [int](Clamp-Num $s['RefreshMs'] 500 5000)
    $s['CpuThreshold']       = [int](Clamp-Num $s['CpuThreshold'] 10 100)
    $s['GpuThreshold']       = [int](Clamp-Num $s['GpuThreshold'] 10 100)
    $s['MemThreshold']       = [int](Clamp-Num $s['MemThreshold'] 10 100)
    $s['SustainedSec']       = [int](Clamp-Num $s['SustainedSec'] 1 600)
    $s['CooldownSec']        = [int](Clamp-Num $s['CooldownSec'] 10 3600)
    $s['HistoryIntervalSec'] = [int](Clamp-Num $s['HistoryIntervalSec'] 1 3600)
    $s['IdleMinutes']        = [int](Clamp-Num $s['IdleMinutes'] 1 120)
    $s['DiskFreePct']        = [int](Clamp-Num $s['DiskFreePct'] 0 50)
    $s['UiScale']            = [double](Clamp-Num $s['UiScale'] 0.7 1.6)
    $s['HistoryKeepMonths']  = [int](Clamp-Num $s['HistoryKeepMonths'] 0 120)
    if (@('Compress', 'Delete') -notcontains $s['HistoryCleanupMode']) { $s['HistoryCleanupMode'] = 'Compress' }
    if (@('Normal', 'Quiet') -notcontains $s['LogLevel']) { $s['LogLevel'] = 'Normal' }
    if (@('Left', 'Right') -notcontains $s['BadgeSide']) { $s['BadgeSide'] = 'Left' }
    if (@(5, 10, 25, 50) -notcontains [int]$s['SlowLimit']) { $s['SlowLimit'] = 10 }
    $s['SizeW']         = [double](Clamp-Num $s['SizeW'] 0 4000)
    $s['SizeH']         = [double](Clamp-Num $s['SizeH'] 0 4000)
    $s['SizeCW']        = [double](Clamp-Num $s['SizeCW'] 0 4000)
    $s['SizeCH']        = [double](Clamp-Num $s['SizeCH'] 0 4000)
    $s['DataLimitGB']   = [int](Clamp-Num $s['DataLimitGB'] 0 100000)
    $s['DataResetDay']  = [int](Clamp-Num $s['DataResetDay'] 1 28)
    $s['BatteryLowPct'] = [int](Clamp-Num $s['BatteryLowPct'] 5 50)
    if ($s['ExpandedTab'] -eq 'Wi-Fi') { $s['ExpandedTab'] = 'Network' }
    if ([string]$s['ExpandedTab'] -eq 'Scan') { $s['ExpandedTab'] = 'Network'; $s['NetView'] = 'Nearby' }
    if (@('System', 'Network') -notcontains $s['ExpandedTab']) { $s['ExpandedTab'] = 'System' }
    if (@('Devices', 'Nearby', 'Dns', 'Speed') -notcontains [string]$s['NetView']) { $s['NetView'] = 'Devices' }
    $s['GlassOpacity']       = [double](Clamp-Num $s['GlassOpacity'] 0.3 1.0)
    if ($s['Theme'] -ne 'Custom' -and -not $script:Themes.Contains($s['Theme'])) { $s['Theme'] = 'Midnight' }
    if (@('TopLeft', 'TopRight', 'BottomLeft', 'BottomRight') -notcontains $s['Corner']) { $s['Corner'] = 'TopRight' }
    return $s
}

function Save-Settings {
    try {
        $json = $script:Settings | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('Saving settings failed: ' + $_.Exception.Message) }
}

$script:Settings = Load-Settings
$script:Scale = $script:DpiScale * [double]$script:Settings['UiScale']
$script:Px1 = [Math]::Max(1.0, [Math]::Round($script:Scale))

# ---------------------------------------------------------------- theme / palette
function Mix-Rgb([int[]]$bg, [double]$amt) {
    $r = [int][Math]::Round($bg[0] + (255 - $bg[0]) * $amt)
    $g = [int][Math]::Round($bg[1] + (255 - $bg[1]) * $amt)
    $b = [int][Math]::Round($bg[2] + (255 - $bg[2]) * $amt)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Get-ThemeRgb {
    $name = [string]$script:Settings['Theme']
    if ($name -eq 'Custom') {
        try {
            $p = ([string]$script:Settings['CustomColor']).Split(',')
            $rgb = @([int]$p[0], [int]$p[1], [int]$p[2])
            $lum = 0.299 * $rgb[0] + 0.587 * $rgb[1] + 0.114 * $rgb[2]
            if ($lum -gt 110) {
                $f = 110.0 / $lum
                $rgb = @([int]($rgb[0] * $f), [int]($rgb[1] * $f), [int]($rgb[2] * $f))
            }
            return $rgb
        } catch { return $script:Themes['Midnight'] }
    }
    if ($script:Themes.Contains($name)) { return $script:Themes[$name] }
    return $script:Themes['Midnight']
}

$script:BrushCache = @{}
$script:PenCache = @{}
function Clear-GdiCache {
    foreach ($b in @($script:BrushCache.Values)) { try { $b.Dispose() } catch { } }
    foreach ($p in @($script:PenCache.Values)) { try { $p.Dispose() } catch { } }
    $script:BrushCache = @{}
    $script:PenCache = @{}
}

function Build-Palette {
    $rgb = Get-ThemeRgb
    $C = [System.Drawing.Color]
    $p = @{}
    $p.Bg        = $C::FromArgb($rgb[0], $rgb[1], $rgb[2])
    $p.Header    = Mix-Rgb $rgb 0.045
    $p.Border    = Mix-Rgb $rgb 0.16
    $p.Hover     = Mix-Rgb $rgb 0.13
    $p.Chip      = Mix-Rgb $rgb 0.07
    $p.Track     = Mix-Rgb $rgb 0.13
    $p.Panel     = Mix-Rgb $rgb 0.03
    $p.PanelLine = Mix-Rgb $rgb 0.11
    $p.Text      = $C::FromArgb(232, 238, 245)
    $p.Muted     = $C::FromArgb(138, 155, 176)
    $p.Teal      = $C::FromArgb(45, 212, 191)
    $p.Blue      = $C::FromArgb(96, 165, 250)
    $p.Amber     = $C::FromArgb(245, 176, 65)
    $p.Red       = $C::FromArgb(239, 83, 80)
    $p.Off       = $C::FromArgb(100, 116, 139)
    $p.CloseHover = $C::FromArgb(220, 70, 80)
    $script:Pal = $p
    Clear-GdiCache
}
Build-Palette

function Get-Brush([System.Drawing.Color]$c) {
    $k = $c.ToArgb()
    $b = $script:BrushCache[$k]
    if ($null -eq $b) { $b = New-Object System.Drawing.SolidBrush($c); $script:BrushCache[$k] = $b }
    return $b
}

function Get-Pen([System.Drawing.Color]$c, [double]$w, [bool]$round) {
    $k = '{0}|{1}|{2}' -f $c.ToArgb(), $w, $round
    $p = $script:PenCache[$k]
    if ($null -eq $p) {
        $p = New-Object System.Drawing.Pen($c, [single]$w)
        if ($round) {
            $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        }
        $script:PenCache[$k] = $p
    }
    return $p
}

function Alpha([System.Drawing.Color]$c, [int]$a) { return [System.Drawing.Color]::FromArgb($a, $c) }

function Get-LoadColor([double]$pct) {
    if ($pct -lt 60) { return $script:Pal.Teal }
    elseif ($pct -le 85) { return $script:Pal.Amber }
    else { return $script:Pal.Red }
}

# ---------------------------------------------------------------- fonts / text
$famSemi = 'Segoe UI Semibold'
$fam = 'Segoe UI'
try {
    $installed = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
    if ($installed -notcontains $famSemi) { $famSemi = $fam }
} catch { }
function New-Font([string]$family, [double]$size) {
    return New-Object System.Drawing.Font($family, [single]$size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
}
function Build-Fonts {
    $u = [double]$script:Settings['UiScale']
    $old = $script:Fonts
    $script:Fonts = @{
        Title      = New-Font $famSemi (10.5 * $u)
        PanelTitle = New-Font $famSemi (9 * $u)
        Tile       = New-Font $famSemi (14.5 * $u)
        Gauge      = New-Font $famSemi (17 * $u)
        Muted      = New-Font $fam (8 * $u)
        Chip       = New-Font $fam (8.5 * $u)
        Popup      = New-Font $famSemi (11 * $u)
        PopupBig   = New-Font $famSemi (26 * $u)
    }
    if ($null -ne $old) { foreach ($ft in @($old.Values)) { try { $ft.Dispose() } catch { } } }
}
Build-Fonts

function New-Sf([string]$h, [string]$v) {
    $sf = New-Object System.Drawing.StringFormat
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    if ($h -eq 'L') { $sf.Alignment = [System.Drawing.StringAlignment]::Near }
    elseif ($h -eq 'C') { $sf.Alignment = [System.Drawing.StringAlignment]::Center }
    else { $sf.Alignment = [System.Drawing.StringAlignment]::Far }
    if ($v -eq 'T') { $sf.LineAlignment = [System.Drawing.StringAlignment]::Near }
    else { $sf.LineAlignment = [System.Drawing.StringAlignment]::Center }
    return $sf
}
$script:Sf = @{}
foreach ($hh in 'L', 'C', 'R') { foreach ($vv in 'M', 'T') { $script:Sf[$hh + $vv] = New-Sf $hh $vv } }

function Draw-Text($g, [string]$text, $font, $brush, [double]$x, [double]$y, [double]$w, [double]$h, [string]$al) {
    if ([string]::IsNullOrEmpty($al)) { $al = 'LM' }
    $rf = New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$w, [single]$h)
    $g.DrawString($text, $font, $brush, $rf, $script:Sf[$al])
}

function Text-Width($g, [string]$text, $font) { return [int][Math]::Ceiling($g.MeasureString($text, $font).Width) }

function New-RoundPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Max(1.0, 2.0 * $r)
    if ($d -gt $w) { $d = $w }
    if ($d -gt $h) { $d = $h }
    $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Fill-Round($g, $brush, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-RoundPath $x $y $w $h $r
    $g.FillPath($brush, $p)
    $p.Dispose()
}

function Fill-Pill($g, $brush, [double]$x, [double]$y, [double]$w, [double]$h) {
    Fill-Round $g $brush $x $y $w $h ($h / 2.0)
}

# ---------------------------------------------------------------- formatting
function Format-Speed([double]$bps) {
    $kb = $bps / 1024.0
    if ($kb -lt 1) { return '0 KB/s' }
    if ($kb -lt 10) { return ((Fmt $kb '0.0') + ' KB/s') }
    if ($kb -lt 1000) { return ((Fmt $kb '0') + ' KB/s') }
    $mb = $kb / 1024.0
    if ($mb -lt 10) { return ((Fmt $mb '0.00') + ' MB/s') }
    if ($mb -lt 1000) { return ((Fmt $mb '0.0') + ' MB/s') }
    return ((Fmt ($mb / 1024.0) '0.00') + ' GB/s')
}

function Format-Size([double]$bytes) {
    $gb = $bytes / 1GB
    if ($gb -ge 1000) { return ((Fmt ($gb / 1024.0) '0.0') + ' TB') }
    if ($gb -ge 100) { return ((Fmt $gb '0') + ' GB') }
    if ($gb -ge 1) { return ((Fmt $gb '0.0') + ' GB') }
    return ((Fmt ($bytes / 1MB) '0') + ' MB')
}

function Format-Uptime($boot) {
    try {
        $ts = (Get-Date) - $boot
        if ($ts.TotalDays -ge 1) { return ('{0}d {1}h' -f [int]$ts.Days, [int]$ts.Hours) }
        if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.Hours, [int]$ts.Minutes) }
        return ('{0}m' -f [int]$ts.Minutes)
    } catch { return '-' }
}

function Csv-Field([string]$s) {
    if ($null -eq $s) { return '' }
    if ($s.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) { return ('"' + $s.Replace('"', '""') + '"') }
    return $s
}

# ---------------------------------------------------------------- background sampler (runs in an MTA runspace)
$script:SamplerSource = @'
param($Shared, $Events, $DataDir)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$ncpu = [Environment]::ProcessorCount
$errAt = @{}
function Note([string]$key, [string]$msg) {
    $now = [DateTime]::UtcNow
    if (-not $errAt.ContainsKey($key) -or ($now - $errAt[$key]).TotalSeconds -gt 60) {
        $errAt[$key] = $now
        [void]$Events.Enqueue('LOG|Sampler ' + $key + ': ' + $msg)
    }
}
function F1([double]$v) { return $v.ToString('0.0', $inv) }

$st = @{
    Cpu = 0.0; Cores = [double[]]@(); Gpu = -1.0; GpuMem = -1.0; GpuTop = ''
    MemPct = 0.0; MemUsed = 0.0; MemTotal = 0.0
    Down = 0.0; Up = 0.0; NetName = ''; NetId = ''; Nics = @(); NetPrev = @{}
    DiskPct = 0.0; DiskRead = 0.0; DiskWrite = 0.0
    Drives = @(); TopCpu = @(); TopRam = @(); ProcPrev = @{}; ProcAt = [DateTime]::UtcNow
    PidNames = @{}; LastHist = [DateTime]::MinValue; LastFlush = [DateTime]::MinValue; HistFail = $false
}

# ---- counters
$cpuTotal = $null; $coreCtr = @()
try {
    $cpuTotal = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total', $true)
    [void]$cpuTotal.NextValue()
} catch { Note 'cpu-init' $_.Exception.Message }
try {
    $names = @((New-Object System.Diagnostics.PerformanceCounterCategory('Processor')).GetInstanceNames() |
        Where-Object { $_ -ne '_Total' } |
        Sort-Object { $p = $_ -split ','; ([int]$p[0]) * 1000 + ([int]$p[$p.Length - 1]) })
    $list = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $c = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', $n, $true)
        [void]$c.NextValue()
        [void]$list.Add($c)
    }
    $coreCtr = $list.ToArray()
} catch { Note 'cores-init' $_.Exception.Message }

$ci = $null
try { Add-Type -AssemblyName Microsoft.VisualBasic; $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo } catch { Note 'mem-init' $_.Exception.Message }

$dIdle = $null; $dRead = $null; $dWrite = $null
try {
    $dIdle  = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', '% Idle Time', '_Total', $true)
    $dRead  = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', 'Disk Read Bytes/sec', '_Total', $true)
    $dWrite = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', 'Disk Write Bytes/sec', '_Total', $true)
    [void]$dIdle.NextValue(); [void]$dRead.NextValue(); [void]$dWrite.NextValue()
} catch { Note 'disk-init' $_.Exception.Message; $dIdle = $null }

$gpu = $null
try { $gpu = New-Object GpuReader } catch { Note 'gpu-init' $_.Exception.Message }

$boot = $null
try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime }
catch { $boot = (Get-Date).AddMilliseconds(-[Environment]::TickCount) }

$histCsv = $null
try { $histCsv = New-Object CsvAppender('Timestamp,CpuPercent,GpuPercent,MemPercent,MemUsedGB,NetDownKBps,NetUpKBps,DiskActivityPercent,DiskReadKBps,DiskWriteKBps') }
catch { Note 'csv-init' $_.Exception.Message }

# ---- helpers
function Refresh-Nics {
    $good = New-Object System.Collections.ArrayList
    $all = New-Object System.Collections.ArrayList
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
            if ($n.OperationalStatus.ToString() -ne 'Up') { continue }
            $t = $n.NetworkInterfaceType.ToString()
            if ($t -eq 'Loopback' -or $t -eq 'Tunnel') { continue }
            [void]$all.Add($n)
            foreach ($gw in $n.GetIPProperties().GatewayAddresses) {
                if ($gw.Address.AddressFamily.ToString() -eq 'InterNetwork' -and $gw.Address.ToString() -ne '0.0.0.0') {
                    [void]$good.Add($n)
                    break
                }
            }
        } catch { }
    }
    if ($good.Count -gt 0) { $st.Nics = $good.ToArray() } else { $st.Nics = $all.ToArray() }
}

function Read-Net([double]$dt) {
    $best = $null; $bestRate = -1.0; $bestDown = 0.0; $bestUp = 0.0
    foreach ($n in $st.Nics) {
        try {
            $s = $n.GetIPv4Statistics()
            $rx = [double]$s.BytesReceived; $tx = [double]$s.BytesSent
            $id = $n.Id
            $p = $st.NetPrev[$id]
            $down = 0.0; $up = 0.0
            if ($null -ne $p -and $dt -gt 0) {
                $down = [Math]::Max(0.0, ($rx - $p[0]) / $dt)
                $up = [Math]::Max(0.0, ($tx - $p[1]) / $dt)
            }
            $st.NetPrev[$id] = @($rx, $tx)
            $rate = $down + $up
            $take = $false
            if ($null -eq $best -or $rate -gt $bestRate) { $take = $true }
            elseif ($rate -eq $bestRate -and $id -eq $st.NetId) { $take = $true }
            if ($take) { $best = $n; $bestRate = $rate; $bestDown = $down; $bestUp = $up }
        } catch { }
    }
    if ($null -ne $best) {
        $st.Down = $bestDown; $st.Up = $bestUp; $st.NetId = $best.Id; $st.NetName = $best.Name
    } else {
        $st.Down = 0.0; $st.Up = 0.0; $st.NetName = ''
    }
}

function Read-Drives {
    $out = New-Object System.Collections.ArrayList
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType.ToString() -ne 'Fixed') { continue }
            if (-not $d.IsReady) { continue }
            [void]$out.Add([pscustomobject]@{ Name = $d.Name.TrimEnd('\'); Total = [double]$d.TotalSize; Free = [double]$d.AvailableFreeSpace })
        } catch { }
    }
    $st.Drives = $out.ToArray()
}

function Read-Procs {
    $now = [DateTime]::UtcNow
    $dt = ($now - $st.ProcAt).TotalSeconds
    $st.ProcAt = $now
    $cpuByName = @{}; $ramByName = @{}; $newPrev = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $id = $p.Id
            if ($id -eq 0) { continue }
            $name = $p.ProcessName
            $ramByName[$name] = [double]$ramByName[$name] + [double]$p.WorkingSet64
            $c = $null
            try { $c = $p.TotalProcessorTime.TotalSeconds } catch { $c = $null }
            if ($null -ne $c) {
                $newPrev[$id] = $c
                if ($st.ProcPrev.ContainsKey($id) -and $dt -gt 0) {
                    $d = $c - $st.ProcPrev[$id]
                    if ($d -gt 0) { $cpuByName[$name] = [double]$cpuByName[$name] + $d }
                }
            }
        } catch { }
        finally { try { $p.Dispose() } catch { } }
    }
    $st.ProcPrev = $newPrev
    $cl = New-Object System.Collections.ArrayList
    if ($dt -gt 0) {
        foreach ($k in $cpuByName.Keys) {
            $pct = [Math]::Min(100.0, $cpuByName[$k] / $dt / $ncpu * 100.0)
            [void]$cl.Add([pscustomobject]@{ Name = $k; Value = $pct })
        }
    }
    $rl = New-Object System.Collections.ArrayList
    foreach ($k in $ramByName.Keys) { [void]$rl.Add([pscustomobject]@{ Name = $k; Value = [double]$ramByName[$k] }) }
    $st.TopCpu = @($cl | Sort-Object Value -Descending | Select-Object -First 6)
    $st.TopRam = @($rl | Sort-Object Value -Descending | Select-Object -First 6)
}

# ---- history cleanup (older months are compressed to .gz or deleted)
function Run-Cleanup {
    $keep = [int]$Shared.Cfg.HistoryKeepMonths
    if ($keep -le 0) { return }
    $mode = [string]$Shared.Cfg.HistoryCleanupMode
    $cut = (Get-Date -Day 1).Date.AddMonths(-$keep)
    $done = 0
    foreach ($fi in (@(Get-ChildItem -LiteralPath $DataDir -Filter 'history-*' -File) + @(Get-ChildItem -LiteralPath $DataDir -Filter 'network-*' -File))) {
        if ($fi.Name -notmatch '^(history|network)-(\d{4})-(\d{2})\.csv(\.gz)?$') { continue }
        $isGz = ($Matches[4] -eq '.gz')
        $d = New-Object DateTime -ArgumentList ([int]$Matches[2]), ([int]$Matches[3]), 1
        if ($d -ge $cut) { continue }
        try {
            if ($mode -eq 'Delete') {
                Remove-Item -LiteralPath $fi.FullName -Force
                $done++
            } elseif (-not $isGz) {
                $src = [System.IO.File]::OpenRead($fi.FullName)
                $dst = [System.IO.File]::Create($fi.FullName + '.gz')
                $gz = New-Object System.IO.Compression.GZipStream($dst, [System.IO.Compression.CompressionMode]::Compress)
                try { $src.CopyTo($gz) } finally { $gz.Dispose(); $dst.Dispose(); $src.Dispose() }
                Remove-Item -LiteralPath $fi.FullName -Force
                $done++
            }
        } catch { Note 'cleanup' $_.Exception.Message }
    }
    [void]$Events.Enqueue('LOG|History cleanup (' + $mode + ', older than ' + $keep + ' months): ' + $done + ' file(s)')
}

# ---- main loop
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ring = New-Object System.Collections.ArrayList
$lastTick = $sw.Elapsed.TotalSeconds
$nextProcs = 0.0; $nextDrives = 0.0; $nextNics = 0.0; $nextCleanup = 30.0
$seq = 0
[void]$Events.Enqueue('LOG|Sampler started (cores=' + $coreCtr.Count + ', gpu=' + $(if ($gpu -and $gpu.Available) { 'counters' } else { 'n/a' }) + ')')

try {
    while (-not $Shared.Stop) {
        $t0 = $sw.Elapsed.TotalSeconds
        $wasIdle = [bool]$Shared.Cfg.Idle
        try {
            $dt = $t0 - $lastTick; $lastTick = $t0
            if ($dt -le 0) { $dt = 1.0 }
            $refreshMs = [int]$Shared.Cfg.RefreshMs
            if ($refreshMs -lt 250) { $refreshMs = 1000 }
            if ($wasIdle) { $refreshMs = [Math]::Max($refreshMs, 5000) }

            try { if ($null -ne $cpuTotal) { $st.Cpu = [Math]::Min(100.0, [Math]::Max(0.0, [double]$cpuTotal.NextValue())) } }
            catch { Note 'cpu' $_.Exception.Message }

            try {
                if ($coreCtr.Count -gt 0) {
                    $arr = New-Object 'double[]' $coreCtr.Count
                    for ($i = 0; $i -lt $coreCtr.Count; $i++) {
                        $arr[$i] = [Math]::Min(100.0, [Math]::Max(0.0, [double]$coreCtr[$i].NextValue()))
                    }
                    $st.Cores = $arr
                }
            } catch { Note 'cores' $_.Exception.Message }

            try {
                $total = 0.0; $avail = 0.0
                if ($null -ne $ci) { $total = [double]$ci.TotalPhysicalMemory; $avail = [double]$ci.AvailablePhysicalMemory }
                else {
                    $os = Get-CimInstance -ClassName Win32_OperatingSystem
                    $total = [double]$os.TotalVisibleMemorySize * 1024.0; $avail = [double]$os.FreePhysicalMemory * 1024.0
                }
                if ($total -gt 0) {
                    $st.MemTotal = $total; $st.MemUsed = $total - $avail
                    $st.MemPct = [Math]::Min(100.0, [Math]::Max(0.0, ($total - $avail) / $total * 100.0))
                }
            } catch { Note 'mem' $_.Exception.Message }

            try {
                if ($t0 -ge $nextNics) { Refresh-Nics; $nextNics = $t0 + 5.0 }
                Read-Net $dt
            } catch { Note 'net' $_.Exception.Message }

            try {
                if ($null -ne $dIdle) {
                    $st.DiskPct = [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - [double]$dIdle.NextValue()))
                    $st.DiskRead = [Math]::Max(0.0, [double]$dRead.NextValue())
                    $st.DiskWrite = [Math]::Max(0.0, [double]$dWrite.NextValue())
                }
            } catch { Note 'disk' $_.Exception.Message }

            try {
                if ($null -ne $gpu) {
                    $gpu.Sample()
                    $st.Gpu = [double]$gpu.Usage
                    $st.GpuMem = [double]$gpu.VramUsedBytes
                    $tp = [int]$gpu.TopPid
                    if ($tp -gt 0 -and $gpu.TopPidValue -gt 1.0) {
                        $nm = $st.PidNames[$tp]
                        if ($null -eq $nm) {
                            try { $nm = (Get-Process -Id $tp -ErrorAction Stop).ProcessName } catch { $nm = 'pid ' + $tp }
                            if ($st.PidNames.Count -gt 500) { $st.PidNames = @{} }
                            $st.PidNames[$tp] = $nm
                        }
                        $st.GpuTop = [string]$nm
                    } else { $st.GpuTop = '' }
                }
            } catch { Note 'gpu' $_.Exception.Message; $st.Gpu = -1.0 }

            if ($t0 -ge $nextProcs) {
                try { Read-Procs } catch { Note 'procs' $_.Exception.Message }
                $nextProcs = $t0 + 4.0
            }
            if ($t0 -ge $nextDrives) {
                try { Read-Drives } catch { Note 'drives' $_.Exception.Message }
                $nextDrives = $t0 + 5.0
            }

            $seq++
            $Shared.Snap = [pscustomobject]@{
                Seq = $seq; Cpu = $st.Cpu; Cores = $st.Cores
                Gpu = $st.Gpu; GpuMem = $st.GpuMem; GpuTop = $st.GpuTop
                MemPct = $st.MemPct; MemUsed = $st.MemUsed; MemTotal = $st.MemTotal
                Down = $st.Down; Up = $st.Up; NetName = $st.NetName
                DiskPct = $st.DiskPct; DiskRead = $st.DiskRead; DiskWrite = $st.DiskWrite
                Drives = $st.Drives; TopCpu = $st.TopCpu; TopRam = $st.TopRam; Boot = $boot
            }
            [void]$ring.Add([pscustomobject]@{ Cpu = $st.Cpu; Gpu = $st.Gpu; Mem = $st.MemPct; Down = $st.Down; Up = $st.Up })
            while ($ring.Count -gt 120) { $ring.RemoveAt(0) }
            $Shared.History = $ring.ToArray()
            if ([bool]$Shared.Cfg.CleanupRequest -or $t0 -ge $nextCleanup) {
                $Shared.Cfg.CleanupRequest = $false
                $nextCleanup = $t0 + 86400.0
                try { Run-Cleanup } catch { Note 'cleanup' $_.Exception.Message }
            }

            # ---- CSV history (written here, never on the UI thread)
            try {
                $cfg = $Shared.Cfg
                $nowD = Get-Date
                $file = Join-Path $DataDir ('history-' + $nowD.ToString('yyyy-MM', $inv) + '.csv')
                if ($cfg.HistoryEnabled -and $null -ne $histCsv) {
                    if (($nowD - $st.LastHist).TotalSeconds -ge [double]$cfg.HistoryIntervalSec) {
                        $st.LastHist = $nowD
                        $gpuText = ''
                        if ($st.Gpu -ge 0) { $gpuText = F1 $st.Gpu }
                        $row = (@(
                            $nowD.ToString('yyyy-MM-dd HH:mm:ss', $inv), (F1 $st.Cpu), $gpuText, (F1 $st.MemPct),
                            (F1 ($st.MemUsed / 1GB)), (F1 ($st.Down / 1024.0)), (F1 ($st.Up / 1024.0)),
                            (F1 $st.DiskPct), (F1 ($st.DiskRead / 1024.0)), (F1 ($st.DiskWrite / 1024.0))
                        ) -join ',')
                        $ok = $histCsv.Write($file, $row)
                        $st.LastFlush = $nowD
                        if (-not $ok -and -not $st.HistFail) {
                            $st.HistFail = $true
                            [void]$Events.Enqueue('LOG|History file not writable, buffering rows in memory: ' + $histCsv.LastError)
                        } elseif ($ok -and $st.HistFail) {
                            $st.HistFail = $false
                            [void]$Events.Enqueue('LOG|History file writable again, buffered rows written')
                        }
                    } elseif ($histCsv.PendingCount -gt 0 -and ($nowD - $st.LastFlush).TotalSeconds -ge 15) {
                        $st.LastFlush = $nowD
                        $ok = $histCsv.Flush($file)
                        if ($ok -and $st.HistFail) {
                            $st.HistFail = $false
                            [void]$Events.Enqueue('LOG|History file writable again, buffered rows written')
                        }
                    }
                }
            } catch { Note 'history' $_.Exception.Message }
        } catch {
            Note 'loop' $_.Exception.Message
            Start-Sleep -Milliseconds 1000
        }

        $elapsed = $sw.Elapsed.TotalSeconds - $t0
        $sleepMs = [int](($refreshMs / 1000.0 - $elapsed) * 1000.0)
        if ($sleepMs -lt 10) { $sleepMs = 10 }
        while ($sleepMs -gt 0 -and -not $Shared.Stop -and ($wasIdle -eq [bool]$Shared.Cfg.Idle)) {
            $chunk = [Math]::Min(100, $sleepMs)
            Start-Sleep -Milliseconds $chunk
            $sleepMs -= $chunk
        }
    }
} finally {
    try {
        $f2 = Join-Path $DataDir ('history-' + (Get-Date).ToString('yyyy-MM', $inv) + '.csv')
        if ($null -ne $histCsv) { [void]$histCsv.Flush($f2) }
    } catch { }
    foreach ($c in @($cpuTotal, $dIdle, $dRead, $dWrite) + @($coreCtr)) { try { if ($null -ne $c) { $c.Dispose() } } catch { } }
    [void]$Events.Enqueue('LOG|Sampler stopped')
}
'@

# ---------------------------------------------------------------- shared state / start sampler
$script:Events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Shared = [hashtable]::Synchronized(@{})
$script:Shared['Stop'] = $false
$script:Shared['Snap'] = $null
$script:Shared['History'] = @()
$script:Shared['Taskbar'] = $null
$script:Shared['Cfg'] = [hashtable]::Synchronized(@{ RefreshMs = 1000; HistoryEnabled = $true; HistoryIntervalSec = 5; Idle = $false; HistoryKeepMonths = 0; HistoryCleanupMode = 'Compress'; CleanupRequest = $false })

function Sync-Cfg {
    $c = $script:Shared['Cfg']
    $c['RefreshMs'] = [int]$script:Settings['RefreshMs']
    $c['HistoryEnabled'] = [bool]$script:Settings['HistoryEnabled']
    $c['HistoryIntervalSec'] = [int]$script:Settings['HistoryIntervalSec']
    $c['HistoryKeepMonths'] = [int]$script:Settings['HistoryKeepMonths']
    $c['HistoryCleanupMode'] = [string]$script:Settings['HistoryCleanupMode']
    if ($null -ne $script:Wifi) {
        $script:Wifi['HistEnabled'] = [bool]$script:Settings['HistoryEnabled']
        $script:Wifi['HistInterval'] = [Math]::Max(5, [int]$script:Settings['HistoryIntervalSec'])
        $script:Wifi['DataResetDay'] = [int]$script:Settings['DataResetDay']
    }
}
Sync-Cfg

function Start-Sampler {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:SamplerSource).AddArgument($script:Shared).AddArgument($script:Events).AddArgument($script:DataDir)
    $script:SamplerRs = $rs
    $script:SamplerPs = $ps
    $script:SamplerAsync = $ps.BeginInvoke()
}

function Stop-Sampler {
    try {
        $script:Shared['Stop'] = $true
        if ($null -ne $script:SamplerAsync) {
            [void]$script:SamplerAsync.AsyncWaitHandle.WaitOne(3000)
            if (-not $script:SamplerAsync.IsCompleted) { try { $script:SamplerPs.Stop() } catch { } }
        }
        foreach ($er in @($script:SamplerPs.Streams.Error)) { Write-Log ('Sampler stream error: ' + [string]$er) }
        $script:SamplerPs.Dispose()
        $script:SamplerRs.Close()
        $script:SamplerRs.Dispose()
    } catch { Write-Log ('Stop-Sampler: ' + $_.Exception.Message) }
}

function Drain-Events {
    $msg = $null
    $n = 0
    while ($n -lt 50 -and $script:Events.TryDequeue([ref]$msg)) {
        $n++
        if ($msg.StartsWith('LOG|')) { Write-Log $msg.Substring(4) }
    }
    try {
        if ($null -ne $script:SamplerPs -and $script:SamplerPs.Streams.Error.Count -gt 0) {
            $k = 0
            foreach ($er in @($script:SamplerPs.Streams.Error)) { if ($k -lt 3) { Write-Log ('Sampler stream error: ' + [string]$er) }; $k++ }
            $script:SamplerPs.Streams.Error.Clear()
        }
        if ($null -ne $script:SamplerAsync -and $script:SamplerAsync.IsCompleted -and -not $script:Shared['Stop']) {
            Log-Once 'Sampler' 'the sampler runspace ended unexpectedly; values will not update'
        }
    } catch { }
}

# ---------------------------------------------------------------- UI state
$script:StartTime = Get-Date
function Update-Metrics {
    $script:Px1 = [Math]::Max(1.0, [Math]::Round($script:Scale))
    $script:M = (S 12)           # distance from the screen edges
    $script:Pad = (S 18)         # distance between the window border and everything inside
    $script:CompactW = (S 380); $script:CompactH = (S 206)
    $script:ExpW = (S 380);     $script:ExpH = (S 900)
    $script:HeaderH = (S 40)
}
Update-Metrics

function New-EmptySnap {
    return [pscustomobject]@{
        Seq = 0; Cpu = 0.0; Cores = [double[]]@(); Gpu = -1.0; GpuMem = -1.0; GpuTop = ''
        MemPct = 0.0; MemUsed = 0.0; MemTotal = 0.0; Down = 0.0; Up = 0.0; NetName = ''
        DiskPct = 0.0; DiskRead = 0.0; DiskWrite = 0.0
        Drives = @(); TopCpu = @(); TopRam = @(); Boot = (Get-Date)
    }
}
$script:Snap = New-EmptySnap
$script:Gr = @{ Cpu = [double[]]@(); Gpu = [double[]]@(); Mem = [double[]]@(); Down = [double[]]@(); Up = [double[]]@() }
$script:Hit = @{}
$script:Hover = $null
$script:Down = $null
$script:Dragging = $false
$script:Anim = @{ Active = $false; Step = 0; From = $null; To = $null }
$script:Cleaned = $false
$script:PendingResnap = $false
$script:Menu = $null
$script:Popup = $null
$script:PopData = $null
$script:PopHit = @{}
$script:PopHover = $null
$script:PopRepaints = 0
$script:LastPopup = [DateTime]::MinValue
$script:AlertQueue = New-Object System.Collections.Queue
$script:AlertState = @{
    CPU = @{ Since = $null; Last = [DateTime]::MinValue }
    GPU = @{ Since = $null; Last = [DateTime]::MinValue }
    RAM = @{ Since = $null; Last = [DateTime]::MinValue }
}
$script:AlertCsv = New-Object CsvAppender('Timestamp,Metric,Value,Threshold,TopProcess')
$script:AlertFailing = $false
$script:TickCount = 0

# ---------------------------------------------------------------- main window
$script:Form = New-Object BufferedForm
$f = $script:Form
$f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$f.ShowInTaskbar = $true
$f.TopMost = [bool]$script:Settings['AlwaysOnTop']
$f.Text = 'System Dashboard'
$f.BackColor = $script:Pal.Bg
$f.Size = New-Object System.Drawing.Size($script:CompactW, $script:CompactH)

# Taskbar icon: icon.ico or icon.png next to the script if present, otherwise a drawn teal ring.
function Set-AppIcon {
    $fm = $script:Form
    $file = $null
    foreach ($n in 'icon.ico', 'icon.png') {
        $c = Join-Path $PSScriptRoot $n
        if (Test-Path -LiteralPath $c) { $file = $c; break }
    }
    try {
        if ($file -and $file.EndsWith('.ico')) {
            $fm.Icon = New-Object System.Drawing.Icon($file)
            Write-Log ('Icon loaded from ' + $file)
            return
        }
        $bmp = New-Object System.Drawing.Bitmap(64, 64)
        $gi = [System.Drawing.Graphics]::FromImage($bmp)
        $gi.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $gi.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        if ($file) {
            $src = [System.Drawing.Image]::FromFile($file)
            $gi.DrawImage($src, 0, 0, 64, 64)
            $src.Dispose()
            Write-Log ('Icon loaded from ' + $file)
        } else {
            $gi.FillEllipse((New-Object System.Drawing.SolidBrush($script:Pal.Bg)), 2, 2, 60, 60)
            $ipen = New-Object System.Drawing.Pen($script:Pal.Teal, 8)
            $ipen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $ipen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $gi.DrawArc($ipen, 12, 12, 40, 40, 135, 220)
            $ipen.Dispose()
        }
        $gi.Dispose()
        $script:IconHandle = $bmp.GetHicon()
        $fm.Icon = [System.Drawing.Icon]::FromHandle($script:IconHandle)
        $bmp.Dispose()
    } catch { Write-Log ('Icon: ' + $_.Exception.Message) }
}
Set-AppIcon

# ---------------------------------------------------------------- geometry helpers
function Get-ScreenByName([string]$name) {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { if ($s.DeviceName -eq $name) { return $s } }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

# smallest sizes the window may be dragged to (the pages scroll instead of overflowing)
function Get-MinSize { return (New-Object System.Drawing.Size([int](S 360), [int](S 400))) }

function Get-WinRadius { return (S 16) }     # corner radius of the window

function Get-TargetSize($screen) {
    $wa = $screen.WorkingArea
    $maxW = $wa.Width - 2 * $script:M
    if ($script:Settings['Expanded']) {
        $uw = [double]$script:Settings['SizeW']; if ($uw -le 0) { $uw = 380.0 }
        $uh = [double]$script:Settings['SizeH']; if ($uh -le 0) { $uh = 900.0 }
        $min = Get-MinSize
        $w = [Math]::Max($min.Width, [Math]::Min([int](S $uw), $maxW))
        $h = [Math]::Max($min.Height, [Math]::Min([int](S $uh), $wa.Height - 2 * $script:M))
        return (New-Object System.Drawing.Size($w, $h))
    }
    $uw = [double]$script:Settings['SizeCW']; if ($uw -le 0) { $uw = 380.0 }
    $w = [Math]::Max([int](S 360), [Math]::Min([int](S $uw), $maxW))
    $h = $script:CompactH
    $uh = [double]$script:Settings['SizeCH']
    if ($uh -gt 0) { $h = [Math]::Max($script:CompactH, [Math]::Min([int](S $uh), [Math]::Min($script:CompactH + [int](S 140), $wa.Height - 2 * $script:M))) }
    return (New-Object System.Drawing.Size($w, $h))
}

function Get-CornerPoint($screen, [string]$corner, $size) {
    $wa = $screen.WorkingArea
    $m = $script:M
    if ($corner -like '*Left') { $x = $wa.Left + $m } else { $x = $wa.Right - $size.Width - $m }
    if ($corner -like 'Top*') { $y = $wa.Top + $m } else { $y = $wa.Bottom - $size.Height - $m }
    return (New-Object System.Drawing.Point($x, $y))
}

function Test-HasPos { return ([int]$script:Settings['PosX'] -gt -90000) }

# Screen the widget belongs on: the one holding its free position, or the remembered corner screen.
function Get-LayoutScreen {
    if (-not $script:Settings['SnapToCorner'] -and (Test-HasPos)) {
        return [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(([int]$script:Settings['PosX'] + 40), ([int]$script:Settings['PosY'] + 20))))
    }
    return (Get-ScreenByName ([string]$script:Settings['Screen']))
}

# Where the window goes: the saved free position (kept inside the working area), or the corner when snapping.
function Get-LayoutPoint($screen, $size) {
    if ($script:Settings['SnapToCorner'] -or -not (Test-HasPos)) { return (Get-CornerPoint $screen ([string]$script:Settings['Corner']) $size) }
    $wa = $screen.WorkingArea
    $x = [Math]::Max($wa.Left, [Math]::Min([int]$script:Settings['PosX'], $wa.Right - $size.Width))
    $y = [Math]::Max($wa.Top, [Math]::Min([int]$script:Settings['PosY'], $wa.Bottom - $size.Height))
    return (New-Object System.Drawing.Point($x, $y))
}

function Update-Region {
    $fm = $script:Form
    if ($fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
    Set-RegionSize $fm.Width $fm.Height
}

function Set-RegionRect([int]$x, [int]$y, [int]$w, [int]$h) {
    $fm = $script:Form
    $path = New-RoundPath $x $y $w $h (Get-WinRadius)
    $old = $fm.Region
    $fm.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
    if ($null -ne $old) { $old.Dispose() }
}

function Set-RegionSize([int]$w, [int]$h) {
    $fm = $script:Form
    $path = New-RoundPath 0 0 $w $h (Get-WinRadius)
    $old = $fm.Region
    $fm.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
    if ($null -ne $old) { $old.Dispose() }
}

function Update-ResizeMode {
    $fm = $script:Form
    try {
        $fm.Grip = [int](S 6)
        if ($script:ResizeAnim.Active) { $fm.GripMode = 0 }
        else { $fm.GripMode = 2 }
    } catch { }
}

function Apply-Layout {
    $fm = $script:Form
    $screen = Get-LayoutScreen
    $size = Get-TargetSize $screen
    $pt = Get-LayoutPoint $screen $size
    $rect = New-Object System.Drawing.Rectangle($pt, $size)
    $script:Resizing = $true
    $redrawOff = $false
    try {
        Update-Glass $rect $true                 # glass for the NEW area first (widget is excluded from capture)
        if ($fm.IsHandleCreated) { [void][Native]::SendMessage($fm.Handle, 0x000B, [IntPtr]0, [IntPtr]::Zero); $redrawOff = $true }
        Set-RegionSize $rect.Width $rect.Height  # clip to the new shape before the window grows
        $fm.Bounds = $rect
    } finally {
        if ($redrawOff) { [void][Native]::SendMessage($fm.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero) }
        $script:Resizing = $false
    }
    Update-ResizeMode
    $fm.Invalidate($true)
    $fm.Update()
    Write-Log ('Layout expanded=' + $script:Settings['Expanded'] + ' corner=' + $script:Settings['Corner'] + ' screen=' + $screen.DeviceName + ' rect=' + $rect.X + ',' + $rect.Y + ',' + $rect.Width + ',' + $rect.Height)
}

function Get-WidgetRect {
    $fm = $script:Form
    if ($fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return $fm.RestoreBounds }
    return $fm.Bounds
}

function Get-ScreenSig {
    return (([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName + ':' + $_.WorkingArea.ToString() }) -join ';')
}
$script:ScreenSig = Get-ScreenSig

# ---------------------------------------------------------------- snap animation
function Start-SnapAnim($target) {
    $fm = $script:Form
    $script:Anim = @{ Active = $true; Step = 0; From = $fm.Location; To = $target }
    $script:TimerAnim.Interval = 15
    $script:TimerAnim.Start()
}

function Step-SnapAnim {
    $a = $script:Anim
    if (-not $a.Active) { $script:TimerAnim.Stop(); return }
    $a.Step = $a.Step + 1
    $t = [Math]::Min(1.0, $a.Step / 12.0)
    $e = 1.0 - [Math]::Pow(1.0 - $t, 3)
    $x = [int][Math]::Round($a.From.X + ($a.To.X - $a.From.X) * $e)
    $y = [int][Math]::Round($a.From.Y + ($a.To.Y - $a.From.Y) * $e)
    $script:Form.Location = New-Object System.Drawing.Point($x, $y)
    if ($a.Step -ge 12) {
        $script:Form.Location = $a.To
        $a.Active = $false
        $script:TimerAnim.Stop()
        Update-Glass
        $script:Form.Invalidate()
    }
}

function Snap-ToNearestCorner {
    $fm = $script:Form
    $center = New-Object System.Drawing.Point(($fm.Left + [int]($fm.Width / 2)), ($fm.Top + [int]($fm.Height / 2)))
    $screen = [System.Windows.Forms.Screen]::FromPoint($center)
    $wa = $screen.WorkingArea
    $right = ($center.X -gt ($wa.Left + $wa.Width / 2))
    $bottom = ($center.Y -gt ($wa.Top + $wa.Height / 2))
    $corner = $(if ($bottom) { 'Bottom' } else { 'Top' }) + $(if ($right) { 'Right' } else { 'Left' })
    $script:Settings['Corner'] = $corner
    $script:Settings['Screen'] = [string]$screen.DeviceName
    Save-Settings
    Write-Log ('Snapped to ' + $corner + ' on ' + $screen.DeviceName)
    $size = Get-TargetSize $screen
    if ($fm.Width -ne $size.Width -or $fm.Height -ne $size.Height) { $fm.Size = $size }
    Start-SnapAnim (Get-CornerPoint $screen $corner $size)
}

function Finish-Drag {
    if ($script:Settings['SnapToCorner']) { Snap-ToNearestCorner; return }
    $fm = $script:Form
    $screen = [System.Windows.Forms.Screen]::FromRectangle($fm.Bounds)
    $wa = $screen.WorkingArea
    $x = [Math]::Max($wa.Left, [Math]::Min($fm.Left, $wa.Right - $fm.Width))
    $y = [Math]::Max($wa.Top, [Math]::Min($fm.Top, $wa.Bottom - $fm.Height))
    if ($x -ne $fm.Left -or $y -ne $fm.Top) { $fm.Location = New-Object System.Drawing.Point($x, $y) }
    $script:Settings['PosX'] = $x
    $script:Settings['PosY'] = $y
    $script:Settings['Screen'] = [string]$screen.DeviceName
    Save-Settings
    Update-Glass
    Write-Log ('Placed at ' + $x + ',' + $y + ' on ' + $screen.DeviceName)
}

function Restore-Widget {
    $fm = $script:Form
    $script:Backgrounded = $false
    Disable-ClickThroughIfOn
    if ($script:AutoHidden) { Set-AutoHidden $false }
    if ($fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $fm.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
    $fm.Show()
    $fm.TopMost = [bool]$script:Settings['AlwaysOnTop']
    $fm.Activate()
    [void][Native]::SetForegroundWindow($fm.Handle)
    Write-Log 'Widget restored'
}

# ---------------------------------------------------------------- hit testing / header layout
function Hit-Test($pt) {
    foreach ($k in @($script:Hit.Keys)) { if ($script:Hit[$k].Contains($pt)) { return $k } }
    return $null
}

function Layout-Header([int]$w) {
    $bs = (S 28); $gap = (S 4)
    $y = [int][Math]::Floor(($script:HeaderH - $bs) / 2)
    $x = $w - ($script:Pad - (S 7)) - $bs
    foreach ($name in 'close', 'min', 'expand', 'settings') {
        $script:Hit[$name] = New-Object System.Drawing.Rectangle($x, $y, $bs, $bs)
        $x -= ($bs + $gap)
    }
}

# ---------------------------------------------------------------- actions
function Open-DataFolder {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:DataDir + '"') } catch { Write-Log ('Open folder: ' + $_.Exception.Message) }
}

function Open-AlertsLog {
    try {
        if (Test-Path -LiteralPath $script:AlertsPath) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:AlertsPath + '"') }
        else { Open-DataFolder }
    } catch { Write-Log ('Open alerts log: ' + $_.Exception.Message) }
}

function Set-Setting([string]$key, $value) {
    $script:Settings[$key] = $value
    Write-Log ('Setting ' + $key + ' = ' + $value)
    Save-Settings
    Sync-Cfg
    if ($key -eq 'AlertsEnabled' -and -not $value) { Reset-Alerts; Hide-Popup }
    if ($key -eq 'ClickThrough') { Apply-ClickThrough }
    if (@('AlertCpu', 'AlertGpu', 'AlertRam', 'AlertDisk', 'AlertSpeed', 'AlertDns', 'DeviceAlerts', 'AlertOutage', 'AlertData', 'AlertBattery') -contains $key -and -not $value) { Purge-Alerts $key }
    if ($key -eq 'ShowTaskbarBadge') { Update-Badge }
    if ($key -eq 'AlwaysOnTop') { $script:Form.TopMost = [bool]$value }
    if ($key -eq 'WifiEnabled') { if ($value) { Start-WifiServices } else { Stop-WifiServices } }
    if ($key -eq 'SnapToCorner') {
        if ($value) { Snap-ToNearestCorner }
        else { $script:Settings['PosX'] = $script:Form.Left; $script:Settings['PosY'] = $script:Form.Top; Save-Settings }
    }
    if ($key -eq 'AutoHideFullscreen' -and -not $value -and $script:AutoHidden) { Set-AutoHidden $false }
}

function Set-Theme([string]$name) {
    $script:Settings['Theme'] = $name
    Write-Log ('Setting Theme = ' + $name)
    Save-Settings
    Build-Palette
    $script:Form.BackColor = $script:Pal.Bg
    $script:Form.Invalidate()
    if ($null -ne $script:Popup) { $script:Popup.BackColor = $script:Pal.Bg; $script:Popup.Invalidate() }
    Refresh-Badge
}

# The very first draw of a page is slow (PowerShell compiles the drawing code). Doing it once in the background of
# start-up makes the first expand as quick as the later ones.
function Invoke-Warmup {
    $fm = $script:Form
    if (-not $fm.Visible -or $fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or $script:ResizeAnim.Active -or $script:Dragging) { return }
    $saveExp = $script:Settings['Expanded']; $saveTab = $script:Settings['ExpandedTab']; $saveHit = $script:Hit
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $script:Settings['Expanded'] = $true
        foreach ($tab in 'System', 'Network') {
            $script:Settings['ExpandedTab'] = $tab
            $sz = Get-TargetSize (Get-LayoutScreen)
            $b = Render-Bitmap $sz.Width $sz.Height
            $b.Dispose()
        }
    } finally {
        $script:Settings['Expanded'] = $saveExp; $script:Settings['ExpandedTab'] = $saveTab; $script:Hit = $saveHit
    }
    Write-Log ('Warm-up render done in ' + $sw.ElapsedMilliseconds + ' ms')
}

function Render-Bitmap([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    try { Paint-Main $gr $w $h } finally { $gr.Dispose() }
    return $bmp
}

function Finish-ResizeAnim {
    try { $script:TimerResize.Stop() } catch { }
    $script:ResizeAnim = @{ Active = $false }
    if ($null -ne $script:AnimBmp) { try { $script:AnimBmp.Dispose() } catch { }; $script:AnimBmp = $null }
    $script:Resizing = $false
    Apply-Layout
}

# the animated rectangle (screen coordinates) at progress t (0..1): ease-out
function Get-AnimRect($a, [double]$t) {
    $e = 1.0 - [Math]::Pow(1.0 - $t, 3)
    return (New-Object System.Drawing.Rectangle(
        [int][Math]::Round($a.FromX + ($a.ToX - $a.FromX) * $e),
        [int][Math]::Round($a.FromY + ($a.ToY - $a.FromY) * $e),
        [int][Math]::Round($a.FromW + ($a.ToW - $a.FromW) * $e),
        [int][Math]::Round($a.FromH + ($a.ToH - $a.FromH) * $e)))
}

function Step-ResizeAnim {
    $a = $script:ResizeAnim
    if (-not $a.Active) { $script:TimerResize.Stop(); return }
    $t = [Math]::Min(1.0, $a.Sw.ElapsedMilliseconds / [double]$a.Dur)
    if ($t -ge 1.0) { Finish-ResizeAnim; return }
    $r = Get-AnimRect $a $t
    # only the shape of the window changes; what is inside it was drawn once, so nothing flickers
    Set-RegionRect ($r.X - $a.UX) ($r.Y - $a.UY) $r.Width $r.Height
}

function Toggle-Expanded {
    if ($script:ResizeAnim.Active) { return }
    $fm = $script:Form
    $newExp = -not [bool]$script:Settings['Expanded']
    $script:Anim['Active'] = $false
    $script:TimerAnim.Stop()
    $canAnim = ($fm.Visible -and $fm.IsHandleCreated -and $fm.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized)
    if (-not $canAnim) {
        $script:Settings['Expanded'] = $newExp; Save-Settings; Apply-Layout; return
    }
    $screen = Get-LayoutScreen
    $fromSize = $fm.Size; $fromPt = $fm.Location
    $bmp = $null
    try {
        if ($newExp) {
            $script:Settings['Expanded'] = $true
            $toSize = Get-TargetSize $screen
            $toPt = Get-LayoutPoint $screen $toSize
            Update-Glass (New-Object System.Drawing.Rectangle($toPt, $toSize)) $true
            $bmp = Render-Bitmap $toSize.Width $toSize.Height
        } else {
            $bmp = Render-Bitmap $fromSize.Width $fromSize.Height     # still shows the expanded look
            $script:Settings['Expanded'] = $false
            $toSize = Get-TargetSize $screen
            $toPt = Get-LayoutPoint $screen $toSize
        }
    } catch {
        Log-Once 'Expand render' (Err-Text $_)
        if ($null -ne $bmp) { $bmp.Dispose() }
        $script:Settings['Expanded'] = $newExp; Save-Settings; Apply-Layout; return
    }
    Write-Log ('Setting Expanded = ' + $script:Settings['Expanded'])
    Save-Settings
    $fromRect = New-Object System.Drawing.Rectangle($fromPt, $fromSize)
    $toRect = New-Object System.Drawing.Rectangle($toPt, $toSize)
    $union = [System.Drawing.Rectangle]::Union($fromRect, $toRect)
    if ($newExp) { $big = $toRect } else { $big = $fromRect }
    $script:AnimOff = New-Object System.Drawing.Point(($big.X - $union.X), ($big.Y - $union.Y))
    $script:AnimBmp = $bmp
    $script:Resizing = $true
    $script:ResizeAnim = @{ Active = $true; Dur = 230.0; Sw = [System.Diagnostics.Stopwatch]::StartNew()
        FromW = $fromSize.Width; ToW = $toSize.Width; FromH = $fromSize.Height; ToH = $toSize.Height
        FromX = $fromPt.X; ToX = $toPt.X; FromY = $fromPt.Y; ToY = $toPt.Y; UX = $union.X; UY = $union.Y }
    Update-ResizeMode
    # the window becomes as big as the larger of the two sizes at once, but keeps the OLD shape, so the screen does not change yet
    $redrawOff = $false
    try {
        if ($fm.IsHandleCreated) { [void][Native]::SendMessage($fm.Handle, 0x000B, [IntPtr]0, [IntPtr]::Zero); $redrawOff = $true }
        Set-RegionRect ($fromRect.X - $union.X) ($fromRect.Y - $union.Y) $fromRect.Width $fromRect.Height
        $fm.Bounds = $union
    } finally {
        if ($redrawOff) { [void][Native]::SendMessage($fm.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero) }
    }
    $fm.Invalidate()
    $fm.Update()                       # draws the picture once
    $script:ResizeAnim.Sw.Restart()    # the clock starts after the first frame is on screen
    $script:TimerResize.Interval = 10
    $script:TimerResize.Start()
}

function New-Swatch([int[]]$rgb) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 150, 150), 1)
    $g.FillEllipse($b, 1, 1, 13, 13)
    $g.DrawEllipse($pen, 1, 1, 13, 13)
    $b.Dispose(); $pen.Dispose(); $g.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- frosted glass
$script:GlassBmp = $null
$script:GlassOk = $false
$script:Resizing = $false
$script:Sizing = $false     # the user is dragging a window edge
$script:AnimBmp = $null
$script:AnimOff = New-Object System.Drawing.Point(0, 0)   # where the pre-drawn picture sits inside the animation window
$script:ResizeAnim = @{ Active = $false }
$script:AutoHidden = $false
$script:Backgrounded = $false
$script:Exiting = $false
$script:WasMin = $false
$script:Idle = $false
$script:DiskLast = @{}
$script:LastLocBlur = [DateTime]::MinValue

# Only used for the split second of a glass capture and to test that the call is supported.
# The widget is NOT excluded from screenshots or recordings the rest of the time.
function Test-AffinitySupport {
    $ok = (Set-Affinity 0x11)
    if ($ok) { [void](Set-Affinity 0) }
    return $ok
}

function Set-Affinity([uint32]$mode, [bool]$quiet = $false) {
    $ok = $false
    try {
        $ok = [Native]::SetWindowDisplayAffinity($script:Form.Handle, $mode)
        if (-not $ok -and -not $quiet) { Write-Log ('SetWindowDisplayAffinity(' + $mode + ') failed, win32 error ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    } catch { Write-Log ('SetWindowDisplayAffinity exception: ' + $_.Exception.Message) }
    return $ok
}

function Free-GlassBmp {
    if ($null -ne $script:GlassBmp) { try { $script:GlassBmp.Dispose() } catch { }; $script:GlassBmp = $null }
}

function Enable-Glass {
    $fm = $script:Form
    $fm.Opacity = 0.999
    if ($fm.IsHandleCreated) {
        $script:GlassOk = (Test-AffinitySupport)
        if ($script:GlassOk) { Write-Log 'Glass on (widget stays visible in screenshots)' } else { Write-Log 'Glass unavailable, using solid tinted background' }
        Update-Glass
    }
}

function Disable-Glass {
    $fm = $script:Form
    if ($fm.IsHandleCreated -and $script:GlassOk) { [void](Set-Affinity 0) }
    $script:GlassOk = $false
    Free-GlassBmp
    $fm.Opacity = 1.0
    $fm.Invalidate()
    Write-Log 'Glass off'
}

function Update-Glass($rect = $null, [bool]$noInvalidate = $false) {
    if (-not $script:Settings['Glass'] -or -not $script:GlassOk) { return }
    $fm = $script:Form
    if (-not $fm.Visible -or $script:AutoHidden -or $fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
    if ($script:Dragging -or $script:Anim.Active -or $script:Sizing) { return }
    if ($script:ResizeAnim.Active -and $null -eq $rect) { return }
    if ($null -eq $rect) { $rect = $fm.Bounds }
    $w = $rect.Width; $h = $rect.Height
    if ($w -lt 10 -or $h -lt 10) { return }
    $full = $null; $b1 = $null; $b2 = $null
    try {
        $full = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $gg = [System.Drawing.Graphics]::FromImage($full)
        # Hide the widget from capture only while we grab the pixels behind it, then show it to capture again.
        [void](Set-Affinity 0x11 $true)
        try {
            Start-Sleep -Milliseconds 50
            $gg.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $rect.Size)
        } finally { [void](Set-Affinity 0 $true) }
        $gg.Dispose()
        $w1 = [Math]::Max(1, [int]($w / 5)); $h1 = [Math]::Max(1, [int]($h / 5))
        $b1 = New-Object System.Drawing.Bitmap($w1, $h1, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $g1 = [System.Drawing.Graphics]::FromImage($b1)
        $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g1.DrawImage($full, 0, 0, $w1, $h1)
        $g1.Dispose()
        $w2 = [Math]::Max(1, [int]($w1 / 3)); $h2 = [Math]::Max(1, [int]($h1 / 3))
        $b2 = New-Object System.Drawing.Bitmap($w2, $h2, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $g2 = [System.Drawing.Graphics]::FromImage($b2)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g2.DrawImage($b1, 0, 0, $w2, $h2)
        $g2.Dispose()
        $old = $script:GlassBmp
        $script:GlassBmp = $b2; $b2 = $null
        if ($null -ne $old) { $old.Dispose() }
        if (-not $noInvalidate) { $fm.Invalidate() }
    } catch { Log-Once 'Glass capture' (Err-Text $_) }
    finally {
        if ($null -ne $full) { $full.Dispose() }
        if ($null -ne $b1) { $b1.Dispose() }
        if ($null -ne $b2) { $b2.Dispose() }
    }
}

function Paint-Glass($g, $path, [int]$w, [int]$h) {
    $p = $script:Pal
    $g.SetClip($path)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $bm = $script:GlassBmp
    $g.DrawImage($bm, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), 0, 0, $bm.Width, $bm.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $ia.Dispose()
    $g.FillRectangle((Get-Brush (Alpha ([System.Drawing.Color]::White) 30)), 0, 0, $w, $h)
    $ta = [int]([Math]::Min(0.88, [Math]::Max(0.35, [double]$script:Settings['GlassOpacity'] - 0.12)) * 255)
    $g.FillRectangle((Get-Brush (Alpha $p.Bg $ta)), 0, 0, $w, $h)
    $g.FillRectangle((Get-Brush (Alpha $p.Header $ta)), 0, 0, $w, $script:HeaderH)
    $sr = New-Object System.Drawing.Rectangle(0, 0, $w, (S 96))
    $lb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($sr, [System.Drawing.Color]::FromArgb(48, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillRectangle($lb, $sr)
    $lb.Dispose()
    $g.ResetClip()
}

# ---------------------------------------------------------------- settings menu (step 5)
function Pick-CustomColor {
    $owner = $null; $dlg = $null
    try {
        $wr = Get-WidgetRect
        $owner = New-Object System.Windows.Forms.Form
        $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $owner.ShowInTaskbar = $false
        $owner.TopMost = $true
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $owner.Size = New-Object System.Drawing.Size(1, 1)
        $owner.Location = New-Object System.Drawing.Point(($wr.Left + 20), ($wr.Top + 20))
        $owner.Opacity = 0.01
        $owner.Show()
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $rgb = Get-ThemeRgb
        $dlg.Color = [System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            $c = $dlg.Color
            Set-Setting 'CustomColor' ('{0},{1},{2}' -f $c.R, $c.G, $c.B)
            Set-Theme 'Custom'
        }
    } catch { Write-Log ('Custom colour: ' + (Err-Text $_)) }
    finally {
        if ($null -ne $dlg) { $dlg.Dispose() }
        if ($null -ne $owner) { $owner.Close(); $owner.Dispose() }
    }
}

function Set-Choice([string]$key, $value) {
    Set-Setting $key $value
    if ($key -eq 'RefreshMs') { $script:TimerMain.Interval = [int]$value }
    if ($key -eq 'UiScale') { Apply-UiScale }
    if ($key -eq 'BadgeSide') { Update-Badge }
    if ($key -eq 'HistoryKeepMonths' -or $key -eq 'HistoryCleanupMode') { $script:Shared['Cfg']['CleanupRequest'] = $true }
    if ($key -eq 'GlassOpacity') { Update-Glass; $script:Form.Invalidate() }
}

function Set-GlassSetting([bool]$on) {
    Set-Setting 'Glass' $on
    if ($on) { Enable-Glass } else { Disable-Glass }
}

function Add-ChoiceMenu($parent, [string]$text, [string]$key, $values, $labels) {
    $sub = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    for ($i = 0; $i -lt $values.Count; $i++) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem([string]$labels[$i])
        $mi.Tag = @{ Key = $key; Value = $values[$i] }
        $mi.Checked = ([string]$script:Settings[$key] -eq [string]$values[$i])
        $mi.Add_Click({ param($s, $e) try { Set-Choice ([string]$s.Tag.Key) $s.Tag.Value } catch { Log-Once 'Choice click' (Err-Text $_) } })
        [void]$sub.DropDownItems.Add($mi)
    }
    if ($parent -is [System.Windows.Forms.ToolStripMenuItem]) { [void]$parent.DropDownItems.Add($sub) } else { [void]$parent.Items.Add($sub) }
}

function Add-ToggleItem($menu, [string]$text, [string]$key) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.Tag = $key
    $mi.Checked = [bool]$script:Settings[$key]
    $mi.Add_Click({ param($s, $e) try { Set-Setting ([string]$s.Tag) (-not [bool]$script:Settings[[string]$s.Tag]) } catch { Log-Once 'Toggle click' (Err-Text $_) } })
    if ($menu -is [System.Windows.Forms.ToolStripMenuItem]) { [void]$menu.DropDownItems.Add($mi) } else { [void]$menu.Items.Add($mi) }
}

function Show-SettingsMenu {
    try { if ($null -ne $script:Menu) { $script:Menu.Dispose() } } catch { }
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $themeItem = New-Object System.Windows.Forms.ToolStripMenuItem('Background colour')
    foreach ($name in @($script:Themes.Keys)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($name)
        $mi.Tag = $name
        $mi.Image = New-Swatch $script:Themes[$name]
        $mi.Checked = ([string]$script:Settings['Theme'] -eq $name)
        $mi.Add_Click({ param($s, $e) try { Set-Theme ([string]$s.Tag) } catch { Log-Once 'Theme click' (Err-Text $_) } })
        [void]$themeItem.DropDownItems.Add($mi)
    }
    $ci = New-Object System.Windows.Forms.ToolStripMenuItem('Custom color...')
    $ci.Checked = ([string]$script:Settings['Theme'] -eq 'Custom')
    $ci.Add_Click({ param($s, $e) try { Pick-CustomColor } catch { Log-Once 'Custom click' (Err-Text $_) } })
    [void]$themeItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$themeItem.DropDownItems.Add($ci)
    [void]$menu.Items.Add($themeItem)

    $gi = New-Object System.Windows.Forms.ToolStripMenuItem('Glass (translucent)')
    $gi.Checked = [bool]$script:Settings['Glass']
    $gi.Add_Click({ param($s, $e) try { Set-GlassSetting (-not [bool]$script:Settings['Glass']) } catch { Log-Once 'Glass click' (Err-Text $_) } })
    [void]$menu.Items.Add($gi)
    Add-ChoiceMenu $menu 'Glass opacity' 'GlassOpacity' @(0.95, 0.90, 0.85, 0.75, 0.65, 0.55) @('95%', '90%', '85%', '75%', '65%', '55%')

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    Add-ToggleItem $menu 'Alerts enabled' 'AlertsEnabled'
    $at = New-Object System.Windows.Forms.ToolStripMenuItem('Alert types')
    Add-ToggleItem $at 'High CPU usage' 'AlertCpu'
    Add-ToggleItem $at 'High GPU usage' 'AlertGpu'
    Add-ToggleItem $at 'High memory (RAM) usage' 'AlertRam'
    Add-ToggleItem $at 'Low disk space' 'AlertDisk'
    Add-ToggleItem $at 'New machine connected to the network' 'DeviceAlerts'
    Add-ToggleItem $at 'Slow / recovered internet speed' 'AlertSpeed'
    Add-ToggleItem $at 'DNS Shield turned off' 'AlertDns'
    Add-ToggleItem $at 'Internet / network outage ended' 'AlertOutage'
    Add-ToggleItem $at 'Monthly data limit' 'AlertData'
    Add-ToggleItem $at 'Low battery' 'AlertBattery'
    [void]$menu.Items.Add($at)
    $al = New-Object System.Windows.Forms.ToolStripMenuItem('Alert settings')
    $thv = @(70, 80, 85, 90, 95); $thl = @('70%', '80%', '85%', '90%', '95%')
    Add-ChoiceMenu $al 'CPU threshold' 'CpuThreshold' $thv $thl
    Add-ChoiceMenu $al 'GPU threshold' 'GpuThreshold' $thv $thl
    Add-ChoiceMenu $al 'RAM threshold' 'MemThreshold' $thv $thl
    Add-ChoiceMenu $al 'Sustained for' 'SustainedSec' @(5, 10, 20, 30, 60) @('5 s', '10 s', '20 s', '30 s', '60 s')
    Add-ChoiceMenu $al 'Cooldown per metric' 'CooldownSec' @(60, 120, 300, 600) @('1 min', '2 min', '5 min', '10 min')
    Add-ChoiceMenu $al 'Low battery alert at' 'BatteryLowPct' @(10, 15, 20, 30) @('10%', '15%', '20%', '30%')
    Add-ChoiceMenu $al 'Low disk space alert' 'DiskFreePct' @(0, 5, 10, 15, 20) @('Off', 'below 5% free', 'below 10% free', 'below 15% free', 'below 20% free')
    [void]$menu.Items.Add($al)
    Add-ChoiceMenu $menu 'Refresh rate' 'RefreshMs' @(500, 1000, 2000, 5000) @('0.5 s', '1 s', '2 s', '5 s')
    $wm = New-Object System.Windows.Forms.ToolStripMenuItem('Network assistant')
    Add-ToggleItem $wm 'Network monitoring (pings, speed, devices, DNS)' 'WifiEnabled'
    Add-ToggleItem $wm 'Auto speed test every 30 min' 'AutoSpeedTest'
    Add-ChoiceMenu $wm 'Slow-speed limit' 'SlowLimit' @(5, 10, 25, 50) @('5 Mbps', '10 Mbps', '25 Mbps', '50 Mbps')
    $m1 = New-Object System.Windows.Forms.ToolStripMenuItem('Run speed test now')
    $m1.Add_Click({ param($s, $e) try { Start-SpeedTest $true } catch { Log-Once 'Speed click' (Err-Text $_) } })
    [void]$wm.DropDownItems.Add($m1)
    $m3 = New-Object System.Windows.Forms.ToolStripMenuItem('Run full test (1-2 minutes)')
    $m3.Add_Click({ param($s, $e) try { Start-FullTest } catch { Log-Once 'Full test click' (Err-Text $_) } })
    [void]$wm.DropDownItems.Add($m3)
    $m4 = New-Object System.Windows.Forms.ToolStripMenuItem('Open network dashboard (history, speed tests, full tests)')
    $m4.Add_Click({ param($s, $e) try { Open-WebPage 'net' $script:NetworkHtml } catch { Log-Once 'Dashboard click' (Err-Text $_) } })
    [void]$wm.DropDownItems.Add($m4)
    $m5 = New-Object System.Windows.Forms.ToolStripMenuItem('Report for my internet provider (outages, slow speeds)')
    $m5.Add_Click({ param($s, $e) try { Open-ProviderReport } catch { Log-Once 'Report click' (Err-Text $_) } })
    [void]$wm.DropDownItems.Add($m5)
    $m6 = New-Object System.Windows.Forms.ToolStripMenuItem('Scan nearby Wi-Fi networks now')
    $m6.Add_Click({ param($s, $e) try { Set-ExpTab 'Network'; Set-NetView 'Nearby'; Start-WifiScan } catch { Log-Once 'Scan click' (Err-Text $_) } })
    [void]$wm.DropDownItems.Add($m6)
    Add-ChoiceMenu $wm 'Monthly data limit' 'DataLimitGB' @(0, 50, 100, 200, 500, 1000) @('No limit', '50 GB', '100 GB', '200 GB', '500 GB', '1000 GB')
    Add-ChoiceMenu $wm 'Data counter restarts on day' 'DataResetDay' @(1, 5, 10, 15, 20, 25) @('1st', '5th', '10th', '15th', '20th', '25th')
    $m2 = New-Object System.Windows.Forms.ToolStripMenuItem('Check DNS Shield now')
    $m2.Add_Click({ param($s, $e) try { $script:NextDnsUtc = [DateTime]::UtcNow } catch { } })
    [void]$wm.DropDownItems.Add($m2)
    $pv = New-Object System.Windows.Forms.ToolStripMenuItem('Preview network popups')
    $pv1 = New-Object System.Windows.Forms.ToolStripMenuItem('New device popup')
    $pv1.Add_Click({ param($s, $e) try {
        $list = @(Get-SortedDevices); $pick = $null
        foreach ($dv in $list) { if (-not (Get-DeviceName $dv)) { $pick = $dv; break } }
        if ($null -eq $pick -and $list.Count -gt 0) { $pick = $list[0] }
        if ($null -eq $pick) { Show-Balloon 'Preview' 'No devices found yet - wait a few seconds.'; return }
        [void](Show-DevicePopup @{ Mac = [string]$pick.Mac; Kind = 'new' } $true)
    } catch { Log-Once 'Preview click' (Err-Text $_) } })
    $pv2 = New-Object System.Windows.Forms.ToolStripMenuItem('Slow speed popup')
    $pv2.Add_Click({ param($s, $e) try { [void](Show-SpeedPopup @{ Type = 'speed'; Kind = 'slow'; Reason = 'auto'; Mbps = 4.2; Limit = [double]$script:Settings['SlowLimit'] }) } catch { } })
    $pv3 = New-Object System.Windows.Forms.ToolStripMenuItem('Fast speed popup')
    $pv3.Add_Click({ param($s, $e) try { [void](Show-SpeedPopup @{ Type = 'speed'; Kind = 'fast'; Reason = 'recovered'; Mbps = 48.7; Limit = [double]$script:Settings['SlowLimit'] }) } catch { } })
    $pv4 = New-Object System.Windows.Forms.ToolStripMenuItem('DNS Shield off popup')
    $pv4.Add_Click({ param($s, $e) try { [void](Show-DnsPopup @{ Summary = 'Using your router DNS: no scam filter known.' }) } catch { } })
    foreach ($pi in @($pv1, $pv2, $pv3, $pv4)) { [void]$pv.DropDownItems.Add($pi) }
    [void]$wm.DropDownItems.Add($pv)
    [void]$menu.Items.Add($wm)
    $win = New-Object System.Windows.Forms.ToolStripMenuItem('Window and power')
    $sw = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
    $sw.Checked = (Test-StartupEnabled)
    $sw.Add_Click({ param($s, $e) try { Set-Startup (-not (Test-StartupEnabled)) } catch { Log-Once 'Startup click' (Err-Text $_) } })
    [void]$win.DropDownItems.Add($sw)
    Add-ToggleItem $win 'Always on top of other windows' 'AlwaysOnTop'
    Add-ToggleItem $win 'Snap to screen corners after moving' 'SnapToCorner'
    $rz = New-Object System.Windows.Forms.ToolStripMenuItem('Reset window size')
    $rz.Add_Click({ param($s, $e) try { foreach ($k in 'SizeW', 'SizeH', 'SizeCW', 'SizeCH') { $script:Settings[$k] = 0.0 }; Save-Settings; Apply-Layout } catch { Log-Once 'Reset size' (Err-Text $_) } })
    [void]$win.DropDownItems.Add($rz)
    Add-ToggleItem $win 'Taskbar mini widget' 'ShowTaskbarBadge'
    Add-ChoiceMenu $win 'Taskbar mini widget position' 'BadgeSide' @('Left', 'Right') @('Left (between Widgets and Start)', 'Right (next to the tray area)')
    Add-ToggleItem $win 'Keep running in the background when closed (x)' 'CloseToBackground'
    Add-ChoiceMenu $win 'Size' 'UiScale' @(0.85, 1.0, 1.2, 1.4) @('Small', 'Normal', 'Large', 'Extra large')
    Add-ToggleItem $win 'Auto-hide when a fullscreen app is active' 'AutoHideFullscreen'
    Add-ToggleItem $win 'Click-through (a second start turns it off)' 'ClickThrough'
    Add-ToggleItem $win 'Slow down sampling when idle' 'PauseWhenIdle'
    Add-ChoiceMenu $win 'Idle after' 'IdleMinutes' @(2, 5, 10, 15) @('2 min', '5 min', '10 min', '15 min')
    [void]$menu.Items.Add($win)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    Add-ToggleItem $menu 'History logging' 'HistoryEnabled'
    Add-ChoiceMenu $menu 'History interval' 'HistoryIntervalSec' @(1, 5, 10, 30, 60) @('1 s', '5 s', '10 s', '30 s', '60 s')
    $hc = New-Object System.Windows.Forms.ToolStripMenuItem('History cleanup')
    Add-ChoiceMenu $hc 'Keep history' 'HistoryKeepMonths' @(0, 3, 6, 12, 24) @('Forever', '3 months', '6 months', '12 months', '24 months')
    Add-ChoiceMenu $hc 'Older files' 'HistoryCleanupMode' @('Compress', 'Delete') @('Compress (.gz)', 'Delete')
    $cn = New-Object System.Windows.Forms.ToolStripMenuItem('Clean up now')
    $cn.Add_Click({ param($s, $e) try { $script:Shared['Cfg']['CleanupRequest'] = $true; Write-Log 'History cleanup requested' } catch { Log-Once 'Cleanup click' (Err-Text $_) } })
    [void]$hc.DropDownItems.Add($cn)
    [void]$menu.Items.Add($hc)
    Add-ChoiceMenu $menu 'Log level' 'LogLevel' @('Normal', 'Quiet') @('Normal', 'Quiet (errors only)')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $di = New-Object System.Windows.Forms.ToolStripMenuItem('Open data folder')
    $di.Add_Click({ param($s, $e) try { Open-DataFolder } catch { Log-Once 'Folder click' (Err-Text $_) } })
    [void]$menu.Items.Add($di)
    $ti = New-Object System.Windows.Forms.ToolStripMenuItem('Test popup')
    $ti.Add_Click({ param($s, $e) try { Show-TestPopup } catch { Log-Once 'Test popup' (Err-Text $_) } })
    [void]$menu.Items.Add($ti)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $xi = New-Object System.Windows.Forms.ToolStripMenuItem('Exit dashboard')
    $xi.Add_Click({ param($s, $e) try { Exit-App } catch { Log-Once 'Exit click' (Err-Text $_) } })
    [void]$menu.Items.Add($xi)

    $script:Menu = $menu
    $r = $script:Hit['settings']
    $menu.Show($script:Form, (New-Object System.Drawing.Point($r.Left, ($r.Bottom + (S 4)))))
}

function Invoke-Action([string]$name) {
    switch ($name) {
        'min'      { $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized }
        'close'    { Request-Close }
        'expand'   { Toggle-Expanded }
        'settings' { Show-SettingsMenu }
        'hist'     { Open-HistoryPage }
        'alerts'   { Open-AlertsPage }
        'tab_sys'  { Set-ExpTab 'System' }
        'tab_wifi' { Set-ExpTab 'Network' }
        'nv_dev'   { Set-NetView 'Devices' }
        'nv_wifi'  { Set-NetView 'Nearby' }
        'nv_dns'   { Set-NetView 'Dns' }
        'nv_speed' { Set-NetView 'Speed' }
        'sp_run'   { Start-SpeedTest $true }
        'sc_scan'  { Start-WifiScan }
        'w_speed'  { Start-SpeedTest $true }
        'w_full'   { Start-FullTest }
        'w_dash'   { Open-WebPage 'net' $script:NetworkHtml }
        'w_dns'    { $script:NextDnsUtc = [DateTime]::UtcNow; $script:Dns['Summary'] = 'Checking your DNS servers...'; $script:Form.Invalidate() }
        'dns_fix'  { Show-DnsFixDialog }
    }
}

# ---------------------------------------------------------------- form events
$f.Add_Paint({ param($s, $e) try { Paint-Main $e.Graphics $s.ClientSize.Width $s.ClientSize.Height } catch { Log-Once 'Paint' (Err-Text $_) } })

$f.Add_HandleCreated({ param($s, $e) try {
    Write-Log 'Main window handle created'
    if ($script:Settings['Glass']) { $script:GlassOk = (Test-AffinitySupport); if (-not $script:GlassOk) { Write-Log 'Glass unavailable, using solid tinted background' } }
} catch { Log-Once 'HandleCreated' (Err-Text $_) } })

$f.Add_Shown({ param($s, $e) try { Update-Glass } catch { Log-Once 'Shown' (Err-Text $_) } })

$f.Add_LocationChanged({ param($s, $e) try {
    $now = Get-Date
    if (-not $script:Resizing -and ($now - $script:LastLocBlur).TotalMilliseconds -ge 60) { $script:LastLocBlur = $now; Update-Glass }
} catch { Log-Once 'LocationChanged' (Err-Text $_) } })

$f.Add_SizeChanged({ param($s, $e) try {
    $isMin = ($s.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized)
    if (-not $isMin -and $script:WasMin) { Disable-ClickThroughIfOn }
    $script:WasMin = $isMin
    if ($s.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        if (-not $script:Resizing) { Update-Region; Update-Glass }
        if ($script:PendingResnap -and -not $script:Dragging -and -not $script:Anim.Active) { $script:PendingResnap = $false; Apply-Layout }
    }
} catch { Log-Once 'SizeChanged' (Err-Text $_) } })

$f.Add_ResizeBegin({ param($s, $e) try {
    $script:Sizing = $true
    $wa = [System.Windows.Forms.Screen]::FromRectangle($s.Bounds).WorkingArea
    $min = Get-MinSize
    if ($script:Settings['Expanded']) { $minH = $min.Height; $maxH = $wa.Height - 2 * $script:M } else { $minH = $script:CompactH; $maxH = [Math]::Min($script:CompactH + [int](S 140), $wa.Height - 2 * $script:M) }
    $s.MinimumSize = New-Object System.Drawing.Size($min.Width, $minH)
    $s.MaximumSize = New-Object System.Drawing.Size(($wa.Width - 2 * $script:M), $maxH)
} catch { Log-Once 'ResizeBegin' (Err-Text $_) } })

$f.Add_ResizeEnd({ param($s, $e) try {
    $s.MinimumSize = New-Object System.Drawing.Size(0, 0)
    $s.MaximumSize = New-Object System.Drawing.Size(0, 0)
    $script:Sizing = $false
    $u = [double]$script:Scale
    if ($script:Settings['Expanded']) {
        $script:Settings['SizeW'] = [Math]::Round($s.Width / $u, 1)
        $script:Settings['SizeH'] = [Math]::Round($s.Height / $u, 1)
    } else {
        $script:Settings['SizeCW'] = [Math]::Round($s.Width / $u, 1)
        $script:Settings['SizeCH'] = [Math]::Round($s.Height / $u, 1)
    }
    Write-Log ('Resized to ' + $s.Width + ' x ' + $s.Height)
    Save-Settings
    Update-Region
    Finish-Drag                      # remembers the position, keeps the window on screen, refreshes the glass
} catch { $script:Sizing = $false; Log-Once 'ResizeEnd' (Err-Text $_) } })

$f.Add_MouseDown({ param($s, $e) try {
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:Anim.Active) { $script:Anim['Active'] = $false; $script:TimerAnim.Stop() }
    $script:Down = @{ Cursor = [System.Windows.Forms.Cursor]::Position; Loc = $s.Location; Hit = (Hit-Test $e.Location); Moved = $false }
} catch { Log-Once 'MouseDown' (Err-Text $_) } })

$f.Add_MouseMove({ param($s, $e) try {
    $d = $script:Down
    if ($null -ne $d) {
        if ($null -eq $d.Hit) {
            $cp = [System.Windows.Forms.Cursor]::Position
            $dx = $cp.X - $d.Cursor.X; $dy = $cp.Y - $d.Cursor.Y
            if (-not $d.Moved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -lt (S 4)) { return }
            $d.Moved = $true
            $script:Dragging = $true
            $s.Location = New-Object System.Drawing.Point(($d.Loc.X + $dx), ($d.Loc.Y + $dy))
        }
        return
    }
    $h = Hit-Test $e.Location
    if ($h -ne $script:Hover) {
        $script:Hover = $h
        if ($null -ne $h) { $s.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $s.Cursor = [System.Windows.Forms.Cursors]::Default }
        $s.Invalidate()
    }
} catch { Log-Once 'MouseMove' (Err-Text $_) } })

$f.Add_MouseUp({ param($s, $e) try {
    $d = $script:Down
    $script:Down = $null
    if ($null -eq $d) { return }
    if ($d.Moved) { $script:Dragging = $false; Finish-Drag; return }
    if ($null -eq $d.Hit -and $script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network') {
        $row = Get-DeviceRowAt $e.Location
        if ($row) { Show-NameDialog ([string]$row.Mac); return }
    }
    if ($null -ne $d.Hit -and (Hit-Test $e.Location) -eq $d.Hit) { Invoke-Action ([string]$d.Hit) }
} catch { $script:Dragging = $false; Log-Once 'MouseUp' (Err-Text $_) } })

$f.Add_MouseLeave({ param($s, $e) try {
    if ($null -ne $script:Hover -and $null -eq $script:Down) { $script:Hover = $null; $s.Cursor = [System.Windows.Forms.Cursors]::Default; $s.Invalidate() }
} catch { Log-Once 'MouseLeave' (Err-Text $_) } })

$f.Add_MouseWheel({ param($s, $e) try {
    if ($script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network' -and $script:NetMax -gt 0 -and $script:NetRect.Contains($e.Location)) {
        $nv = [string]$script:Settings['NetView']
        $overList = (($nv -eq 'Devices' -and $script:DevPanelRect.Contains($e.Location)) -or ($nv -eq 'Nearby' -and $script:ScanPanelRect.Contains($e.Location)))
        if (-not $overList) {
            $step = [double](S 44)
            if ($e.Delta -gt 0) { $script:NetScroll = [Math]::Max(0.0, $script:NetScroll - $step) } else { $script:NetScroll = [Math]::Min($script:NetMax, $script:NetScroll + $step) }
            $s.Invalidate()
        }
    }
    if ($script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'System' -and $script:SysMax -gt 0 -and $script:SysRect.Contains($e.Location)) {
        $step = [double](S 44)
        if ($e.Delta -gt 0) { $script:SysScroll = [Math]::Max(0.0, $script:SysScroll - $step) } else { $script:SysScroll = [Math]::Min($script:SysMax, $script:SysScroll + $step) }
        $s.Invalidate()
    }
    if ($script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network' -and [string]$script:Settings['NetView'] -eq 'Nearby' -and $script:ScanPanelRect.Contains($e.Location)) {
        if ($e.Delta -gt 0) { $script:ScanScroll = [Math]::Max(0, $script:ScanScroll - 1) } else { $script:ScanScroll = $script:ScanScroll + 1 }
        $s.Invalidate()
    }
    if ($script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network' -and [string]$script:Settings['NetView'] -eq 'Devices' -and $script:DevPanelRect.Contains($e.Location)) {
        if ($e.Delta -gt 0) { $script:DevScroll = $script:DevScroll - 1 } else { $script:DevScroll = $script:DevScroll + 1 }
        if ($script:DevScroll -lt 0) { $script:DevScroll = 0 }
        $s.Invalidate()
    }
} catch { Log-Once 'MouseWheel' (Err-Text $_) } })

$f.Add_FormClosing({ param($s, $e) try {
    # Alt+F4 or "Close window" from the taskbar also just go to the background (not on Windows shutdown)
    if (-not $script:Exiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and (Can-Background)) {
        $e.Cancel = $true
        Hide-ToBackground
        return
    }
    Stop-Everything
} catch { Write-Log ('FormClosing: ' + $_.Exception.Message) } })

# ---------------------------------------------------------------- painting
function Draw-Panel($g, [double]$x, [double]$y, [double]$w, [double]$h, [string]$title) {
    $p = New-RoundPath ($x + 0.5) ($y + 0.5) ($w - 1) ($h - 1) (S 8)
    $g.FillPath((Get-Brush $script:Pal.Panel), $p)
    $g.DrawPath((Get-Pen $script:Pal.PanelLine $script:Px1 $false), $p)
    $p.Dispose()
    if ($title) { Draw-Text $g $title $script:Fonts.PanelTitle (Get-Brush $script:Pal.Text) ($x + (S 10)) ($y + (S 4)) ($w - (S 20)) (S 18) 'LM' }
}

function Draw-Tile($g, [double]$x, [double]$y, [double]$w, [double]$h, [string]$label, [string]$value, [string]$sub, $valColor) {
    $F = $script:Fonts; $mut = Get-Brush $script:Pal.Muted
    Draw-Panel $g $x $y $w $h ''
    Draw-Text $g $label $F.Muted $mut ($x + (S 10)) ($y + (S 4)) ($w - (S 20)) (S 12) 'LM'
    Draw-Text $g $value $F.Tile (Get-Brush $valColor) ($x + (S 10)) ($y + (S 15)) ($w - (S 20)) (S 24) 'LM'
    Draw-Text $g $sub $F.Muted $mut ($x + (S 10)) ($y + $h - (S 16)) ($w - (S 20)) (S 12) 'LM'
}

function Draw-Button($g, $r, [string]$text, [bool]$hover) {
    $p = $script:Pal
    if ($hover) { $bg = $p.Hover } else { $bg = $p.Chip }
    $path = New-RoundPath ($r.X + 0.5) ($r.Y + 0.5) ($r.Width - 1) ($r.Height - 1) (S 8)
    $g.FillPath((Get-Brush $bg), $path)
    $g.DrawPath((Get-Pen $p.PanelLine $script:Px1 $false), $path)
    $path.Dispose()
    Draw-Text $g $text $script:Fonts.Chip (Get-Brush $p.Text) $r.X $r.Y $r.Width $r.Height 'CM'
}

function Draw-Ring($g, [double]$x, [double]$y, [double]$size, [double]$pct, [string]$label) {
    $pw = 9.0 * $script:Scale
    $rect = New-Object System.Drawing.RectangleF([single]($x + $pw / 2), [single]($y + $pw / 2), [single]($size - $pw), [single]($size - $pw))
    $g.DrawArc((Get-Pen $script:Pal.Track $pw $true), $rect, 135, 270)
    if ($pct -gt 0.4) {
        $g.DrawArc((Get-Pen (Get-LoadColor $pct) $pw $true), $rect, 135, [single](270.0 * [Math]::Min(100.0, $pct) / 100.0))
    }
    Draw-Text $g ((Fmt $pct '0') + '%') $script:Fonts.Gauge (Get-Brush $script:Pal.Text) $x ($y + $size / 2 - (S 22)) $size (S 30) 'CM'
    Draw-Text $g $label $script:Fonts.Muted (Get-Brush $script:Pal.Muted) $x ($y + $size / 2 + (S 10)) $size (S 14) 'CM'
}

function Draw-Chip($g, [double]$x, [double]$y, [double]$maxRight, [string]$text, $dotColor) {
    $F = $script:Fonts
    $h = (S 22)
    $tw = Text-Width $g $text $F.Chip
    $w = [Math]::Min($tw + (S 26), $maxRight - $x)
    if ($w -lt (S 30)) { return $maxRight }
    Fill-Pill $g (Get-Brush $script:Pal.Chip) $x $y $w $h
    $d = (S 7)
    $g.FillEllipse((Get-Brush $dotColor), [single]($x + (S 9)), [single]($y + ($h - $d) / 2), [single]$d, [single]$d)
    Draw-Text $g $text $F.Chip (Get-Brush $script:Pal.Text) ($x + (S 20)) $y ($w - (S 24)) $h 'LM'
    return ($x + $w + (S 6))
}

function Get-NiceMax([double]$v, [double]$minV) {
    $v = [Math]::Max($v * 1.1, $minV)
    $mag = [Math]::Pow(10, [Math]::Floor([Math]::Log10($v)))
    foreach ($m in 1.0, 2.0, 2.5, 5.0, 10.0) { if ($v -le $m * $mag) { return ($m * $mag) } }
    return (10.0 * $mag)
}

function Get-Peak([double[]]$a) {
    $m = 0.0
    foreach ($v in $a) { if ($v -gt $m) { $m = $v } }
    return $m
}

function Draw-Graph($g, [double]$x, [double]$y, [double]$w, [double]$h, $series, [double]$maxV) {
    $n = 120
    $gp = Get-Pen $script:Pal.PanelLine $script:Px1 $false
    for ($i = 0; $i -le 4; $i++) {
        $yy = $y + $h - ($h * $i / 4.0)
        $g.DrawLine($gp, [single]$x, [single]$yy, [single]($x + $w), [single]$yy)
    }
    foreach ($k in 1..3) {
        $xx = $x + $w * $k / 4.0
        $g.DrawLine($gp, [single]$xx, [single]$y, [single]$xx, [single]($y + $h))
    }
    foreach ($s in $series) {
        $d = $s.Data
        $cnt = $d.Length
        if ($cnt -lt 2) { continue }
        $pts = New-Object 'System.Drawing.PointF[]' $cnt
        for ($i = 0; $i -lt $cnt; $i++) {
            $px = $x + $w * (($n - $cnt + $i) / ($n - 1.0))
            $v = [Math]::Min($maxV, [Math]::Max(0.0, $d[$i]))
            $py = $y + $h - ($h * $v / $maxV)
            $pts[$i] = New-Object System.Drawing.PointF([single]$px, [single]$py)
        }
        $poly = New-Object 'System.Drawing.PointF[]' ($cnt + 2)
        [Array]::Copy($pts, $poly, $cnt)
        $poly[$cnt] = New-Object System.Drawing.PointF($pts[$cnt - 1].X, [single]($y + $h))
        $poly[$cnt + 1] = New-Object System.Drawing.PointF($pts[0].X, [single]($y + $h))
        $g.FillPolygon((Get-Brush (Alpha $s.Color 55)), $poly)
        $g.DrawLines((Get-Pen $s.Color (1.6 * $script:Scale) $true), $pts)
    }
}

# Panel with title, legend, "max N" label and a graph inside.
function Draw-GraphPanel($g, [double]$x, [double]$y, [double]$w, [double]$h, [string]$title, $series, [double]$maxV, [string]$maxText, $legend) {
    $F = $script:Fonts
    Draw-Panel $g $x $y $w $h $title
    $mut = Get-Brush $script:Pal.Muted
    $rx = $x + $w - (S 10)
    $mw = Text-Width $g $maxText $F.Muted
    Draw-Text $g $maxText $F.Muted $mut ($rx - $mw - (S 2)) ($y + (S 5)) ($mw + (S 4)) (S 14) 'RM'
    $rx = $rx - $mw - (S 12)
    for ($i = $legend.Count - 1; $i -ge 0; $i--) {
        $lg = $legend[$i]
        $tw = Text-Width $g $lg.Text $F.Muted
        Draw-Text $g $lg.Text $F.Muted $mut ($rx - $tw - (S 2)) ($y + (S 5)) ($tw + (S 4)) (S 14) 'RM'
        $sq = (S 7)
        $g.FillEllipse((Get-Brush $lg.Color), [single]($rx - $tw - $sq - (S 5)), [single]($y + (S 12) - $sq / 2), [single]$sq, [single]$sq)
        $rx = $rx - $tw - $sq - (S 14)
    }
    Draw-Graph $g ($x + (S 10)) ($y + (S 24)) ($w - (S 20)) ($h - (S 24) - (S 8)) $series $maxV
}

function Draw-HeaderBar($g, [int]$w) {
    $p = $script:Pal
    $dot = (S 8)
    $g.FillEllipse((Get-Brush $p.Teal), $script:Pad, [int](($script:HeaderH - $dot) / 2), $dot, $dot)
    $sr = $script:Hit['settings']
    Draw-Text $g 'System Dashboard' $script:Fonts.Title (Get-Brush $p.Text) ($script:Pad + (S 14)) 0 ([Math]::Max([double](S 40), $sr.Left - $script:Pad - (S 18))) $script:HeaderH 'LM'
    $u = $script:Scale
    foreach ($name in 'settings', 'expand', 'min', 'close') {
        $r = $script:Hit[$name]
        $hov = ($script:Hover -eq $name)
        $bgc = $p.Header
        if ($hov) {
            if ($name -eq 'close') { $bgc = $p.CloseHover } else { $bgc = $p.Hover }
            Fill-Round $g (Get-Brush $bgc) $r.X $r.Y $r.Width $r.Height (S 7)
        }
        $cx = $r.X + $r.Width / 2.0; $cy = $r.Y + $r.Height / 2.0
        if ($hov) { $col = $p.Text } else { $col = $p.Muted }
        $pen = Get-Pen $col (1.6 * $u) $true
        if ($name -eq 'settings') {
            $rows = @(@(-5, -3), @(0, 3), @(5, -1))
            foreach ($rw in $rows) {
                $yy = $cy + $rw[0] * $u
                $g.DrawLine($pen, [single]($cx - 6 * $u), [single]$yy, [single]($cx + 6 * $u), [single]$yy)
                $kx = $cx + $rw[1] * $u
                $g.FillEllipse((Get-Brush $bgc), [single]($kx - 2.4 * $u), [single]($yy - 2.4 * $u), [single](4.8 * $u), [single](4.8 * $u))
                $g.DrawEllipse($pen, [single]($kx - 2.4 * $u), [single]($yy - 2.4 * $u), [single](4.8 * $u), [single](4.8 * $u))
            }
        }
        elseif ($name -eq 'expand') {
            if ($script:Settings['Expanded']) { $d1 = 2.0; $d2 = -3.0 } else { $d1 = -2.0; $d2 = 3.0 }
            $pts = New-Object 'System.Drawing.PointF[]' 3
            $pts[0] = New-Object System.Drawing.PointF([single]($cx - 5 * $u), [single]($cy + $d1 * $u))
            $pts[1] = New-Object System.Drawing.PointF([single]$cx, [single]($cy + $d2 * $u))
            $pts[2] = New-Object System.Drawing.PointF([single]($cx + 5 * $u), [single]($cy + $d1 * $u))
            $g.DrawLines($pen, $pts)
        }
        elseif ($name -eq 'min') {
            $g.DrawLine($pen, [single]($cx - 5 * $u), [single]($cy + 3 * $u), [single]($cx + 5 * $u), [single]($cy + 3 * $u))
        }
        else {
            $g.DrawLine($pen, [single]($cx - 4 * $u), [single]($cy - 4 * $u), [single]($cx + 4 * $u), [single]($cy + 4 * $u))
            $g.DrawLine($pen, [single]($cx + 4 * $u), [single]($cy - 4 * $u), [single]($cx - 4 * $u), [single]($cy + 4 * $u))
        }
    }
}

function Paint-Main($g, [int]$w, [int]$h) {
    $p = $script:Pal
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    if ($null -ne $script:AnimBmp) {
        $g.FillRectangle((Get-Brush $p.Bg), 0, 0, $w, $h)
        $g.DrawImageUnscaled($script:AnimBmp, $script:AnimOff.X, $script:AnimOff.Y)
        return
    }
    $script:Hit = @{}
    $path = New-RoundPath 0 0 ($w - 1) ($h - 1) (Get-WinRadius)
    $glass = ($script:Settings['Glass'] -and $script:GlassOk -and $null -ne $script:GlassBmp)
    if ($glass) {
        Paint-Glass $g $path $w $h
        $g.DrawPath((Get-Pen (Alpha ([System.Drawing.Color]::White) 110) $script:Px1 $false), $path)
    } else {
        $g.FillPath((Get-Brush $p.Bg), $path)
        $g.SetClip($path)
        $g.FillRectangle((Get-Brush $p.Header), 0, 0, $w, $script:HeaderH)
        $g.ResetClip()
        $g.DrawPath((Get-Pen $p.Border $script:Px1 $false), $path)
    }
    $path.Dispose()
    Layout-Header $w
    Draw-HeaderBar $g $w
    if ($script:Settings['Expanded']) {
        Paint-Compact $g $w $script:CompactH   # the small view stays exactly as it is, at the top
        Paint-Expanded $g $w $h                # extra details below it
    } else { Paint-Compact $g $w $h }
}

function Paint-Compact($g, [int]$w, [int]$h) {
    $p = $script:Pal; $F = $script:Fonts; $d = $script:Snap
    $m = $script:Pad
    $mut = Get-Brush $p.Muted
    $rx = $m - (S 2)
    $ry = $script:HeaderH + (S 8)
    $chipY = $h - $m - (S 22)
    $availV = $chipY - $ry - (S 4)                                   # height between the header and the chips
    $rs = [Math]::Max((S 108), [Math]::Min($availV - (S 6), (S 190)))
    $rs = [Math]::Min($rs, [Math]::Max((S 108), $w - $m - $rx - (S 14) - (S 190)))   # keep room for the values on the right
    $ry = $ry + [Math]::Max(0, [int](($availV - (S 6) - $rs) / 2))   # centred when the ring cannot grow any more
    Draw-Ring $g $rx $ry $rs $d.Cpu 'CPU'

    $px = $rx + $rs + (S 14)
    $pw = $w - $m - $px
    $rowH = $rs / 3.0
    $vw = (S 80)
    if ($d.Gpu -ge 0) { $gv = ((Fmt $d.Gpu '0') + '%'); $gc = Get-LoadColor $d.Gpu; $gs = '' } else { $gv = 'N/A'; $gc = $p.Off; $gs = 'no GPU counter' }
    if ($d.Gpu -ge 0 -and $d.GpuMem -ge 0) { $gs = 'VRAM ' + (Format-Size $d.GpuMem) }
    $rows = @(
        @{ L = 'GPU'; V = $gv; C = $gc; S = $gs },
        @{ L = 'RAM'; V = ((Fmt $d.MemPct '0') + '%'); C = (Get-LoadColor $d.MemPct); S = ((Format-Size $d.MemUsed) + ' / ' + (Format-Size $d.MemTotal)) },
        @{ L = 'Disk'; V = ((Fmt $d.DiskPct '0') + '%'); C = (Get-LoadColor $d.DiskPct); S = ('R ' + (Format-Speed $d.DiskRead) + '  W ' + (Format-Speed $d.DiskWrite)) }
    )
    for ($i = 0; $i -lt 3; $i++) {
        $r = $rows[$i]
        $y = $ry + $i * $rowH
        if ($i -gt 0) { $g.DrawLine((Get-Pen $p.PanelLine $script:Px1 $false), [single]$px, [single]($y - 1), [single]($px + $pw), [single]($y - 1)) }
        Draw-Text $g $r.L $F.Muted $mut $px ($y + (S 3)) (S 60) (S 14) 'LT'
        Draw-Text $g $r.S $F.Muted $mut $px ($y + (S 17)) ($pw - $vw) (S 14) 'LT'
        Draw-Text $g $r.V $F.Tile (Get-Brush $r.C) ($px + $pw - $vw) $y $vw $rowH 'RM'
    }

    $cy = $h - $m - (S 22)
    $cx = $m
    if ($d.NetName -ne '') { $dc = $p.Teal; $uc = $p.Blue } else { $dc = $p.Off; $uc = $p.Off }
    $cx = Draw-Chip $g $cx $cy ($w - $m) ($script:ArrowDown + ' ' + (Format-Speed $d.Down)) $dc
    $cx = Draw-Chip $g $cx $cy ($w - $m) ($script:ArrowUp + ' ' + (Format-Speed $d.Up)) $uc
    $wf = $script:Wifi
    if ([bool]$script:Settings['WifiEnabled'] -and $wf.Connected) {
        if ($wf.IsWifi -and [int]$wf.Signal -ge 0 -and [string]$wf.Ssid) {
            $nm = [string]$wf.Ssid
            if ($nm.Length -gt 14) { $nm = $nm.Substring(0, 14) }
            [void](Draw-Chip $g $cx $cy ($w - $m) ($nm + '  ' + [string]$wf.Signal + '%') (Get-SignalColor ([int]$wf.Signal)))
        } elseif (-not $wf.IsWifi) {
            $lt = 'Ethernet'
            $ls2 = Format-LinkSpeed ([double]$wf.LinkSpeed)
            if ($ls2) { $lt += '  ' + $ls2 }
            [void](Draw-Chip $g $cx $cy ($w - $m) $lt $script:Pal.Teal)
        }
    }
}

function Paint-Expanded($g, [int]$w, [int]$h) {
    $p = $script:Pal; $F = $script:Fonts; $d = $script:Snap; $gr = $script:Gr
    $m = $script:Pad; $x = $m; $cw = $w - 2 * $m
    $gap = (S 6)
    $y = $script:CompactH + (S 2)
    $footH = (S 26)
    $limit = $h - $m - $footH - $gap
    $mut = Get-Brush $p.Muted
    $txt = Get-Brush $p.Text

    Draw-Tabs $g $x $y $cw
    $y += (S 30)
    if ([string]$script:Settings['ExpandedTab'] -eq 'Network') { Paint-WifiPage $g $x $y $cw $h; return }

    # --- the page fills the window: spare height goes to the top-process list and the two graphs
    $y0 = $y; $viewBottom = $limit
    $dn = [Math]::Max(1, [Math]::Min(6, @($d.Drives).Count))
    $hCpu = (S 150); $hMem = (S 118); $hProc = (S 76)
    $hDrv = (S 28) + $dn * (S 18)
    $hBat = 0; $nPan = 5
    if ($script:Battery.Present) { $hBat = (S 36); $nPan++ }
    $hCores = 0
    if ($d.Cores.Length -gt 0) { $hCores = (S 44); $nPan++ }
    $need = $hCpu + $hMem + (S 30) + $hBat + $hCores + $hDrv + $hProc + $nPan * $gap
    $extra = ($limit + $gap - $y) - $need
    if ($extra -gt 0) {
        $rowsMore = [Math]::Min(3, [int][Math]::Floor($extra * 0.4 / (S 16)))
        $hProc += $rowsMore * (S 16)
        $extra -= $rowsMore * (S 16)
        $addCpu = [int][Math]::Floor($extra * 0.6)
        $hCpu += $addCpu
        $hMem += ($extra - $addCpu)
    }
    # too small for everything: keep the normal sizes and let the page scroll with the mouse wheel
    $scrollMode = ($extra -lt 0)
    $contentH = $need - $gap
    if ($scrollMode) {
        $viewH = $viewBottom - $y0
        $script:SysMax = [Math]::Max(0.0, $contentH - $viewH)
        if ($script:SysScroll -gt $script:SysMax) { $script:SysScroll = $script:SysMax }
        if ($script:SysScroll -lt 0) { $script:SysScroll = 0.0 }
        $y = $y0 - $script:SysScroll
        $limit = 1000000
        $gstate = $g.Save()
        $g.SetClip((New-Object System.Drawing.RectangleF([single]0, [single]$y0, [single]$w, [single]$viewH)))
    } else { $script:SysScroll = 0.0; $script:SysMax = 0.0 }
    $script:SysRect = New-Object System.Drawing.Rectangle(0, [int]$y0, [int]$w, [int]($viewBottom - $y0))
    # --- CPU / GPU graph
    $sh = $hCpu
    if ($y + $sh -le $limit) {
        $series = @(@{ Data = $gr.Cpu; Color = $p.Teal })
        $legend = @(@{ Text = 'CPU'; Color = $p.Teal })
        $peak = Get-Peak $gr.Cpu
        if ($d.Gpu -ge 0) {
            $series += @{ Data = $gr.Gpu; Color = $p.Blue }
            $legend += @{ Text = 'GPU'; Color = $p.Blue }
            $peak = [Math]::Max($peak, (Get-Peak $gr.Gpu))
        }
        $mx = [Math]::Min(100.0, (Get-NiceMax $peak 10.0))
        Draw-GraphPanel $g $x $y $cw $sh 'CPU / GPU  2 min' $series $mx ('max ' + (Fmt $mx '0') + '%') $legend
        $y += $sh + $gap
    }
    # --- memory graph
    $sh = $hMem
    if ($y + $sh -le $limit) {
        $mx = [Math]::Min(100.0, (Get-NiceMax (Get-Peak $gr.Mem) 10.0))
        Draw-GraphPanel $g $x $y $cw $sh ('Memory  ' + (Format-Size $d.MemUsed) + ' / ' + (Format-Size $d.MemTotal)) @(@{ Data = $gr.Mem; Color = $p.Teal }) $mx ('max ' + (Fmt $mx '0') + '%') @()
        $y += $sh + $gap
    }
    # --- uptime (the other values are already in the small view above)
    $sh = (S 30)
    if ($y + $sh -le $limit) {
        Draw-Panel $g $x $y $cw $sh ''
        Draw-Text $g 'Uptime' $F.Muted $mut ($x + (S 10)) $y (S 60) $sh 'LM'
        Draw-Text $g ((Format-Uptime $d.Boot) + '   (since ' + $d.Boot.ToString('MM-dd HH:mm', $script:Inv) + ')') $F.PanelTitle $txt ($x + (S 70)) $y ($cw - (S 80)) $sh 'LM'
        $y += $sh + $gap
    }
    # --- battery (laptops only)
    $sh = (S 36)
    if ($script:Battery.Present -and ($y + $sh -le $limit)) { Draw-BatteryPanel $g $x $y $cw $sh; $y += $sh + $gap }
    # --- per-core bars
    $sh = (S 44)
    if ($y + $sh -le $limit -and $d.Cores.Length -gt 0) {
        Draw-Panel $g $x $y $cw $sh 'Cores'
        $n = $d.Cores.Length
        $bx = $x + (S 10); $bw = $cw - (S 20)
        $by = $y + (S 22); $bh = $sh - (S 22) - (S 6)
        $bg = [Math]::Max(1, [int](S 2))
        $each = [Math]::Max(2.0, ($bw - ($n - 1) * $bg) / [double]$n)
        for ($i = 0; $i -lt $n; $i++) {
            $cx = $bx + $i * ($each + $bg)
            if ($cx + $each -gt $bx + $bw + 1) { break }
            $g.FillRectangle((Get-Brush $p.Track), [single]$cx, [single]$by, [single]$each, [single]$bh)
            $fh = $bh * [Math]::Min(100.0, $d.Cores[$i]) / 100.0
            if ($fh -ge 1) { $g.FillRectangle((Get-Brush (Get-LoadColor $d.Cores[$i])), [single]$cx, [single]($by + $bh - $fh), [single]$each, [single]$fh) }
        }
        $y += $sh + $gap
    }
    # --- drives
    $sh = $hDrv
    if ($y + $sh -le $limit) {
        Draw-Panel $g $x $y $cw $sh 'Drives'
        $drives = @($d.Drives)
        $rowH = (S 18)
        $maxRows = [int][Math]::Floor(($sh - (S 24)) / $rowH)
        $shown = [Math]::Min($drives.Count, $maxRows)
        for ($i = 0; $i -lt $shown; $i++) {
            $dr = $drives[$i]
            $ry = $y + (S 22) + $i * $rowH
            $usedPct = 0.0
            if ($dr.Total -gt 0) { $usedPct = ($dr.Total - $dr.Free) / $dr.Total * 100.0 }
            Draw-Text $g $dr.Name $F.PanelTitle $txt ($x + (S 10)) $ry (S 36) (S 13) 'LM'
            Draw-Text $g ((Format-Size $dr.Free) + ' free of ' + (Format-Size $dr.Total)) $F.Muted $mut ($x + (S 46)) $ry ($cw - (S 56)) (S 13) 'RM'
            $bx = $x + (S 10); $bw = $cw - (S 20); $bh = [Math]::Max(2, (S 3)); $byy = $ry + (S 14)
            $g.FillRectangle((Get-Brush $p.Track), [single]$bx, [single]$byy, [single]$bw, [single]$bh)
            $g.FillRectangle((Get-Brush (Get-LoadColor $usedPct)), [single]$bx, [single]$byy, [single]($bw * $usedPct / 100.0), [single]$bh)
        }
        if ($drives.Count -gt $shown) { Draw-Text $g ('+' + ($drives.Count - $shown) + ' more') $F.Muted $mut ($x + (S 60)) ($y + (S 4)) ($cw - (S 70)) (S 14) 'RM' }
        $y += $sh + $gap
    }
    # --- top processes
    $sh = $hProc
    $maxProcRows = [Math]::Max(1, [int][Math]::Floor(($sh - (S 24)) / (S 16)))
    if ($y + $sh -le $limit) {
        Draw-Panel $g $x $y $cw $sh 'Top processes'
        $colW = [int](($cw - (S 30)) / 2)
        for ($c = 0; $c -lt 2; $c++) {
            $cx = $x + (S 10) + $c * ($colW + (S 10))
            if ($c -eq 0) { $list = @($d.TopCpu); $hd = 'by CPU' } else { $list = @($d.TopRam); $hd = 'by RAM' }
            Draw-Text $g $hd $F.Muted $mut ($x + $cw - (S 10) - (S 60) - $(if ($c -eq 0) { $colW + (S 10) } else { 0 })) ($y + (S 5)) (S 60) (S 14) 'RM'
            for ($i = 0; $i -lt [Math]::Min($maxProcRows, $list.Count); $i++) {
                $it = $list[$i]
                $ry = $y + (S 22) + $i * (S 16)
                if ($c -eq 0) { $vt = ((Fmt $it.Value '0.0') + '%') } else { $vt = (Format-Size $it.Value) }
                Draw-Text $g $it.Name $F.Muted $txt $cx $ry ($colW - (S 56)) (S 14) 'LM'
                Draw-Text $g $vt $F.Muted $mut ($cx + $colW - (S 56)) $ry (S 56) (S 14) 'RM'
            }
        }
        $y += $sh + $gap
    }
    if ($scrollMode) {
        $g.Restore($gstate)
        if ($script:SysMax -gt 0) {
            $trackH = $viewBottom - $y0
            $thumbH = [Math]::Max([double](S 24), $trackH * $trackH / $contentH)
            $thumbY = $y0 + ($trackH - $thumbH) * $script:SysScroll / $script:SysMax
            $g.FillRectangle((Get-Brush ([System.Drawing.Color]::FromArgb(120, 138, 155, 176))), [single]($w - (S 11)), [single]$thumbY, [single](S 3), [single]$thumbH)
        }
    }
    # --- footer buttons
    $fy = $h - $m - $footH
    $bw2 = [int](($cw - $gap) / 2)
    $script:Hit['hist'] = New-Object System.Drawing.Rectangle($x, $fy, $bw2, $footH)
    $script:Hit['alerts'] = New-Object System.Drawing.Rectangle(($x + $bw2 + $gap), $fy, ($cw - $bw2 - $gap), $footH)
    Draw-Button $g $script:Hit['hist'] 'View history' ($script:Hover -eq 'hist')
    Draw-Button $g $script:Hit['alerts'] 'Open alerts log' ($script:Hover -eq 'alerts')
}

# ---------------------------------------------------------------- popup (toast)
function Hide-Popup {
    try {
        if ($null -ne $script:PopRepaintTimer) { $script:PopRepaintTimer.Stop() }
        if ($null -ne $script:PopHideTimer) { $script:PopHideTimer.Stop() }
        if ($null -ne $script:Popup -and $script:Popup.Visible) { $script:Popup.Hide() }
    } catch { Log-Once 'Hide-Popup' $_.Exception.Message }
}

function Ensure-Popup {
    if ($null -ne $script:Popup) { return }
    $pf = New-Object PopupForm
    $pf.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $pf.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $pf.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $pf.ShowInTaskbar = $false
    $pf.TopMost = $true
    $pf.Size = New-Object System.Drawing.Size((S 348), (S 136))
    $pf.BackColor = $script:Pal.Bg
    $rp = New-RoundPath 0 0 $pf.Width $pf.Height (S 14)
    $pf.Region = New-Object System.Drawing.Region($rp)
    $rp.Dispose()
    $pf.Add_Paint({ param($s, $e) try { Paint-Popup $e.Graphics $s.ClientSize.Width $s.ClientSize.Height } catch { Log-Once 'Popup paint' (Err-Text $_) } })
    $pf.Add_MouseMove({ param($s, $e) try {
        $h = $null
        foreach ($k in @($script:PopHit.Keys)) { if ($script:PopHit[$k].Contains($e.Location)) { $h = $k } }
        if ($h -ne $script:PopHover) {
            $script:PopHover = $h
            if ($null -ne $h) { $s.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $s.Cursor = [System.Windows.Forms.Cursors]::Default }
            $s.Invalidate()
        }
    } catch { Log-Once 'Popup move' (Err-Text $_) } })
    $pf.Add_MouseUp({ param($s, $e) try {
        foreach ($k in @($script:PopHit.Keys)) { if ($script:PopHit[$k].Contains($e.Location)) { Invoke-PopupAction ([string]$k); break } }
    } catch { Log-Once 'Popup up' (Err-Text $_) } })

    $rt = New-Object System.Windows.Forms.Timer
    $rt.Interval = 200
    $rt.Add_Tick({ try {
        $script:PopRepaints = $script:PopRepaints + 1
        if ($null -ne $script:Popup -and $script:Popup.Visible) { $script:Popup.Invalidate(); $script:Popup.Update() }
        if ($script:PopRepaints -ge 6) { $script:PopRepaintTimer.Stop() }
    } catch { Log-Once 'Popup repaint' (Err-Text $_) } })
    $script:PopRepaintTimer = $rt

    $ht = New-Object System.Windows.Forms.Timer
    $ht.Interval = 20000
    $ht.Add_Tick({ try { Hide-Popup } catch { Log-Once 'Popup autohide' (Err-Text $_) } })
    $script:PopHideTimer = $ht
    $script:Popup = $pf
}

function Place-Popup {
    $pf = $script:Popup
    $pw = $pf.Width; $ph = $pf.Height
    $wr = Get-WidgetRect
    $screen = [System.Windows.Forms.Screen]::FromRectangle($wr)
    $wa = $screen.WorkingArea
    $gap = (S 8)
    $leftSide = (($wr.Left + $wr.Width / 2) -lt ($wa.Left + $wa.Width / 2))
    if ($leftSide) { $x = $wr.Left } else { $x = $wr.Right - $pw }
    if ($leftSide) { $bx = $wr.Right + $gap } else { $bx = $wr.Left - $pw - $gap }
    $cands = @(
        (New-Object System.Drawing.Point($x, ($wr.Top - $ph - $gap))),   # above
        (New-Object System.Drawing.Point($bx, $wr.Top)),                 # beside
        (New-Object System.Drawing.Point($x, ($wr.Bottom + $gap)))       # below
    )
    $chosen = $null
    foreach ($c in $cands) {
        $r = New-Object System.Drawing.Rectangle($c.X, $c.Y, $pw, $ph)
        if ($wa.Contains($r)) { $chosen = $c; break }
    }
    if ($null -eq $chosen) { $chosen = $cands[0] }
    $px = [Math]::Max($wa.Left, [Math]::Min($chosen.X, $wa.Right - $pw))
    $py = [Math]::Max($wa.Top, [Math]::Min($chosen.Y, $wa.Bottom - $ph))
    $pf.Location = New-Object System.Drawing.Point($px, $py)
}

function Show-TestPopup {
    $a = [pscustomobject]@{
        Title = 'High CPU usage (test)'; Value = 93.0
        Lines = @(('Threshold: ' + $script:Settings['CpuThreshold'] + '%'), ('Sustained for ' + $script:Settings['SustainedSec'] + ' s'), 'Top process: example.exe (41%)')
    }
    Show-AlertPopup $a
    Write-Log 'Test popup shown'
}

# ---------------------------------------------------------------- alerts
function Purge-Alerts([string]$key) {
    $keep = New-Object System.Collections.ArrayList
    foreach ($q in $script:AlertQueue.ToArray()) {
        $drop = $false
        if ($q -is [hashtable]) {
            if (($key -eq 'AlertSpeed' -and $q.Type -eq 'speed') -or ($key -eq 'AlertDns' -and $q.Type -eq 'dns') -or ($key -eq 'DeviceAlerts' -and $q.Type -eq 'device') -or ($key -eq 'AlertOutage' -and $q.Type -eq 'outage') -or ($key -eq 'AlertData' -and $q.Type -eq 'data')) { $drop = $true }
        } else {
            $t = [string]$q.Title
            if (($key -eq 'AlertCpu' -and $t -like 'High CPU*') -or ($key -eq 'AlertGpu' -and $t -like 'High GPU*') -or ($key -eq 'AlertRam' -and $t -like 'High memory*') -or ($key -eq 'AlertDisk' -and $t -like 'Low disk*') -or ($key -eq 'AlertBattery' -and $t -like 'Battery low*')) { $drop = $true }
        }
        if (-not $drop) { [void]$keep.Add($q) }
    }
    $script:AlertQueue.Clear()
    foreach ($q in $keep) { $script:AlertQueue.Enqueue($q) }
}

function Reset-Alerts {
    foreach ($k in @('CPU', 'GPU', 'RAM')) { $script:AlertState[$k]['Since'] = $null }
    $script:AlertQueue.Clear()
}

function Queue-Alert([string]$metric, [double]$val, [double]$thr, [double]$dur, $snap) {
    $top = ''; $topText = ''
    if ($metric -eq 'CPU') {
        $t = @($snap.TopCpu)
        if ($t.Count -gt 0) { $top = [string]$t[0].Name; $topText = $top + ' (' + (Fmt $t[0].Value '0') + '%)' }
        $title = 'High CPU usage'
    } elseif ($metric -eq 'RAM') {
        $t = @($snap.TopRam)
        if ($t.Count -gt 0) { $top = [string]$t[0].Name; $topText = $top + ' (' + (Format-Size $t[0].Value) + ')' }
        $title = 'High memory usage'
    } else {
        if ($snap.GpuTop) { $top = [string]$snap.GpuTop; $topText = $top }
        $title = 'High GPU usage'
    }
    if (-not $topText) { $topText = 'unknown' }
    $a = [pscustomobject]@{
        Title = $title; Value = $val
        Lines = @(('Threshold: ' + (Fmt $thr '0') + '%'), ('Sustained for ' + (Fmt $dur '0') + ' s'), ('Top process: ' + $topText))
    }
    $script:AlertQueue.Enqueue($a)
    Write-Log ('ALERT ' + $metric + ' ' + (Fmt $val '0.0') + '% (threshold ' + (Fmt $thr '0') + '%) for ' + (Fmt $dur '0') + ' s, top=' + $top)
    $line = (@((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $metric, (Fmt $val '0.0'), (Fmt $thr '0'), (Csv-Field $top)) -join ',')
    $ok = $script:AlertCsv.Write($script:AlertsPath, $line)
    if (-not $ok -and -not $script:AlertFailing) {
        $script:AlertFailing = $true
        Write-Log ('alerts.csv not writable, keeping rows in memory: ' + $script:AlertCsv.LastError)
    } elseif ($ok -and $script:AlertFailing) {
        $script:AlertFailing = $false
        Write-Log 'alerts.csv writable again'
    }
}

function Eval-Alerts($snap) {
    if (-not $script:Settings['AlertsEnabled']) { return }
    $now = Get-Date
    if (($now - $script:StartTime).TotalSeconds -lt 45) { Reset-Alerts; return }
    $checks = @(
        @{ K = 'CPU'; V = [double]$snap.Cpu;    T = [double]$script:Settings['CpuThreshold']; E = [bool]$script:Settings['AlertCpu'] },
        @{ K = 'GPU'; V = [double]$snap.Gpu;    T = [double]$script:Settings['GpuThreshold']; E = [bool]$script:Settings['AlertGpu'] },
        @{ K = 'RAM'; V = [double]$snap.MemPct; T = [double]$script:Settings['MemThreshold']; E = [bool]$script:Settings['AlertRam'] }
    )
    foreach ($c in $checks) {
        $st = $script:AlertState[$c.K]
        if (-not $c.E) { $st['Since'] = $null; continue }
        if ($c.V -lt 0 -or $c.V -lt $c.T) { $st['Since'] = $null; continue }
        if ($null -eq $st['Since']) { $st['Since'] = $now }
        $dur = ($now - $st['Since']).TotalSeconds
        if ($dur -ge [double]$script:Settings['SustainedSec'] -and ($now - $st['Last']).TotalSeconds -ge [double]$script:Settings['CooldownSec']) {
            $st['Last'] = $now
            Queue-Alert $c.K $c.V $c.T $dur $snap
        }
    }
    $dthr = [double]$script:Settings['DiskFreePct']
    if ($dthr -gt 0 -and [bool]$script:Settings['AlertDisk']) {
        foreach ($dr in @($snap.Drives)) {
            if ($dr.Total -le 0) { continue }
            $free = $dr.Free / $dr.Total * 100.0
            if ($free -ge $dthr) { continue }
            $last = $script:DiskLast[$dr.Name]
            if ($null -ne $last -and ($now - $last).TotalMinutes -lt 60) { continue }
            $script:DiskLast[$dr.Name] = $now
            Queue-DiskAlert $dr $free $dthr
        }
    }
}

function Append-AlertRow([string]$metric, [double]$val, [double]$thr, [string]$top) {
    $line = (@((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $metric, (Fmt $val '0.0'), (Fmt $thr '0'), (Csv-Field $top)) -join ',')
    $ok = $script:AlertCsv.Write($script:AlertsPath, $line)
    if (-not $ok -and -not $script:AlertFailing) { $script:AlertFailing = $true; Write-Log ('alerts.csv not writable, keeping rows in memory: ' + $script:AlertCsv.LastError) }
    elseif ($ok -and $script:AlertFailing) { $script:AlertFailing = $false; Write-Log 'alerts.csv writable again' }
}

function Queue-DiskAlert($dr, [double]$free, [double]$thr) {
    $a = [pscustomobject]@{
        Title = ('Low disk space (' + $dr.Name + ')'); Value = (100.0 - $free); ValueText = ((Fmt $free '0') + '% free')
        Lines = @(('Threshold: below ' + (Fmt $thr '0') + '% free'), ('Free: ' + (Format-Size $dr.Free) + ' of ' + (Format-Size $dr.Total)), ('Drive: ' + $dr.Name))
    }
    $script:AlertQueue.Enqueue($a)
    Write-Log ('ALERT DISK ' + $dr.Name + ' ' + (Fmt $free '0.0') + '% free (threshold ' + (Fmt $thr '0') + '%)')
    Append-AlertRow 'DISK' $free $thr ([string]$dr.Name)
}

# ---------------------------------------------------------------- window features
function Apply-ClickThrough {
    $fm = $script:Form
    $on = [bool]$script:Settings['ClickThrough']
    $fm.ClickThrough = $on
    if (-not $fm.IsHandleCreated) { return }
    if ($on) { $fm.Opacity = 0.999 } elseif (-not $script:Settings['Glass']) { $fm.Opacity = 1.0 }
    $ex = [Native]::GetWindowLong($fm.Handle, -20)
    if ($on) { $ex = $ex -bor 0x20 } else { $ex = $ex -band (-bnot 0x20) }
    [void][Native]::SetWindowLong($fm.Handle, -20, $ex)
    Write-Log ('Click-through ' + $(if ($on) { 'on (a second start of the .bat turns it off)' } else { 'off' }))
}

function Disable-ClickThroughIfOn {
    if ([bool]$script:Settings['ClickThrough']) { Set-Setting 'ClickThrough' $false }
}

function Set-AutoHidden([bool]$hide) {
    $fm = $script:Form
    $script:AutoHidden = $hide
    Update-Badge
    if ($hide) {
        Hide-Popup
        [void][Native]::ShowWindow($fm.Handle, 0)
        Write-Log 'Hidden: a fullscreen app is active'
    } else {
        if (-not $script:Backgrounded) {
            [void][Native]::ShowWindow($fm.Handle, 4)
            $fm.Invalidate()
            Update-Glass
        }
        Write-Log 'Shown again: fullscreen app ended'
    }
}

function Check-Fullscreen {
    if (-not $script:Settings['AutoHideFullscreen']) {
        if ($script:AutoHidden) { Set-AutoHidden $false }
        return
    }
    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
    $fs = [Native]::IsFullscreenForeground()
    if ($fs -and -not $script:AutoHidden) { Set-AutoHidden $true }
    elseif (-not $fs -and $script:AutoHidden) { Set-AutoHidden $false }
}

function Reset-Popup {
    try { Hide-Popup } catch { }
    foreach ($t in @($script:PopRepaintTimer, $script:PopHideTimer)) { try { if ($null -ne $t) { $t.Stop(); $t.Dispose() } } catch { } }
    $script:PopRepaintTimer = $null; $script:PopHideTimer = $null
    if ($null -ne $script:Popup) { try { $script:Popup.Dispose() } catch { }; $script:Popup = $null }
}

function Apply-UiScale {
    if ($script:ResizeAnim.Active) { return }
    $script:Scale = $script:DpiScale * [double]$script:Settings['UiScale']
    Update-Metrics
    Build-Fonts
    Clear-GdiCache
    Reset-Popup
    Reset-Badge
    Apply-Layout
    Update-Badge
    Write-Log ('UI scale applied: ' + (Fmt $script:Scale '0.00'))
}

# ---------------------------------------------------------------- periodic work (UI thread)
function Update-GraphData {
    $h = $script:Shared['History']
    if ($null -eq $h) { return }
    $n = $h.Length
    if ($n -lt 1) { return }
    $cpu = New-Object 'double[]' $n; $gpu = New-Object 'double[]' $n; $mem = New-Object 'double[]' $n
    $dn = New-Object 'double[]' $n; $up = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $s = $h[$i]
        $cpu[$i] = [double]$s.Cpu; $gpu[$i] = [Math]::Max(0.0, [double]$s.Gpu); $mem[$i] = [double]$s.Mem
        $dn[$i] = [double]$s.Down; $up[$i] = [double]$s.Up
    }
    $script:Gr = @{ Cpu = $cpu; Gpu = $gpu; Mem = $mem; Down = $dn; Up = $up }
}

function Main-Tick {
    $script:TickCount = $script:TickCount + 1
    Drain-Events
    try { Update-Battery; Eval-Battery } catch { Log-Once 'Battery' $_.Exception.Message }
    $idleNow = $false
    if ($script:Settings['PauseWhenIdle']) { $idleNow = ([Native]::IdleSeconds() -ge ([double]$script:Settings['IdleMinutes'] * 60.0)) }
    if ($idleNow -ne $script:Idle) {
        $script:Idle = $idleNow
        $script:Shared['Cfg']['Idle'] = $idleNow
        Write-Log ('Idle mode ' + $(if ($idleNow) { 'on (sampling every 5 s)' } else { 'off' }))
        if (-not $idleNow) { $script:Form.Invalidate() }
    }
    $snap = $script:Shared['Snap']
    if ($null -ne $snap -and $snap.Seq -ne $script:Snap.Seq) {
        $script:Snap = $snap
        Update-GraphData
        Eval-Alerts $snap
        try { Refresh-Badge } catch { }
    }
    Pump-Popups
    if ($script:AlertCsv.PendingCount -gt 0 -and ($script:TickCount % 10) -eq 0) {
        $ok = $script:AlertCsv.Flush($script:AlertsPath)
        if ($ok -and $script:AlertFailing) { $script:AlertFailing = $false; Write-Log 'alerts.csv writable again' }
    }
    $fm = $script:Form
    if ($fm.Visible -and $fm.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized -and -not $script:Dragging -and -not $script:Anim.Active -and -not $script:ResizeAnim.Active -and -not $script:AutoHidden -and -not $script:Idle) {
        $fm.Invalidate()
    }
}

function Check-Screens {
    $sig = Get-ScreenSig
    if ($sig -eq $script:ScreenSig) { return }
    $script:ScreenSig = $sig
    Write-Log 'Screen layout changed'
    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or $script:Dragging -or $script:Anim.Active -or $script:ResizeAnim.Active) { $script:PendingResnap = $true; return }
    Apply-Layout
}

# ---------------------------------------------------------------- history + log web page
$script:HistoryHtml = Join-Path $script:DataDir 'history.html'
$script:AlertsHtml = Join-Path $script:DataDir 'alerts.html'
$script:HistoryPending = $false
$script:PendingPath = ''
$script:HistoryTemplate = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>System Dashboard - History and Log</title>
<style>
/*THEME*/
*{box-sizing:border-box}
html,body{margin:0}
body{background:var(--bg);color:var(--text);font:14px/1.45 "Segoe UI",system-ui,-apple-system,sans-serif;min-height:100vh}
.wrap{max-width:1120px;margin:0 auto;padding:16px 16px 40px}
.top{background:var(--header);border:1px solid var(--border);border-radius:16px;padding:12px 16px;display:flex;align-items:center;gap:14px;flex-wrap:wrap;position:sticky;top:10px;z-index:5;box-shadow:0 8px 24px rgba(0,0,0,.28)}
.dot{width:10px;height:10px;border-radius:50%;background:var(--teal)}
.title{font-weight:600;font-size:16px}
.sub{color:var(--muted);font-size:12px}
.sp{flex:1}
.tabs,.seg{display:flex;gap:4px;background:var(--chip);border:1px solid var(--panelline);border-radius:999px;padding:3px}
.tabs button,.seg button{background:none;border:0;color:var(--muted);padding:6px 14px;border-radius:999px;font:inherit;cursor:pointer}
.tabs button:hover,.seg button:hover{color:var(--text);background:var(--hover)}
.tabs button.on,.seg button.on{background:var(--teal);color:#06231f;font-weight:600}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:10px;margin:14px 0}
.tile,.card{background:var(--panel);border:1px solid var(--panelline);border-radius:12px}
.tile{padding:10px 14px}
.tile .l{color:var(--muted);font-size:12px}
.tile .v{font-size:22px;font-weight:600;margin-top:2px}
.tile .s{color:var(--muted);font-size:12px}
.card{padding:12px 14px 10px;margin-bottom:12px}
.ch{display:flex;align-items:center;gap:10px;margin-bottom:6px}
.ch b{font-weight:600}
.leg{display:flex;gap:12px;color:var(--muted);font-size:12px;margin-left:auto}
.leg i{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px}
.cv{position:relative}
canvas{width:100%;height:180px;display:block}
.tip{position:absolute;pointer-events:none;background:var(--header);border:1px solid var(--border);border-radius:8px;padding:6px 9px;font-size:12px;white-space:nowrap;display:none;z-index:3;box-shadow:0 6px 18px rgba(0,0,0,.35)}
.empty{color:var(--muted);text-align:center;padding:36px 0}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--panelline)}
th{color:var(--muted);font-weight:500;font-size:12px}
.pill{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:600;color:#10151c}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
.chip{background:var(--chip);border:1px solid var(--panelline);color:var(--muted);border-radius:999px;padding:4px 12px;cursor:pointer;font:inherit;font-size:12px}
.chip.on{color:var(--text);border-color:var(--teal)}
input[type=search]{background:var(--chip);border:1px solid var(--panelline);color:var(--text);border-radius:999px;padding:6px 14px;font:inherit;min-width:220px}
.log{font:12.5px/1.55 Consolas,"Cascadia Mono",monospace;max-height:72vh;overflow:auto}
.log div{padding:1px 6px;border-radius:4px;white-space:pre-wrap;word-break:break-all}
.log div:hover{background:var(--hover)}
.log .e{color:var(--red)}.log .a{color:var(--amber)}.log .s{color:var(--blue)}
.badge{display:inline-block;min-width:46px;text-align:center;border-radius:6px;padding:2px 8px;font-size:11.5px;font-weight:700;letter-spacing:.03em}
.b-PASS{background:rgba(45,212,191,.16);color:var(--teal)}
.b-INFO{background:rgba(96,165,250,.16);color:var(--blue)}
.b-WARN{background:rgba(245,176,65,.2);color:var(--amber)}
.bn ul{margin:8px 0 4px;padding-left:18px}
.bn li{margin:3px 0;color:var(--muted)}
svg{width:100%;height:auto;display:block}
.sp{flex:1}
.bar-note{color:var(--muted);font-size:12px;margin:6px 0}
@media print{
 :root{--bg:#fff;--header:#fff;--border:#bbb;--hover:#eee;--chip:#fff;--track:#ddd;--panel:#fff;--panelline:#bbb;--text:#000;--muted:#444;--teal:#0b7a6c;--blue:#1d4ed8;--amber:#9a5b00;--red:#b91c1c}
 body{background:#fff;color:#000}.top,.noprint{display:none!important}.wrap{max-width:none;padding:0}
 .card{break-inside:avoid;border-color:#bbb}#p_net,#p_alerts,#p_log,#p_over{display:none!important}
}
.hide{display:none}
</style></head><body><div class="wrap">
<div class="top"><span class="dot"></span>
<div><div class="title">System Dashboard</div><div class="sub" id="gen"></div></div>
<span class="sp"></span><div class="seg" id="range"></div><div class="tabs" id="tabs"></div></div>
<div id="p_over"><div class="tiles" id="tiles"></div><div id="charts"></div></div>
<div id="p_net" class="hide"><div class="tiles" id="ntiles"></div><div id="ncharts"></div>
<div class="card"><div class="ch"><b>Outages</b><span class="sub" id="osub"></span></div><div id="otl"></div><div id="otable"></div></div>
<div class="card"><div class="ch"><b>Data usage</b><span class="sub" id="usub"></span></div><div class="tiles" id="utiles"></div><div id="uchart"></div></div>
<div class="card"><div class="ch"><b>Full tests: speed over time</b><div class="leg"><span><i style="background:var(--teal)"></i>Download</span><span><i style="background:var(--blue)"></i>Upload</span></div></div><div id="rc1"></div></div>
<div class="card"><div class="ch"><b>Full tests: delay over time</b><div class="leg"><span><i style="background:var(--teal)"></i>Router</span><span><i style="background:var(--blue)"></i>Internet</span></div></div><div id="rc2"></div></div>
<div class="card"><div class="ch"><b>Latest full test</b><span class="sub" id="fsub"></span></div><div id="fbody"></div></div>
<div class="card"><div class="ch"><b>Speed tests</b><span class="sub">newest first</span></div><div id="stable"></div></div>
<div class="card"><div class="ch"><b>Full test history</b></div><div id="ftable"></div></div>
<div class="card"><div class="ch"><b>Devices on your network</b></div><div id="dtable"></div></div>
<div class="card"><div class="ch"><b>New and returning devices</b></div><div id="evtable"></div></div>
<div class="card"><div class="ch"><b>Nearby Wi-Fi networks</b><span class="sub" id="wsub"></span></div><div id="wadv"></div><div id="wtable"></div></div></div>
<div id="p_report" class="hide"><div class="card"><div class="ch"><b>Report for my internet provider</b><span class="sp"></span><div class="seg noprint" id="rseg"></div><button class="chip noprint" id="rprint">Print / save as PDF</button></div><div id="rbody"></div></div></div>
<div id="p_alerts" class="hide"><div class="tiles" id="atiles"></div><div class="card"><div class="ch"><b>Alerts per day</b><span class="sub">last 14 days</span><div class="leg" id="aleg"></div></div><div class="cv"><canvas id="ac"></canvas><div class="tip" id="act"></div></div></div><div class="card"><div class="bar" id="afilter"></div><div id="atable"></div></div></div>
<div id="p_log" class="hide"><div class="card"><div class="bar" id="lfilter"></div><div class="log" id="logbox"></div></div></div>
</div>
<script>
(function(){
var D = __DATA__;
var $ = function(id){return document.getElementById(id);};
var RANGES=[['1h',3600],['6h',21600],['24h',86400],['7d',604800],['30d',2592000]];
var rangeI=2, tab='__TAB__', aFilter='All', lFilter='All', lText='';
var CH=[
 {id:'c1',title:'CPU and GPU',kind:'pct',s:[['cpu','CPU','--teal'],['gpu','GPU','--blue']]},
 {id:'c2',title:'Memory',kind:'pct',s:[['mem','Memory','--teal']]},
 {id:'c3',title:'Network',kind:'spd',s:[['down','Download','--teal'],['up','Upload','--blue']]},
 {id:'c4',title:'Disk activity',kind:'pct',s:[['disk','Disk','--amber']]}
];
var NCH=[
 {id:'n1',src:'net',title:'Wi-Fi signal',kind:'pct',s:[['sig','Signal','--teal']]},
 {id:'n2',src:'net',title:'Ping (router and internet)',kind:'ms',s:[['rping','Router','--teal'],['iping','Internet','--blue']]},
 {id:'n3',src:'net',title:'Traffic of the active connection',kind:'mbps',s:[['ndown','Download','--teal'],['nup','Upload','--blue']]}
];
function pad(n){return (n<10?'0':'')+n;}
function fmtT(sec,mode){var d=new Date(sec*1000);
 var date=d.getUTCFullYear()+'-'+pad(d.getUTCMonth()+1)+'-'+pad(d.getUTCDate());
 var hm=pad(d.getUTCHours())+':'+pad(d.getUTCMinutes());
 if(mode==='date')return pad(d.getUTCMonth()+1)+'-'+pad(d.getUTCDate());
 if(mode==='full')return date+' '+hm+':'+pad(d.getUTCSeconds());
 return hm;}
function css(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim();}
function hexA(h,a){var v=parseInt(h.replace('#',''),16);return 'rgba('+((v>>16)&255)+','+((v>>8)&255)+','+(v&255)+','+a+')';}
function nice(v){if(v<=0)return 1;var p=Math.pow(10,Math.floor(Math.log(v)/Math.LN10));var m=[1,2,2.5,5,10];
 for(var i=0;i<m.length;i++){if(v<=m[i]*p)return m[i]*p;}return 10*p;}
function fPct(v){return v.toFixed(v<10?1:0)+'%';}
function fSpd(k){return k>=1024?(k/1024).toFixed(k>=10240?0:1)+' MB/s':(k>=10?k.toFixed(0):k.toFixed(1))+' KB/s';}
function fMs(v){return v.toFixed(v<10?1:0)+' ms';}
function fMb(v){return v.toFixed(v<10?1:0)+' Mbps';}
function fmtOf(kind){return kind==='spd'?fSpd:(kind==='ms'?fMs:(kind==='mbps'?fMb:fPct));}
function slice(src){var sec=RANGES[rangeI][1],rt=(src==='net'&&D.net)?D.net:D,ds=sec<=86400?rt.fine:rt.coarse,t1=D.now,t0=t1-sec;
 var i0=Math.max(0,Math.floor((t0-ds.start)/ds.step)),i1=Math.min(ds.n-1,Math.floor((t1-ds.start)/ds.step));
 return {ds:ds,i0:i0,i1:i1,t0:t0,t1:t1,sec:sec};}
function stats(key,src){var r=slice(src),a=r.ds[key],m=r.ds[key+'M'],s=0,n=0,mx=null,i;
 if(!a)return {avg:null,max:null};
 for(i=r.i0;i<=r.i1;i++){if(a[i]!=null){s+=a[i];n++;}if(m[i]!=null&&(mx===null||m[i]>mx))mx=m[i];}
 return {avg:n?s/n:null,max:mx};}
function alertEpoch(s){var m=/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/.exec(s);
 return m?Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5],+m[6])/1000:0;}

function buildTiles(){
 var r=slice(),c=stats('cpu'),g=stats('gpu'),m=stats('mem'),d=stats('down'),u=stats('up'),k=stats('disk'),n=0,i;
 for(i=0;i<D.alerts.length;i++){if(alertEpoch(D.alerts[i][0])>=r.t0)n++;}
 function t(l,v,s){return '<div class="tile"><div class="l">'+l+'</div><div class="v">'+v+'</div><div class="s">'+s+'</div></div>';}
 function p(x){return x===null?'-':fPct(x);} function sp(x){return x===null?'-':fSpd(x);}
 $('tiles').innerHTML=t('CPU average',p(c.avg),'peak '+p(c.max))+
  t('GPU average',g.avg===null?'N/A':p(g.avg),g.avg===null?'no data':'peak '+p(g.max))+
  t('Memory average',p(m.avg),'peak '+p(m.max))+
  t('Download peak',sp(d.max),'average '+sp(d.avg))+
  t('Upload peak',sp(u.max),'average '+sp(u.avg))+
  t('Disk activity',p(k.avg),'peak '+p(k.max))+
  t('Alerts',String(n),'in this range');}

var geo={};
function draw(c,hi){
 var cv=$(c.id),r=slice(c.src),ds=r.ds,dpr=window.devicePixelRatio||1,W=cv.clientWidth,H=cv.clientHeight;
 cv.width=Math.round(W*dpr);cv.height=Math.round(H*dpr);
 var g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
 var L=50,R=8,T=8,B=20,pw=W-L-R,ph=H-T-B,mx=0,i,any=false;
 c.s.forEach(function(s){var a=ds[s[0]];if(!a)return;for(i=r.i0;i<=r.i1;i++){if(a[i]!=null){any=true;if(a[i]>mx)mx=a[i];}}});
 var top=c.kind==='spd'?nice(Math.max(mx*1.1,100)):(c.kind==='ms'?nice(Math.max(mx*1.1,10)):(c.kind==='mbps'?nice(Math.max(mx*1.1,5)):Math.min(100,nice(Math.max(mx*1.1,10)))));
 var fmt=fmtOf(c.kind),muted=css('--muted'),line=css('--panelline');
 g.font='11px "Segoe UI",sans-serif';g.textBaseline='middle';
 for(i=0;i<=4;i++){var y=T+ph-ph*i/4;g.strokeStyle=line;g.lineWidth=1;g.beginPath();g.moveTo(L,y+.5);g.lineTo(L+pw,y+.5);g.stroke();
  g.fillStyle=muted;g.textAlign='right';g.fillText(fmt(top*i/4),L-6,y);}
 g.textAlign='center';g.textBaseline='top';
 for(i=0;i<=4;i++){var tt=r.t0+(r.t1-r.t0)*i/4;g.fillText(fmtT(tt,r.sec>86400*2?'date':'hm'),L+pw*i/4,T+ph+5);}
 var X=function(j){return L+(ds.start+j*ds.step-r.t0)/(r.t1-r.t0)*pw;},Y=function(v){return T+ph-ph*Math.min(v,top)/top;};
 if(!any){g.fillStyle=muted;g.textAlign='center';g.textBaseline='middle';g.fillText('No data in this range',L+pw/2,T+ph/2);geo[c.id]=null;return;}
 c.s.forEach(function(s){var a=ds[s[0]];if(!a)return;var col=css(s[2]),seg=[],j;
  function flush(){if(seg.length>1){g.beginPath();g.moveTo(X(seg[0]),T+ph);for(var q=0;q<seg.length;q++)g.lineTo(X(seg[q]),Y(a[seg[q]]));
    g.lineTo(X(seg[seg.length-1]),T+ph);g.closePath();g.fillStyle=hexA(col,.18);g.fill();
    g.beginPath();for(q=0;q<seg.length;q++){if(q===0)g.moveTo(X(seg[q]),Y(a[seg[q]]));else g.lineTo(X(seg[q]),Y(a[seg[q]]));}
    g.strokeStyle=col;g.lineWidth=1.6;g.lineJoin='round';g.stroke();}
   else if(seg.length===1){g.beginPath();g.arc(X(seg[0]),Y(a[seg[0]]),2,0,6.3);g.fillStyle=col;g.fill();}seg=[];}
  for(j=r.i0;j<=r.i1;j++){if(a[j]==null)flush();else seg.push(j);}flush();});
 if(hi!=null&&hi>=r.i0&&hi<=r.i1){var hx=X(hi);g.strokeStyle=muted;g.lineWidth=1;g.beginPath();g.moveTo(hx+.5,T);g.lineTo(hx+.5,T+ph);g.stroke();
  c.s.forEach(function(s){var a=ds[s[0]];if(a&&a[hi]!=null){g.beginPath();g.arc(hx,Y(a[hi]),3.5,0,6.3);g.fillStyle=css(s[2]);g.fill();}});}
 geo[c.id]={L:L,pw:pw,r:r};}

function tipFor(c,ev){
 var cv=$(c.id),gm=geo[c.id],tip=$(c.id+'t');if(!gm){tip.style.display='none';return;}
 var rect=cv.getBoundingClientRect(),x=ev.clientX-rect.left,r=gm.r,ds=r.ds;
 var t=r.t0+(x-gm.L)/gm.pw*(r.t1-r.t0),i=Math.round((t-ds.start)/ds.step);
 if(x<gm.L||x>gm.L+gm.pw||i<r.i0||i>r.i1){tip.style.display='none';draw(c,null);return;}
 var fmt=fmtOf(c.kind),h='<div style="color:'+css('--muted')+'">'+fmtT(ds.start+i*ds.step,'full')+'</div>',any=false;
 c.s.forEach(function(s){var a=ds[s[0]],m=ds[s[0]+'M'];if(a&&a[i]!=null){any=true;
  h+='<div><i style="display:inline-block;width:8px;height:8px;border-radius:50%;background:'+css(s[2])+';margin-right:6px"></i>'+s[1]+' <b>'+fmt(a[i])+'</b>'+(m&&m[i]!=null?' <span style="color:'+css('--muted')+'">peak '+fmt(m[i])+'</span>':'')+'</div>';}});
 if(!any){tip.style.display='none';return;}
 tip.innerHTML=h;tip.style.display='block';
 var tw=tip.offsetWidth,lx=x+14;if(lx+tw>cv.clientWidth)lx=x-tw-14;tip.style.left=Math.max(0,lx)+'px';tip.style.top='8px';
 draw(c,i);}

function buildCharts(){
 var h='';CH.forEach(function(c){var leg='';c.s.forEach(function(s){leg+='<span><i style="background:var('+s[2]+')"></i>'+s[1]+'</span>';});
  h+='<div class="card"><div class="ch"><b>'+c.title+'</b><div class="leg">'+leg+'</div></div><div class="cv"><canvas id="'+c.id+'"></canvas><div class="tip" id="'+c.id+'t"></div></div></div>';});
 $('charts').innerHTML=h;
 CH.forEach(function(c){var cv=$(c.id);
  cv.addEventListener('mousemove',function(ev){tipFor(c,ev);});
  cv.addEventListener('mouseleave',function(){$(c.id+'t').style.display='none';draw(c,null);});});}
function drawAll(){CH.forEach(function(c){draw(c,null);});}

var MCOL={CPU:'--teal',GPU:'--blue',RAM:'--amber',DISK:'--red'};
function chips(el,list,cur,fn){var h='';list.forEach(function(x){h+='<button class="chip'+(x===cur?' on':'')+'" data-v="'+x+'">'+x+'</button>';});
 el.innerHTML=h;Array.prototype.forEach.call(el.querySelectorAll('button'),function(b){b.addEventListener('click',function(){fn(b.getAttribute('data-v'));});});}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function tile(l,v,s){return '<div class="tile"><div class="l">'+l+'</div><div class="v">'+v+'</div><div class="s">'+s+'</div></div>';}
function buildAlertTiles(){
 var A=D.alerts,by={CPU:0,GPU:0,RAM:0,DISK:0},procs={},i,a,top='-',tn=0,k;
 for(i=0;i<A.length;i++){a=A[i];if(by[a[1]]!==undefined)by[a[1]]++;procs[a[4]]=(procs[a[4]]||0)+1;}
 for(k in procs){if(procs[k]>tn){tn=procs[k];top=k;}}
 $('atiles').innerHTML=tile('Total alerts',String(A.length),'last 300 are kept')+tile('CPU',String(by.CPU),'high usage')+tile('GPU',String(by.GPU),'high usage')+
  tile('Memory',String(by.RAM),'high usage')+tile('Disk space',String(by.DISK),'low free space')+
  tile('Most frequent',esc(top),tn?tn+' times':'')+tile('Latest',A.length?esc(A[A.length-1][0]).replace(' ','<br>'):'-','');
 var lg='';['CPU','GPU','RAM','DISK'].forEach(function(m){lg+='<span><i style="background:var('+MCOL[m]+')"></i>'+m+'</span>';});$('aleg').innerHTML=lg;}
var abars=null,AM=['CPU','GPU','RAM','DISK'];
function drawAlertBars(hi){
 var cv=$('ac');if(!cv||!cv.clientWidth)return;
 var dpr=window.devicePixelRatio||1,W=cv.clientWidth,H=cv.clientHeight;cv.width=Math.round(W*dpr);cv.height=Math.round(H*dpr);
 var g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
 var days=14,today=Math.floor(D.now/86400),cnt=[],i,mx=0;
 for(i=0;i<days;i++)cnt.push({CPU:0,GPU:0,RAM:0,DISK:0,t:0});
 D.alerts.forEach(function(a){var d=today-dayOf(a[0]);if(d>=0&&d<days&&cnt[days-1-d][a[1]]!==undefined){cnt[days-1-d][a[1]]++;cnt[days-1-d].t++;}});
 cnt.forEach(function(c){if(c.t>mx)mx=c.t;});
 var top=Math.max(4,nice(mx*1.1)),L=34,R=8,T=8,B=20,pw=W-L-R,ph=H-T-B,bw=pw/days,muted=css('--muted'),line=css('--panelline');
 g.font='11px "Segoe UI",sans-serif';
 for(i=0;i<=4;i++){var y=T+ph-ph*i/4;g.strokeStyle=line;g.lineWidth=1;g.beginPath();g.moveTo(L,y+.5);g.lineTo(L+pw,y+.5);g.stroke();
  g.fillStyle=muted;g.textAlign='right';g.textBaseline='middle';g.fillText(String(Math.round(top*i/4*10)/10),L-6,y);}
 for(i=0;i<days;i++){var c=cnt[i],x=L+i*bw+bw*.2,w=bw*.6,yb=T+ph;
  if(hi===i){g.fillStyle=hexA(css('--text'),.07);g.fillRect(L+i*bw,T,bw,ph);}
  AM.forEach(function(m){if(c[m]){var h=ph*c[m]/top;g.fillStyle=css(MCOL[m]);g.fillRect(x,yb-h,w,h-1>0?h-1:h);yb-=h;}});
  if(i%2===(days-1)%2){g.fillStyle=muted;g.textAlign='center';g.textBaseline='top';g.fillText(fmtT((today-(days-1-i))*86400,'date'),L+i*bw+bw/2,T+ph+5);}}
 abars={L:L,bw:bw,days:days,cnt:cnt,today:today};}
function initAlertBars(){var cv=$('ac'),tip=$('act');
 cv.addEventListener('mousemove',function(ev){if(!abars)return;var r=cv.getBoundingClientRect(),x=ev.clientX-r.left,i=Math.floor((x-abars.L)/abars.bw);
  if(i<0||i>=abars.days){tip.style.display='none';drawAlertBars(null);return;}
  var c=abars.cnt[i],h='<div style="color:'+css('--muted')+'">'+fmtT((abars.today-(abars.days-1-i))*86400,'date')+'  ('+c.t+' alerts)</div>';
  AM.forEach(function(m){if(c[m])h+='<div><i style="display:inline-block;width:8px;height:8px;border-radius:50%;background:'+css(MCOL[m])+';margin-right:6px"></i>'+m+' <b>'+c[m]+'</b></div>';});
  if(!c.t)h+='<div>none</div>';
  tip.innerHTML=h;tip.style.display='block';var lx=x+14;if(lx+tip.offsetWidth>cv.clientWidth)lx=x-tip.offsetWidth-14;tip.style.left=Math.max(0,lx)+'px';tip.style.top='8px';drawAlertBars(i);});
 cv.addEventListener('mouseleave',function(){tip.style.display='none';drawAlertBars(null);});}
function dayOf(s){return Math.floor(alertEpoch(s)/86400);}
function buildAlerts(){
 buildAlertTiles();
 var bar=$('afilter');chips(bar,['All','CPU','GPU','RAM','DISK'],aFilter,function(v){aFilter=v;buildAlerts();});
 var rows=D.alerts.slice().reverse().filter(function(a){return aFilter==='All'||a[1]===aFilter;});
 if(!rows.length){$('atable').innerHTML='<div class="empty">No alerts recorded.</div>';return;}
 var h='<table><tr><th>Time</th><th>Metric</th><th>Value</th><th>Threshold</th><th>Top process / drive</th></tr>';
 rows.forEach(function(a){var d=a[1]==='DISK',col=css(MCOL[a[1]]||'--blue');
  h+='<tr><td>'+esc(a[0])+'</td><td><span class="pill" style="background:'+col+'">'+esc(a[1])+'</span></td><td>'+esc(a[2])+(d?'% free':'%')+'</td><td>'+esc(a[3])+(d?'% free':'%')+'</td><td>'+esc(a[4])+'</td></tr>';});
 $('atable').innerHTML=h+'</table>';}
function lvl(s){if(/ALERT/.test(s))return 'a';if(/error|fail|exception|FATAL|unexpected/i.test(s))return 'e';if(/ Setting /.test(s))return 's';return '';}
function buildLog(){
 var bar=$('lfilter');chips(bar,['All','Errors','Alerts','Settings'],lFilter,function(v){lFilter=v;buildLog();});
 var inp=document.createElement('input');inp.type='search';inp.placeholder='Search the log...';inp.value=lText;
 inp.addEventListener('input',function(){lText=inp.value;fillLog();});bar.appendChild(inp);
 fillLog();}
function fillLog(){
 var want={Errors:'e',Alerts:'a',Settings:'s'}[lFilter],q=lText.toLowerCase(),h='',n=0;
 for(var i=D.log.length-1;i>=0;i--){var s=D.log[i],l=lvl(s);
  if(want&&l!==want)continue;if(q&&s.toLowerCase().indexOf(q)<0)continue;h+='<div class="'+l+'">'+esc(s)+'</div>';n++;}
 $('logbox').innerHTML=n?h:'<div class="empty">Nothing matches.</div>';}

function n1(v,d){return (v===null||v===undefined||v==='')?'-':(+v).toFixed(d===undefined?1:d);}
function gradeCol(g){return (g==='Excellent'||g==='Good')?'--teal':(g==='Fair'?'--amber':'--red');}
function utcText(x){return x?String(x).replace('T',' ').slice(0,16)+' UTC':'-';}
function buildNetTiles(){
 var c=stats('sig','net'),rp=stats('rping','net'),ip=stats('iping','net'),dn=stats('ndown','net'),up=stats('nup','net');
 var sp=D.speed||[],last=null,fl=D.fullLatest,q;
 for(q=sp.length-1;q>=0;q--){if(sp[q][1]==='ok'&&sp[q][2]){last=sp[q];break;}}
 function p(x){return x===null?'-':fPct(x);} function ms(x){return x===null?'-':fMs(x);} function mb(x){return x===null?'-':fMb(x);}
 $('ntiles').innerHTML=tile('Signal average',c.avg===null?'n/a':p(c.avg),c.avg===null?'wired or no data':'peak '+p(c.max))+
  tile('Router ping',ms(rp.avg),'worst '+ms(rp.max))+tile('Internet ping',ms(ip.avg),'worst '+ms(ip.max))+
  tile('Download',mb(dn.avg),'peak '+mb(dn.max))+tile('Upload',mb(up.avg),'peak '+mb(up.max))+
  tile('Last speed test',(last&&last[2])?n1(last[2])+' Mbps':'-',last?esc(last[0]):'none yet')+
  tile('Last full test',(fl&&fl.Summary)?'<span style="color:var('+gradeCol(fl.Summary.Grade)+')">'+esc(fl.Summary.Grade)+'</span>':'none yet',fl?esc(fl.Time):'press Full test in the widget');}
function buildNetCharts(){
 var h='';NCH.forEach(function(c){var leg='';c.s.forEach(function(s){leg+='<span><i style="background:var('+s[2]+')"></i>'+s[1]+'</span>';});
  h+='<div class="card"><div class="ch"><b>'+c.title+'</b><div class="leg">'+leg+'</div></div><div class="cv"><canvas id="'+c.id+'"></canvas><div class="tip" id="'+c.id+'t"></div></div></div>';});
 $('ncharts').innerHTML=h;
 NCH.forEach(function(c){var cv=$(c.id);
  cv.addEventListener('mousemove',function(ev){tipFor(c,ev);});
  cv.addEventListener('mouseleave',function(){$(c.id+'t').style.display='none';draw(c,null);});});}
function drawNet(){NCH.forEach(function(c){draw(c,null);});drawRunCharts();}
function buildFull(){
 var f=D.fullLatest;
 if(!f||!f.Summary){$('fbody').innerHTML='<div class="empty">No full test yet. Press <b>Full test</b> on the Network page of the widget.</div>';$('fsub').textContent='';return;}
 var S=f.Summary,B=f.Bottleneck,h='';
 $('fsub').textContent=f.Time+'  |  '+(f.IsWifi?'Wi-Fi '+(f.Ssid||''):'Ethernet')+'  |  '+(f.Adapter||'')+'  |  router address hidden';
 if(B){h+='<div class="bn" style="margin-bottom:12px"><div class="ch"><b>Where might the bottleneck be?</b><span class="badge b-'+esc(B.level)+'" style="margin-left:auto">'+esc(B.level)+'</span></div>'+
  '<div style="font-size:16px;font-weight:600">'+esc(B.title)+'</div><div class="sub" style="margin:2px 0 6px">'+esc(B.detail)+'</div>';
  if(B.items&&B.items.length){h+='<ul>';B.items.forEach(function(i){h+='<li><span class="badge b-'+esc(i.level)+'">'+esc(i.level)+'</span> '+esc(i.text)+'</li>';});h+='</ul>';}
  h+='</div>';}
 h+='<div class="tiles">'+tile('Grade','<span style="color:var('+gradeCol(S.Grade)+')">'+esc(S.Grade)+'</span>','score '+n1(S.Score,0)+' / 100')+
  tile('Download',n1(S.DownBest)+' Mbps','average '+n1(S.DownAvg)+' Mbps')+tile('Upload',(S.Up===null||S.Up===undefined)?'-':n1(S.Up)+' Mbps','')+
  tile('Router ping',n1(S.RouterPing)+' ms',f.Router?'loss '+n1(f.Router.Loss)+'%':'')+
  tile('Internet ping',n1(S.InternetPing)+' ms','Google '+n1(S.GooglePing)+' ms, jitter '+n1(S.Jitter)+' ms')+
  tile('Packet loss',n1(S.LossPct)+'%','worst of the internet targets')+
  tile('DNS lookup',(S.DnsAvg===null||S.DnsAvg===undefined)?'-':n1(S.DnsAvg,0)+' ms','median of 5')+'</div>';
 if(f.Diag&&f.Diag.length){h+='<div class="ch" style="margin-top:10px"><b>Diagnostics</b></div>'+tbl(['Check','Result','Status','What it means'],f.Diag.map(function(r){return [esc(r.name),esc(r.value),'<span class="badge b-'+esc(r.level)+'">'+esc(r.level)+'</span>','<span class="sub">'+esc(r.note)+'</span>'];}),'');}
 if(f.Trace&&f.Trace.length){h+='<div class="ch" style="margin-top:14px"><b>Route to the internet</b><span class="sub">traceroute to 1.1.1.1, private addresses hidden</span></div>'+tbl(['Hop','Address','Time'],f.Trace.map(function(r){return [r.Hop,esc(r.Address||'no reply'),(r.Ms===null||r.Ms===undefined)?'-':r.Ms+' ms'];}),'');}
 $('fbody').innerHTML=h;}
function runChart(elId,series,days){
 var t1=D.now,t0=t1-days*86400,pts=[],i;
 (D.fulls||[]).forEach(function(r){var ts=alertEpoch(r[0]);if(ts>=t0&&ts<=t1){var o={ts:ts};series.forEach(function(s){var v=parseFloat(r[s.idx]);o[s.idx]=isNaN(v)?null:v;});pts.push(o);}});
 var has=pts.some(function(p){return series.some(function(s){return p[s.idx]!==null;});});
 if(!has){$(elId).innerHTML='<div class="empty">No full test in this period.</div>';return;}
 var W=900,H=230,L=48,R=14,T=12,B=28,mx=0;
 series.forEach(function(s){pts.forEach(function(p){if(p[s.idx]!==null&&p[s.idx]>mx)mx=p[s.idx];});});
 mx=nice(Math.max(mx*1.1,5));
 var X=function(t){return L+(t-t0)/(t1-t0)*(W-L-R);},Y=function(v){return T+(1-v/mx)*(H-T-B);},g='';
 for(i=0;i<=4;i++){var yv=mx*i/4,y=Y(yv);g+='<line x1="'+L+'" y1="'+y+'" x2="'+(W-R)+'" y2="'+y+'" stroke="'+css('--panelline')+'" stroke-width="1"/><text x="'+(L-6)+'" y="'+(y+4)+'" text-anchor="end" font-size="11" fill="'+css('--muted')+'">'+(Math.round(yv*10)/10)+'</text>';}
 for(i=0;i<=4;i++){var tt=t0+(t1-t0)*i/4;g+='<text x="'+X(tt)+'" y="'+(H-8)+'" text-anchor="'+(i===0?'start':(i===4?'end':'middle'))+'" font-size="11" fill="'+css('--muted')+'">'+fmtT(tt,days>1?'date':'hm')+'</text>';}
 series.forEach(function(s){var col=css(s.color),line=[],dots='';
  pts.forEach(function(p){if(p[s.idx]===null)return;line.push(X(p.ts).toFixed(1)+','+Y(p[s.idx]).toFixed(1));
   dots+='<circle cx="'+X(p.ts).toFixed(1)+'" cy="'+Y(p[s.idx]).toFixed(1)+'" r="3.5" fill="'+col+'"><title>'+esc(s.name)+': '+p[s.idx]+' '+s.unit+' ('+fmtT(p.ts,'full')+')</title></circle>';});
  if(line.length>1)g+='<polyline points="'+line.join(' ')+'" fill="none" stroke="'+col+'" stroke-width="2" stroke-linejoin="round"/>';
  g+=dots;});
 $(elId).innerHTML='<svg viewBox="0 0 '+W+' '+H+'" role="img">'+g+'</svg>';}
function drawRunCharts(){var d=Math.max(1,Math.round(RANGES[rangeI][1]/86400));
 runChart('rc1',[{idx:3,name:'Download',unit:'Mbps',color:'--teal'},{idx:4,name:'Upload',unit:'Mbps',color:'--blue'}],d);
 runChart('rc2',[{idx:5,name:'Router',unit:'ms',color:'--teal'},{idx:6,name:'Internet',unit:'ms',color:'--blue'}],d);}
function tbl(heads,rows,empty){
 if(!rows.length)return '<div class="empty">'+empty+'</div>';
 var h='<table><tr>';heads.forEach(function(x){h+='<th>'+x+'</th>';});h+='</tr>';
 rows.forEach(function(r){h+='<tr>';r.forEach(function(c){h+='<td>'+c+'</td>';});h+='</tr>';});return h+'</table>';}
function buildNetTables(){
 var sp=(D.speed||[]).slice().reverse().slice(0,40).map(function(r){return [esc(r[0]),esc(r[1]),r[2]?esc(r[2])+' Mbps':'-',esc(r[3]),esc((r[4]||'')+' '+(r[6]||r[5]||''))];});
 $('stable').innerHTML=tbl(['Time','Result','Speed','Started by','Connection'],sp,'No speed tests recorded yet.');
 var fu=(D.fulls||[]).slice().reverse().map(function(r){return [esc(r[0]),'<span style="color:var('+gradeCol(r[1])+')"><b>'+esc(r[1])+'</b></span> ('+esc(r[2])+')',n1(r[3])+' / '+n1(r[4])+' Mbps',n1(r[5])+' / '+n1(r[6])+' ms',n1(r[7])+' ms / '+n1(r[8])+'%',esc((r[10]||'')+' '+(r[12]||r[11]||''))];});
 $('ftable').innerHTML=tbl(['Time','Grade','Down / Up','Router / Internet ping','Jitter / Loss','Connection'],fu,'No full tests recorded yet.');
 var dv=(D.devices||[]).slice().sort(function(a,b){return String(b.LastSeen||'').localeCompare(String(a.LastSeen||''));}).map(function(d){return [d.Name?esc(d.Name):'<span style="color:var(--amber)">Unnamed</span>',esc(d.Ip||'-'),esc(d.Mac||''),esc(d.Hostname||d.Vendor||'-'),utcText(d.FirstSeen),utcText(d.LastSeen)];});
 $('dtable').innerHTML=tbl(['Name','IP address','MAC address','Calls itself','First seen','Last seen'],dv,'No devices found yet.');
 var ev=(D.devEvents||[]).slice().reverse().slice(0,60).map(function(r){return [esc(r[0]),r[1]==='new'?'New device':'Back after a while',esc(r[2]),esc(r[3]||'-'),esc(r[4]||'unnamed'),esc(r[5]||'-')];});
 $('evtable').innerHTML=tbl(['Time','Event','MAC address','IP address','Name','Calls itself'],ev,'No device events recorded yet.');}
function causeText(c){return c==='internet'?'Internet (beyond your router)':(c==='router'?'Router or local network':(c==='no link'?'No network link on this PC':c));}
function durText(s){s=Math.round(s);if(s<60)return s+' s';if(s<3600)return Math.floor(s/60)+' min '+(s%60)+' s';return Math.floor(s/3600)+' h '+Math.floor((s%3600)/60)+' min';}
function outageRows(t0,t1){return (D.outages||[]).map(function(o){return {s:alertEpoch(o[0]),e:alertEpoch(o[1]),sec:+o[2],c:o[3],type:o[4],ad:o[5]};}).filter(function(o){return o.e>=t0&&o.s<=t1;});}
function buildOutages(){
 var r=slice('net'),rows=outageRows(r.t0,r.t1),tot=0;rows.forEach(function(o){tot+=o.sec;});
 $('osub').textContent=rows.length?(rows.length+' outage(s), '+durText(tot)+' in total'):'no outages in this range';
 var W=900,H=50,L=10,Rr=10,svg='<svg viewBox="0 0 '+W+' '+H+'"><rect x="'+L+'" y="10" width="'+(W-L-Rr)+'" height="16" rx="4" fill="'+css('--track')+'"/>';
 rows.forEach(function(o){var x1=L+(Math.max(o.s,r.t0)-r.t0)/(r.t1-r.t0)*(W-L-Rr),x2=L+(Math.min(o.e,r.t1)-r.t0)/(r.t1-r.t0)*(W-L-Rr);
  svg+='<rect x="'+x1.toFixed(1)+'" y="10" width="'+Math.max(2,x2-x1).toFixed(1)+'" height="16" fill="'+css('--red')+'"><title>'+esc(fmtT(o.s,'full')+'  '+durText(o.sec)+'  '+causeText(o.c))+'</title></rect>';});
 for(var i=0;i<=4;i++){var tt=r.t0+(r.t1-r.t0)*i/4;svg+='<text x="'+(L+(W-L-Rr)*i/4)+'" y="44" text-anchor="'+(i===0?'start':(i===4?'end':'middle'))+'" font-size="11" fill="'+css('--muted')+'">'+fmtT(tt,r.sec>86400*2?'date':'hm')+'</text>';}
 $('otl').innerHTML=svg+'</svg>';
 $('otable').innerHTML=tbl(['Started','Length','Cause'],rows.slice().reverse().slice(0,60).map(function(o){return [esc(fmtT(o.s,'full')),esc(durText(o.sec)),esc(causeText(o.c))];}),'No outages in this range. Outages are recorded while the dashboard is running.');}
function periodStartSec(nowSec,rd){var d=new Date(nowSec*1000),y=d.getUTCFullYear(),m=d.getUTCMonth(),day=d.getUTCDate();rd=Math.min(28,Math.max(1,rd||1));if(day<rd){m--;if(m<0){m=11;y--;}}return Date.UTC(y,m,rd)/1000;}
function usageDays(){var u=D.usage||{},out=[];Object.keys(u).forEach(function(k){var m=/^(\d+)-(\d+)-(\d+)$/.exec(k);if(m)out.push({t:Date.UTC(+m[1],+m[2]-1,+m[3])/1000,rx:+u[k][0],tx:+u[k][1],k:k});});out.sort(function(a,b){return a.t-b.t;});return out;}
function gb(b){var g=b/1e9;return (g>=100?g.toFixed(0):(g>=10?g.toFixed(1):g.toFixed(2)))+' GB';}
function buildUsage(){
 var days=usageDays(),ps=periodStartSec(D.now,D.resetDay),rx=0,tx=0;
 days.forEach(function(d){if(d.t>=ps){rx+=d.rx;tx+=d.tx;}});
 $('usub').textContent='since '+fmtT(ps,'date')+' (day '+(D.resetDay||1)+' of the month)  -  counted on this PC while the dashboard runs';
 var lim=D.dataLimit||0,pct=lim?((rx+tx)/(lim*1e9)*100):null;
 $('utiles').innerHTML=tile('Downloaded',gb(rx),'this period')+tile('Uploaded',gb(tx),'this period')+tile('Total',gb(rx+tx),lim?(n1(pct,0)+'% of your '+lim+' GB limit'):'no limit set')+
  tile('Today',days.length?gb(days[days.length-1].t===Math.floor(D.now/86400)*86400?days[days.length-1].rx+days[days.length-1].tx:0):'-','downloaded + uploaded');
 var N=31,t0=Math.floor(D.now/86400)*86400-(N-1)*86400,bars=[],mx=0,i;
 for(i=0;i<N;i++)bars.push({t:t0+i*86400,rx:0,tx:0});
 days.forEach(function(d){var j=Math.round((d.t-t0)/86400);if(j>=0&&j<N){bars[j].rx=d.rx;bars[j].tx=d.tx;}});
 bars.forEach(function(b){if(b.rx+b.tx>mx)mx=b.rx+b.tx;});
 if(mx<=0){$('uchart').innerHTML='<div class="empty">No data usage recorded yet.</div>';return;}
 var W=900,H=190,L=48,Rr=10,T=10,B=26,top=nice(mx/1e9*1.1)*1e9,bw=(W-L-Rr)/N,g='';
 for(i=0;i<=4;i++){var y=T+(H-T-B)*(1-i/4);g+='<line x1="'+L+'" y1="'+y+'" x2="'+(W-Rr)+'" y2="'+y+'" stroke="'+css('--panelline')+'"/><text x="'+(L-6)+'" y="'+(y+4)+'" text-anchor="end" font-size="11" fill="'+css('--muted')+'">'+(top*i/4/1e9).toFixed(top/1e9<10?1:0)+'</text>';}
 bars.forEach(function(b,j){var x=L+j*bw+bw*.15,w=bw*.7,h1=(H-T-B)*b.rx/top,h2=(H-T-B)*b.tx/top,yb=H-B;
  g+='<rect x="'+x.toFixed(1)+'" y="'+(yb-h1).toFixed(1)+'" width="'+w.toFixed(1)+'" height="'+h1.toFixed(1)+'" fill="'+css('--teal')+'"><title>'+esc(fmtT(b.t,'date')+': down '+gb(b.rx)+', up '+gb(b.tx))+'</title></rect>';
  g+='<rect x="'+x.toFixed(1)+'" y="'+(yb-h1-h2).toFixed(1)+'" width="'+w.toFixed(1)+'" height="'+h2.toFixed(1)+'" fill="'+css('--blue')+'"><title>'+esc(fmtT(b.t,'date')+': down '+gb(b.rx)+', up '+gb(b.tx))+'</title></rect>';
  if(j%5===0)g+='<text x="'+(x+w/2)+'" y="'+(H-8)+'" text-anchor="middle" font-size="11" fill="'+css('--muted')+'">'+fmtT(b.t,'date')+'</text>';});
 $('uchart').innerHTML='<svg viewBox="0 0 '+W+' '+H+'">'+g+'</svg><div class="leg" style="margin:4px 0 0"><span><i style="background:var(--teal)"></i>Download (GB per day)</span><span><i style="background:var(--blue)"></i>Upload</span></div>';}
function buildScanCard(){
 var sc=D.scan;
 if(!sc||!sc.Networks){$('wsub').textContent='';$('wadv').innerHTML='<div class="empty">No Wi-Fi scan yet. On the widget, open the Network tab and choose Nearby Wi-Fi to scan.</div>';$('wtable').innerHTML='';return;}
 $('wsub').textContent='scanned '+esc(sc.Time||'');var a=sc.Advice||{},h='';
 if(a.Best24)h+='<div>Best 2.4 GHz channel: <b>'+a.Best24.Channel+'</b> <span class="sub">('+a.Best24.Count+' network(s) overlap)</span></div>';
 if(a.Best5)h+='<div>Best 5 GHz channel: <b>'+a.Best5.Channel+'</b> <span class="sub">('+a.Best5.Count+' network(s) overlap)</span></div>';
 if(a.Mine)h+='<div class="bar-note">Your network is on channel '+a.Mine.Channel+' ('+esc(a.Mine.Band)+'), '+a.Mine.Count+' network(s) overlap it. Change the channel in your router settings if a quieter one is listed above.</div>';
 $('wadv').innerHTML=h;
 var rows=(sc.Networks||[]).slice().sort(function(x,y){return y.Signal-x.Signal;}).map(function(n){return [n.Ssid?esc(n.Ssid):'<span class="sub">(hidden)</span>',esc(n.Band||''),n.Channel,n.Signal+'%',esc(n.Auth||''),n.Mine?'<span class="badge b-PASS">yours</span>':''];});
 $('wtable').innerHTML=tbl(['Network','Band','Channel','Signal','Security',''],rows,'No networks found.');}
function buildNetStatic(){buildFull();buildNetTables();buildUsage();buildScanCard();}

// ---------- report for the internet provider
var repDays=7;
function ymdOf(sec){var d=new Date(sec*1000);return d.getUTCFullYear()+'-'+pad(d.getUTCMonth()+1)+'-'+pad(d.getUTCDate());}
function buildReport(){
 var t1=D.now,t0=t1-repDays*86400,lim=D.limit||10,h='',i;
 var segh='';[7,30].forEach(function(d){segh+='<button class="'+(d===repDays?'on':'')+'" data-d="'+d+'">'+d+' days</button>';});$('rseg').innerHTML=segh;
 Array.prototype.forEach.call($('rseg').querySelectorAll('button'),function(b){b.addEventListener('click',function(){repDays=+b.getAttribute('data-d');buildReport();});});
 var out=outageRows(t0,t1).map(function(o){return {s:Math.max(o.s,t0),e:Math.min(o.e,t1),sec:Math.min(o.e,t1)-Math.max(o.s,t0),c:o.c,o:o};});
 var inet=out.filter(function(o){return o.c==='internet';}),rt=out.filter(function(o){return o.c==='router';}),nl=out.filter(function(o){return o.c==='no link';});
 function sum(a){var t=0;a.forEach(function(o){t+=o.sec;});return t;}
 var sp=(D.speed||[]).map(function(r){return {t:alertEpoch(r[0]),res:r[1],mbps:parseFloat(r[2]),src:r[3],conn:(r[4]||'')+' '+(r[6]||r[5]||'')};}).filter(function(r){return r.t>=t0&&r.t<=t1&&r.res==='ok'&&r.mbps>0;});
 var avg=0,mn=null,mxv=null;sp.forEach(function(r){avg+=r.mbps;if(mn===null||r.mbps<mn)mn=r.mbps;if(mxv===null||r.mbps>mxv)mxv=r.mbps;});if(sp.length)avg/=sp.length;
 var slow=sp.filter(function(r){return r.mbps<lim;});
 var net=D.net.coarse,days={};
 function dayRec(k){return days[k]||(days[k]={k:k,dn:0,dnN:0,up:0,upN:0,ip:0,ipN:0,ipX:0,sp:[],oc:0,os:0});}
 if(net&&net.sig){for(i=0;i<net.n;i++){var ts=net.start+i*net.step;if(ts<t0||ts>t1)continue;var r=dayRec(ymdOf(ts));
   var c1=net.ndownN[i]||0,c2=net.nupN[i]||0,c3=net.ipingN[i]||0;
   if(net.ndown[i]!==null&&c1){r.dn+=net.ndown[i]*c1;r.dnN+=c1;}if(net.nup[i]!==null&&c2){r.up+=net.nup[i]*c2;r.upN+=c2;}
   if(net.iping[i]!==null&&c3){r.ip+=net.iping[i]*c3;r.ipN+=c3;}r.ipX+=net.ipingX[i]||0;}}
 var totIp=0,totIpN=0,totX=0;Object.keys(days).forEach(function(k){totIp+=days[k].ip;totIpN+=days[k].ipN;totX+=days[k].ipX;});
 sp.forEach(function(r){dayRec(ymdOf(r.t)).sp.push(r.mbps);});
 out.forEach(function(o){var r=dayRec(ymdOf(o.s));r.oc++;r.os+=o.sec;});
 var du=usageDays(),used=0;du.forEach(function(d){if(d.t>=Math.floor(t0/86400)*86400)used+=d.rx+d.tx;});
 var downNet=sum(inet)+sum(rt),pctUp=100-downNet/(repDays*86400)*100,missed=(totIpN+totX)?totX/(totIpN+totX)*100:null;
 h+='<div class="sub" style="margin-bottom:8px">Period: '+fmtT(t0,'date')+' to '+fmtT(t1,'date')+' ('+repDays+' days). Prepared '+fmtT(D.now,'full')+' (local time) by System Dashboard from this PC. Speed tests use Cloudflare. Outages and speeds are only recorded while the dashboard is running.</div>';
 h+='<div class="tiles">'+tile('Internet outages',String(inet.length),durText(sum(inet))+' in total')+
  tile('Router / local outages',String(rt.length),durText(sum(rt))+' in total')+
  tile('Estimated availability',n1(pctUp,2)+'%','internet + router outages')+
  tile('Speed tests',String(sp.length),sp.length?('average '+n1(avg)+', lowest '+n1(mn)+' Mbps'):'none in this period')+
  tile('Below '+lim+' Mbps',String(slow.length),sp.length?(n1(slow.length/sp.length*100,0)+'% of the tests'):'')+
  tile('Internet ping',totIpN?n1(totIp/totIpN,0)+' ms':'-',missed===null?'':n1(missed,1)+'% of pings got no answer')+
  tile('Data used',gb(used),'downloaded + uploaded')+'</div>';
 h+='<div class="ch" style="margin-top:12px"><b>Outages</b><span class="sub">'+out.length+' in this period</span></div>'+tbl(['Started','Length','Cause'],out.slice().reverse().map(function(o){return [esc(fmtT(o.s,'full')),esc(durText(o.sec)),esc(causeText(o.c))];}),'No outages were recorded in this period.');
 h+='<div class="ch" style="margin-top:12px"><b>Slow speed tests</b><span class="sub">below '+lim+' Mbps</span></div>'+tbl(['Time','Speed','Started by','Connection'],slow.slice().reverse().map(function(r){return [esc(fmtT(r.t,'full')),n1(r.mbps)+' Mbps',esc(r.src),esc(r.conn)];}),'No speed test was below the limit.');
 var drows=Object.keys(days).sort().reverse().map(function(k){var r=days[k],mnS=r.sp.length?Math.min.apply(null,r.sp):null;
   return [esc(k),r.dnN?n1(r.dn/r.dnN)+' Mbps':'-',r.upN?n1(r.up/r.upN)+' Mbps':'-',r.ipN?n1(r.ip/r.ipN,0)+' ms':'-',(r.ipN+r.ipX)?n1(r.ipX/(r.ipN+r.ipX)*100,1)+'%':'-',r.sp.length?(r.sp.length+' test(s), lowest '+n1(mnS)+' Mbps'):'-',r.oc?(r.oc+' ('+durText(r.os)+')'):'0'];});
 h+='<div class="ch" style="margin-top:12px"><b>Day by day</b><span class="sub">average traffic while the PC was online</span></div>'+tbl(['Date','Avg download','Avg upload','Avg ping','Pings without answer','Speed tests','Outages'],drows,'No data in this period.');
 var fl=(D.fulls||[]).filter(function(r){var t=alertEpoch(r[0]);return t>=t0&&t<=t1;}).reverse().map(function(r){return [esc(r[0]),esc(r[1])+' ('+esc(r[2])+')',n1(r[3])+' / '+n1(r[4])+' Mbps',n1(r[5])+' / '+n1(r[6])+' ms',n1(r[8])+'%'];});
 if(fl.length)h+='<div class="ch" style="margin-top:12px"><b>Full tests</b></div>'+tbl(['Time','Grade','Download / Upload','Router / Internet ping','Loss'],fl,'');
 $('rbody').innerHTML=h;}
$('rprint').addEventListener('click',function(){window.print();});

function buildHeader(){
 $('gen').textContent='Snapshot taken '+fmtT(D.now,'full')+'  -  press View history in the widget to refresh';
 var h='';RANGES.forEach(function(r,i){h+='<button class="'+(i===rangeI?'on':'')+'" data-i="'+i+'">'+r[0]+'</button>';});
 $('range').innerHTML=h;
 Array.prototype.forEach.call($('range').querySelectorAll('button'),function(b){b.addEventListener('click',function(){rangeI=+b.getAttribute('data-i');buildHeader();refresh();});});
 var t=[['over','Overview'],['net','Network'],['report','Provider report'],['alerts','Alerts'],['log','Log']],th='';
 t.forEach(function(x){th+='<button class="'+(tab===x[0]?'on':'')+'" data-t="'+x[0]+'">'+x[1]+'</button>';});
 $('tabs').innerHTML=th;
 Array.prototype.forEach.call($('tabs').querySelectorAll('button'),function(b){b.addEventListener('click',function(){tab=b.getAttribute('data-t');buildHeader();show();});});
 $('range').style.display=(tab==='over'||tab==='net')?'flex':'none';}
function show(){$('p_over').className=tab==='over'?'':'hide';$('p_net').className=tab==='net'?'':'hide';$('p_report').className=tab==='report'?'':'hide';$('p_alerts').className=tab==='alerts'?'':'hide';$('p_log').className=tab==='log'?'':'hide';
 if(tab==='over'||tab==='net')refresh();if(tab==='report')buildReport();if(tab==='alerts')drawAlertBars(null);}
function refresh(){if(tab==='net'){buildNetTiles();drawNet();buildOutages();}else{buildTiles();drawAll();}}
buildHeader();buildCharts();buildNetCharts();buildNetStatic();buildAlerts();initAlertBars();buildLog();show();
window.addEventListener('resize',function(){if(tab==='over')drawAll();if(tab==='net')drawNet();if(tab==='alerts')drawAlertBars(null);});
})();
</script></body></html>
'@

function Hex([System.Drawing.Color]$c) { return ('#{0:x2}{1:x2}{2:x2}' -f $c.R, $c.G, $c.B) }

function Build-ThemeCss {
    $p = $script:Pal
    $pairs = @(@('bg', 'Bg'), @('header', 'Header'), @('border', 'Border'), @('hover', 'Hover'), @('chip', 'Chip'), @('track', 'Track'),
               @('panel', 'Panel'), @('panelline', 'PanelLine'), @('text', 'Text'), @('muted', 'Muted'), @('teal', 'Teal'),
               @('blue', 'Blue'), @('amber', 'Amber'), @('red', 'Red'))
    $css = ':root{'
    foreach ($pr in $pairs) { $css += ('--' + $pr[0] + ':' + (Hex $p[$pr[1]]) + ';') }
    return ($css + '}')
}

function Open-WebPage([string]$tab, [string]$path) {
    if ([HistoryPage]::Status -eq 'running') { return }
    [HistoryPage]::SlowLimit = [int]$script:Settings['SlowLimit']
    [HistoryPage]::DataLimitGB = [int]$script:Settings['DataLimitGB']
    [HistoryPage]::DataResetDay = [int]$script:Settings['DataResetDay']
    $script:HistoryPending = $true
    $script:PendingPath = $path
    [HistoryPage]::BuildAsync($script:DataDir, $path, $script:HistoryTemplate, (Build-ThemeCss), $tab)
    Write-Log ('Building web page ' + [System.IO.Path]::GetFileName($path))
}

function Open-HistoryPage { Open-WebPage 'over' $script:HistoryHtml }
function Open-AlertsPage { Open-WebPage 'alerts' $script:AlertsHtml }

function Check-HistoryBuild {
    if (-not $script:HistoryPending) { return }
    $st = [string][HistoryPage]::Status
    if ($st -eq 'done') {
        $script:HistoryPending = $false
        Write-Log ('Web page ready, opening in the default browser: ' + [System.IO.Path]::GetFileName($script:PendingPath))
        try { Start-Process -FilePath $script:PendingPath } catch { Write-Log ('Open web page failed: ' + $_.Exception.Message) 'error' }
    } elseif ($st.StartsWith('error')) {
        $script:HistoryPending = $false
        Write-Log ('Web page failed: ' + $st) 'error'
    }
}

# ---------------------------------------------------------------- taskbar mini widget (left of the tray area)
$script:Badge = $null
$script:BadgeHover = $false
$script:LastBadgeClick = [DateTime]::MinValue

$script:TbLight = $false
$script:TbLightAt = [DateTime]::MinValue

# Is the Windows taskbar light? (then the text must be dark)
function Get-TaskbarLight {
    $now = Get-Date
    if (($now - $script:TbLightAt).TotalSeconds -lt 10) { return $script:TbLight }
    $script:TbLightAt = $now
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop).SystemUsesLightTheme
        $script:TbLight = ([int]$v -eq 1)
    } catch { $script:TbLight = $false }
    return $script:TbLight
}

function Get-BadgeColor([double]$pct, [bool]$light) {
    if ($pct -lt 60) { if ($light) { return [System.Drawing.Color]::FromArgb(13, 148, 136) } else { return $script:Pal.Teal } }
    if ($pct -le 85) { if ($light) { return [System.Drawing.Color]::FromArgb(180, 100, 0) } else { return $script:Pal.Amber } }
    if ($light) { return [System.Drawing.Color]::FromArgb(200, 35, 35) } else { return $script:Pal.Red }
}

# Only text on a see-through bitmap: no border, no background, so it looks like part of the taskbar.
function Render-BadgeBitmap([int]$w, [int]$h) {
    $F = $script:Fonts; $d = $script:Snap
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $light = Get-TaskbarLight
        # almost invisible fill, so the whole area can be clicked (fully transparent pixels let clicks through)
        $g.FillRectangle((Get-Brush ([System.Drawing.Color]::FromArgb(2, 128, 128, 128))), 0, 0, $w, $h)
        if ($script:BadgeHover) {
            if ($light) { $hc = [System.Drawing.Color]::FromArgb(24, 0, 0, 0) } else { $hc = [System.Drawing.Color]::FromArgb(30, 255, 255, 255) }
            Fill-Round $g (Get-Brush $hc) 0 0 $w $h (S 8)
        }
        if ($light) { $lab = [System.Drawing.Color]::FromArgb(75, 85, 100) } else { $lab = $script:Pal.Muted }
        $padY = (S 6)
        $padX = (S 9)
        $inner = $w - 2 * $padX
        $rowH = ($h - 2 * $padY) / 2.0
        $rows = @(@('CPU', [double]$d.Cpu), @('RAM', [double]$d.MemPct))
        for ($i = 0; $i -lt 2; $i++) {
            $y = $padY + $i * $rowH
            Draw-Text $g $rows[$i][0] $F.Muted (Get-Brush $lab) $padX $y ($inner / 2.0) $rowH 'LM'
            Draw-Text $g ((Fmt $rows[$i][1] '0') + '%') $F.Chip (Get-Brush (Get-BadgeColor $rows[$i][1] $light)) ($padX + $inner / 2.0) $y ($inner / 2.0) $rowH 'RM'
        }
    } finally { $g.Dispose() }
    return $bmp
}

function Refresh-Badge {
    $b = $script:Badge
    if ($null -eq $b -or -not $b.Visible -or -not $b.IsHandleCreated -or $b.Width -lt 4 -or $b.Height -lt 4) { return }
    $bmp = $null
    try {
        $bmp = Render-BadgeBitmap $b.Width $b.Height
        $b.SetBitmap($bmp, $b.Left, $b.Top)
    } catch { Log-Once 'Badge render' (Err-Text $_) }
    finally { if ($null -ne $bmp) { $bmp.Dispose() } }
}

function Toggle-FromBadge {
    $now = Get-Date
    if (($now - $script:LastBadgeClick).TotalMilliseconds -lt 350) { return }
    $script:LastBadgeClick = $now
    $fm = $script:Form
    if ($fm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or -not $fm.Visible) { Restore-Widget }
    elseif ([System.Windows.Forms.Form]::ActiveForm -eq $fm) { $fm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized }   # it is the front window: put it away
    else { Restore-Widget }                                                                                                      # it is behind another program: bring it forward
}

function Ensure-Badge {
    if ($null -ne $script:Badge) { return }
    $b = New-Object LayeredBadgeForm
    $b.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $b.TopMost = $true
    $b.Size = New-Object System.Drawing.Size((S 96), (S 44))
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_MouseEnter({ param($s, $e) try { $script:BadgeHover = $true; Refresh-Badge } catch { } })
    $b.Add_MouseLeave({ param($s, $e) try { $script:BadgeHover = $false; Refresh-Badge } catch { } })
    $b.Add_MouseUp({ param($s, $e) try {
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-FromBadge }
        elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-BadgeMenu }
    } catch { Log-Once 'Badge click' (Err-Text $_) } })
    $script:Badge = $b
}

# Closing with x keeps the program running (taskbar widget stays) as long as that widget is available.
function Can-Background {
    return ([bool]$script:Settings['CloseToBackground'] -and [bool]$script:Settings['ShowTaskbarBadge'] -and $null -ne $script:Badge -and $script:Badge.Visible)
}

function Hide-ToBackground {
    $script:Backgrounded = $true
    Hide-Popup
    $script:Form.Hide()
    Write-Log 'Closed to background (click the taskbar widget to open it, right-click it to exit)'
}

function Exit-App {
    Write-Log 'Exit requested'
    $script:Exiting = $true
    $script:Form.Close()
}

function Request-Close {
    if (Can-Background) { Hide-ToBackground } else { Write-Log 'Close button pressed'; Exit-App }
}

$script:BadgeMenu = $null
function Show-BadgeMenu {
    try { if ($null -ne $script:BadgeMenu) { $script:BadgeMenu.Dispose() } } catch { }
    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $o = New-Object System.Windows.Forms.ToolStripMenuItem('Open dashboard')
    $o.Add_Click({ param($s, $e) try { Restore-Widget } catch { Log-Once 'Badge menu open' (Err-Text $_) } })
    $x = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
    $x.Add_Click({ param($s, $e) try { Exit-App } catch { Log-Once 'Badge menu exit' (Err-Text $_) } })
    [void]$cm.Items.Add($o)
    [void]$cm.Items.Add($x)
    $script:BadgeMenu = $cm
    if ($null -ne $script:Badge) { [void][Native]::SetForegroundWindow($script:Badge.Handle) }
    $cm.Show([System.Windows.Forms.Cursor]::Position)
}

function Reset-Badge {
    try { if ($null -ne $script:Badge) { $script:Badge.Hide(); $script:Badge.Dispose() } } catch { }
    $script:Badge = $null
}

# Places the widget on the taskbar just left of the notification area and keeps it above the taskbar.
function Update-Badge {
    $want = ([bool]$script:Settings['ShowTaskbarBadge'] -and -not $script:AutoHidden)
    if (-not $want) {
        try { if ($null -ne $script:Badge -and $script:Badge.Visible) { $script:Badge.Hide() } } catch { }
        return
    }
    $tray = [System.Drawing.Rectangle]::Empty
    $notify = [System.Drawing.Rectangle]::Empty
    $ok = [Native]::GetTaskbarRects([ref]$tray, [ref]$notify)
    $primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    # An auto-hidden taskbar sits mostly off screen: hide the widget with it.
    if (-not $ok -or $tray.Height -lt (S 20) -or -not $primary.Contains($tray)) {
        try { if ($null -ne $script:Badge -and $script:Badge.Visible) { $script:Badge.Hide() } } catch { }
        return
    }
    $bw = (S 96)
    if ($tray.Width -ge $tray.Height) {
        $bh = [Math]::Max((S 26), [Math]::Min((S 44), $tray.Height - (S 4)))
        $x = $null
        if ([string]$script:Settings['BadgeSide'] -eq 'Left') {
            # Windows 11: between the Widgets button and the Start icon (positions come from the UI Automation probe)
            $tb = $script:Shared['Taskbar']
            if ($null -ne $tb -and $null -ne $tb.Start) {
                $sl = [int]$tb.Start[0]
                if ($null -ne $tb.Widgets -and [int]$tb.Widgets[2] -lt $sl) {
                    $x = [Math]::Min([int]$tb.Widgets[2] + (S 10), $sl - $bw - (S 8))
                } else { $x = $sl - $bw - (S 8) }
                if ($x -lt $tray.Left + (S 4)) { $x = $tray.Left + (S 4) }
            } else { $x = $tray.Left + (S 12) }
        }
        if ($null -eq $x) {
            if ($notify.Width -gt 0) { $x = $notify.Left - $bw - (S 8) } else { $x = $tray.Right - (S 300) - $bw }
        }
        $y = $tray.Top + [int](($tray.Height - $bh) / 2)
    } else {
        $bw = [Math]::Min($bw, $tray.Width - (S 6))
        $bh = (S 44)
        $x = $tray.Left + [int](($tray.Width - $bw) / 2)
        if ($notify.Height -gt 0) { $y = $notify.Top - $bh - (S 8) } else { $y = $tray.Bottom - (S 300) }
    }
    Ensure-Badge
    $b = $script:Badge
    if ($b.Width -ne $bw -or $b.Height -ne $bh) { $b.Size = New-Object System.Drawing.Size($bw, $bh) }
    if ($b.Left -ne $x -or $b.Top -ne $y) { $b.Location = New-Object System.Drawing.Point($x, $y) }
    if (-not $b.Visible) { $b.Show() }
    [Native]::KeepTopMost($b.Handle)
    Refresh-Badge
}

# ---------------------------------------------------------------- start with Windows (per-user Run key, no admin)
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'SystemDashboard'

function Get-StartupCommand {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"')
}

function Get-StartupValue {
    try {
        $item = Get-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction Stop
        return [string]$item.($script:RunName)
    } catch { return $null }
}

function Test-StartupEnabled { return ($null -ne (Get-StartupValue)) }

function Set-Startup([bool]$on) {
    try {
        if ($on) {
            if (-not (Test-Path -LiteralPath $script:RunKey)) { [void](New-Item -Path $script:RunKey -Force) }
            Set-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -Value (Get-StartupCommand) -Type String
        } else {
            Remove-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue
        }
        $script:Settings['StartWithWindows'] = [bool]$on
        Save-Settings
        Write-Log ('Start with Windows ' + $(if ($on) { 'enabled' } else { 'disabled' }))
    } catch { Write-Log ('Start with Windows change failed: ' + $_.Exception.Message) 'error' }
}

# If it is enabled but points to an old script location (folder moved), point it at this script.
function Sync-Startup {
    $v = Get-StartupValue
    if ($null -ne $v -and $v -ne (Get-StartupCommand)) {
        Set-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -Value (Get-StartupCommand) -Type String
        Write-Log 'Startup entry updated to the current script location'
    }
    $script:Settings['StartWithWindows'] = ($null -ne (Get-StartupValue))
}

# ---------------------------------------------------------------- taskbar probe (UI Automation, background thread)
$script:ProbeSource = @'
param($Shared, $Events)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
} catch { [void]$Events.Enqueue('LOG|Taskbar probe unavailable: ' + $_.Exception.Message); return }
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
function Find-Button($root, [string]$id, [string]$name) {
    $el = $null
    try {
        $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
        $el = $root.FindFirst($TS::Descendants, $c)
        if ($null -eq $el) {
            $c2 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
            $el = $root.FindFirst($TS::Descendants, $c2)
        }
    } catch { return $null }
    if ($null -eq $el) { return $null }
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty -or $r.Width -le 0 -or $r.Height -le 0) { return $null }
    return @([int]$r.Left, [int]$r.Top, [int]$r.Right, [int]$r.Bottom)
}
$logged = $false
while (-not $Shared.Stop) {
    try {
        $h = [Native]::GetTaskbarHandle()
        if ($h -ne [IntPtr]::Zero) {
            $root = $AE::FromHandle($h)
            $st = Find-Button $root 'StartButton' 'Start'
            $wd = Find-Button $root 'WidgetsButton' 'Widgets'
            $Shared.Taskbar = @{ Start = $st; Widgets = $wd }
            if (-not $logged) {
                $logged = $true
                $stt = 'not found'; if ($null -ne $st) { $stt = $st -join ',' }
                $wdt = 'not found'; if ($null -ne $wd) { $wd2 = $wd -join ',' ; $wdt = $wd2 }
                [void]$Events.Enqueue('LOG|Taskbar probe: Start=' + $stt + ' Widgets=' + $wdt)
            }
        }
    } catch {
        if (-not $logged) { $logged = $true; [void]$Events.Enqueue('LOG|Taskbar probe error: ' + $_.Exception.Message) }
    }
    $ms = 2000
    while ($ms -gt 0 -and -not $Shared.Stop) { Start-Sleep -Milliseconds 100; $ms -= 100 }
}
'@

function Start-TaskbarProbe {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:ProbeSource).AddArgument($script:Shared).AddArgument($script:Events)
    $script:ProbeRs = $rs
    $script:ProbePs = $ps
    $script:ProbeAsync = $ps.BeginInvoke()
}

function Stop-TaskbarProbe {
    try {
        if ($null -ne $script:ProbeAsync) {
            [void]$script:ProbeAsync.AsyncWaitHandle.WaitOne(2500)
            if (-not $script:ProbeAsync.IsCompleted) { try { $script:ProbePs.Stop() } catch { } }
        }
        if ($null -ne $script:ProbePs) { $script:ProbePs.Dispose() }
        if ($null -ne $script:ProbeRs) { $script:ProbeRs.Close(); $script:ProbeRs.Dispose() }
    } catch { Write-Log ('Stop-TaskbarProbe: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- Wi-Fi assistant: shared state and sampler
# Adapter + signal + link rates (netsh), Wi-Fi throughput, router ping and internet ping. Runs in its own runspace.
$script:Wifi = [hashtable]::Synchronized(@{
    Stop = $false; Connected = $false; Note = ''
    Adapter = ''; LocalIp = ''; Gateway = ''; Mask = ''; Mac = ''
    Ssid = ''; Bssid = ''; Signal = -1; Channel = 0; Band = ''; Radio = ''; RxRate = 0; TxRate = 0
    Down = 0.0; Up = 0.0; RouterPing = $null; InetPing = $null; LastError = ''
    LastSpeed = $null; LastSpeedText = ''; LastSpeedTime = $null; SweepReplies = 0; CurlPid = 0
    IsWifi = $false; LinkType = ''; LinkSpeed = 0; DlHist = [double[]]@(); UpHist = [double[]]@()
    HistEnabled = $true; HistInterval = 10; FullPct = 0; FullText = ''; FullCancel = $false
    InetVia = ''; OutageActive = $false; OutageCause = ''; OutageStart = $null; LastOutage = $null; OutageSeq = 0
    DataResetDay = 1; PeriodRx = 0.0; PeriodTx = 0.0; TodayRx = 0.0; TodayTx = 0.0; PeriodStart = ''
})
$script:WifiRunning = $false
$script:WifiOld = New-Object System.Collections.ArrayList
Sync-Cfg

$script:WifiSamplerSource = @'
param($S, $DataDir)
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# Pick the active network adapter: wired or Wi-Fi, with an IPv4 address; real hardware with a gateway wins
function Get-ActiveNic {
    $best = $null; $bestScore = -1
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $t = $n.NetworkInterfaceType.ToString()
        $isWifi = ($t -eq 'Wireless80211')
        if (-not $isWifi -and $t -notmatch 'Ethernet') { continue }
        $props = $n.GetIPProperties()
        $gw = $null; $v4 = $null; $mk = ''
        foreach ($ga in $props.GatewayAddresses) {
            if ($ga.Address.AddressFamily -eq 'InterNetwork' -and $ga.Address.ToString() -ne '0.0.0.0') { $gw = $ga.Address.ToString(); break }
        }
        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -eq 'InterNetwork') { $v4 = $ua.Address.ToString(); $mk = $ua.IPv4Mask.ToString(); break }
        }
        if (-not $v4 -or $v4.StartsWith('169.254.')) { continue }
        $desc = [string]$n.Description
        $virtual = ($desc -match 'Virtual|VMware|Hyper-V|VirtualBox|vEthernet|TAP-|Npcap|WAN Miniport|Bluetooth|Loopback')
        $score = 0
        if ($gw) { $score += 100 }
        if (-not $virtual) { $score += 50 }
        if (-not $isWifi) { $score += 10 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $macTxt = (($n.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { $_.ToString('X2') }) -join ':')
            $best = @{ Nic = $n; Name = $n.Name; Gateway = $gw; Ip = $v4; Mask = $mk; Mac = $macTxt; IsWifi = $isWifi; Speed = [int64]$n.Speed }
        }
    }
    return $best
}

# Run "netsh wlan show interfaces" without a console window and parse it
function Get-WlanInfo {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'netsh.exe'
    $psi.Arguments = 'wlan show interfaces'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(3000)
    $blocks = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s+([^:]+?)\s*:\s?(.*)$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if ($k -eq 'Name') { $cur = @{}; [void]$blocks.Add($cur) }
            if ($null -ne $cur) { $cur[$k] = $v }
        }
    }
    $note = ''
    if ($blocks.Count -eq 0 -and $out -match '(?i)location') { $note = 'location' }
    return @{ Blocks = $blocks; Note = $note }
}

$ping = New-Object System.Net.NetworkInformation.Ping
$freq = [double][System.Diagnostics.Stopwatch]::Frequency
$prevName = ''; $prevRx = [int64]0; $prevTx = [int64]0; $prevTs = [int64]0
$lastWlan = [datetime]'2000-01-01'
$lastPing = [datetime]'2000-01-01'
$lastInet = [datetime]'2000-01-01'
$dlHist = New-Object 'System.Collections.Generic.List[double]'
$upHist = New-Object 'System.Collections.Generic.List[double]'
$netCsv = $null
try { $netCsv = New-Object CsvAppender('Timestamp,AdapterType,Adapter,Ssid,SignalPercent,Channel,Band,LinkSpeedMbps,DownMbps,UpMbps,RouterPingMs,InternetPingMs') } catch { $S.LastError = 'csv: ' + $_.Exception.Message }
$lastHist = [datetime]'2000-01-01'

# Many networks block ping. A web connection (port 443) is the better proof that the internet works.
function Test-Tcp([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $c.Connected) {
            $sw.Stop()
            try { $c.EndConnect($ar) } catch { }
            return [int][Math]::Max(1, $sw.ElapsedMilliseconds)
        }
        return -1
    } catch { return -1 } finally { try { $c.Close() } catch { } }
}

# ---- outage detection: a small state machine, evaluated every 3 seconds
$out = @{ Active = $false; Pending = ''; Count = 0; PendingStart = $null; Start = $null; Cause = ''; ClearCount = 0; ClearAt = $null }
$outCsv = $null
try { $outCsv = New-Object CsvAppender('Start,End,DurationSec,Cause,AdapterType,Adapter') } catch { }
$lastOutEval = Get-Date

function Get-OutageCause($connected, $gw, $router, $inet) {
    if (-not $connected) { return 'no link' }
    if ($gw -and $router -eq -1) { return 'router' }
    if ($inet -eq -1) { return 'internet' }
    return ''
}

# returns $null, or @{ Type = 'start' | 'end'; ... }. Two bad rounds in a row start an outage, two good rounds end it.
function Step-Outage($st, [string]$cause, [datetime]$now) {
    $rank = @{ '' = 0; 'internet' = 1; 'router' = 2; 'no link' = 3 }
    if ($cause) {
        $st.ClearCount = 0
        if (-not $st.Active) {
            if ($st.Pending -ne $cause) { $st.Pending = $cause; $st.Count = 1; $st.PendingStart = $now } else { $st.Count = $st.Count + 1 }
            if ($st.Count -ge 2) {
                $st.Active = $true; $st.Start = $st.PendingStart; $st.Cause = $cause
                return @{ Type = 'start'; Start = $st.Start; Cause = $cause }
            }
            return $null
        }
        if ($rank[$cause] -gt $rank[[string]$st.Cause]) { $st.Cause = $cause }
        return $null
    }
    if (-not $st.Active) { $st.Pending = ''; $st.Count = 0; return $null }
    $st.ClearCount = $st.ClearCount + 1
    if ($st.ClearCount -eq 1) { $st.ClearAt = $now }
    if ($st.ClearCount -ge 2) {
        $st.Active = $false
        $rec = @{ Type = 'end'; Start = $st.Start; End = $st.ClearAt; Seconds = [int][Math]::Max(1, ($st.ClearAt - $st.Start).TotalSeconds); Cause = [string]$st.Cause }
        $st.Pending = ''; $st.Count = 0; $st.Cause = ''
        return $rec
    }
    return $null
}

function Save-Outage($rec) {
    if ($null -eq $outCsv) { return }
    $row = (@($rec.Start.ToString('yyyy-MM-dd HH:mm:ss', $inv), $rec.End.ToString('yyyy-MM-dd HH:mm:ss', $inv), [string]$rec.Seconds, [string]$rec.Cause, (Clean ([string]$S.LinkType)), (Clean ([string]$S.Adapter))) -join ',')
    [void]$outCsv.Write((Join-Path $DataDir 'outages.csv'), $row)
}

# ---- data usage per day (usage.json), counted from the adapter's own byte counters
$usage = @{}
$usagePath = Join-Path $DataDir 'usage.json'
$usageDirty = $false
$lastUsageSave = Get-Date
$lastUsageCalc = [datetime]'2000-01-01'
try {
    if (Test-Path -LiteralPath $usagePath) {
        $uj = (Get-Content -LiteralPath $usagePath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($null -ne $uj) { foreach ($pr in $uj.PSObject.Properties) { $usage[[string]$pr.Name] = @([double]$pr.Value[0], [double]$pr.Value[1]) } }
    }
} catch { $S.LastError = 'usage load: ' + $_.Exception.Message }

function Add-Usage([double]$rxBytes, [double]$txBytes) {
    $d = (Get-Date).ToString('yyyy-MM-dd', $inv)
    if (-not $usage.ContainsKey($d)) { $usage[$d] = @(0.0, 0.0) }
    $a = $usage[$d]
    $a[0] = $a[0] + $rxBytes
    $a[1] = $a[1] + $txBytes
    $script:usageDirty = $true
}

# the billing period starts on the reset day of this or the previous month
function Get-PeriodStart([datetime]$today, [int]$resetDay) {
    if ($resetDay -lt 1) { $resetDay = 1 }
    if ($resetDay -gt 28) { $resetDay = 28 }
    if ($today.Day -ge $resetDay) { return (New-Object DateTime -ArgumentList $today.Year, $today.Month, $resetDay) }
    $pm = $today.AddMonths(-1)
    return (New-Object DateTime -ArgumentList $pm.Year, $pm.Month, $resetDay)
}

function Update-UsageTotals {
    $today = (Get-Date).Date
    $ps = Get-PeriodStart $today ([int]$S.DataResetDay)
    $prx = 0.0; $ptx = 0.0; $trx = 0.0; $ttx = 0.0
    foreach ($k in @($usage.Keys)) {
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($k, 'yyyy-MM-dd', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
        if ($dt -ge $ps) { $prx += $usage[$k][0]; $ptx += $usage[$k][1] }
        if ($dt -eq $today) { $trx = $usage[$k][0]; $ttx = $usage[$k][1] }
    }
    $S.PeriodRx = $prx; $S.PeriodTx = $ptx; $S.TodayRx = $trx; $S.TodayTx = $ttx
    $S.PeriodStart = $ps.ToString('yyyy-MM-dd', $inv)
}

function Save-Usage {
    try {
        $keep = (Get-Date).Date.AddDays(-62)
        foreach ($k in @($usage.Keys)) {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParseExact($k, 'yyyy-MM-dd', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt) -and $dt -lt $keep) { $usage.Remove($k) }
        }
        $o = [ordered]@{}
        foreach ($k in @($usage.Keys | Sort-Object)) { $o[$k] = @([math]::Round($usage[$k][0], 0), [math]::Round($usage[$k][1], 0)) }
        $json = '{}'
        if ($o.Count -gt 0) { $json = ($o | ConvertTo-Json -Compress) }
        $tmp = $usagePath + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $usagePath -Force
        $script:usageDirty = $false
    } catch { $S.LastError = 'usage save: ' + $_.Exception.Message }
}
function Clean([string]$t) { return ($t -replace '[,"\r\n]', ' ').Trim() }
function F2($v) { if ($null -eq $v) { return '' }; return ([double]$v).ToString('0.##', $inv) }
function PingCell($v) { if ($null -eq $v -or [int]$v -lt 0) { return '' }; return [string]$v }

while (-not $S.Stop) {
    $nic = $null
    $cand = $null

    # ---- 1. adapter + live throughput of THIS PC (per second) ----
    try {
        $cand = Get-ActiveNic
        if ($cand) {
            $nic = $cand.Nic
            $S.Connected = $true
            $S.Adapter = [string]$cand.Name
            $S.LocalIp = [string]$cand.Ip
            $S.Mask = [string]$cand.Mask
            $S.Mac = [string]$cand.Mac
            $S.Gateway = [string]$cand.Gateway
            $S.IsWifi = [bool]$cand.IsWifi
            if ($cand.IsWifi) { $S.LinkType = 'Wi-Fi' } else { $S.LinkType = 'Ethernet' }
            $S.LinkSpeed = 0
            if ($cand.Speed -gt 0 -and $cand.Speed -lt 1000000000000) { $S.LinkSpeed = [int]($cand.Speed / 1000000) }
            $st = $nic.GetIPv4Statistics()
            $rx = [int64]$st.BytesReceived
            $tx = [int64]$st.BytesSent
            $ts = [System.Diagnostics.Stopwatch]::GetTimestamp()
            if ($prevName -eq $cand.Name -and $prevTs -gt 0) {
                $dt = ($ts - $prevTs) / $freq
                if ($dt -gt 0.2) {
                    $dr = $rx - $prevRx; if ($dr -lt 0) { $dr = 0 }
                    $du = $tx - $prevTx; if ($du -lt 0) { $du = 0 }
                    Add-Usage ([double]$dr) ([double]$du)
                    $S.Down = [math]::Round(($dr * 8.0) / $dt / 1000000.0, 2)
                    $S.Up   = [math]::Round(($du * 8.0) / $dt / 1000000.0, 2)
                }
            }
            $prevName = [string]$cand.Name; $prevRx = $rx; $prevTx = $tx; $prevTs = $ts
        } else {
            $S.Connected = $false
            $S.Adapter = ''; $S.LocalIp = ''; $S.Gateway = ''; $S.Mask = ''; $S.Mac = ''
            $S.IsWifi = $false; $S.LinkType = ''; $S.LinkSpeed = 0
            $S.Down = 0.0; $S.Up = 0.0
            $prevName = ''; $prevTs = [int64]0
        }
    } catch { $S.LastError = 'counters: ' + $_.Exception.Message }

    # ---- 1b. keep the last 120 samples for the 2-minute graph ----
    try {
        $dlHist.Add([double]$S.Down); $upHist.Add([double]$S.Up)
        while ($dlHist.Count -gt 120) { $dlHist.RemoveAt(0) }
        while ($upHist.Count -gt 120) { $upHist.RemoveAt(0) }
        $S.DlHist = $dlHist.ToArray()
        $S.UpHist = $upHist.ToArray()
    } catch { $S.LastError = 'history: ' + $_.Exception.Message }

    # ---- 2. Wi-Fi details every 2 seconds (only when the active adapter is wireless) ----
    try {
        if ($nic -and $cand.IsWifi) {
            if (((Get-Date) - $lastWlan).TotalSeconds -ge 2) {
                $lastWlan = Get-Date
                $info = Get-WlanInfo
                $blk = $null
                foreach ($b in $info.Blocks) { if ($b['Name'] -eq $cand.Name) { $blk = $b; break } }
                if (-not $blk -and $info.Blocks.Count -gt 0) { $blk = $info.Blocks[0] }
                $state = ''
                if ($blk) { $state = [string]$blk['State'] }
                if ($blk -and $state -match 'connected' -and $state -notmatch 'disconnected') {
                    $S.Note = ''
                    $S.Ssid  = [string]$blk['SSID']
                    $S.Bssid = [string]$blk['BSSID']
                    $S.Radio = [string]$blk['Radio type']
                    $sig = 0; $ch = 0; $rr = 0.0; $tr = 0.0
                    if ([int]::TryParse(([string]$blk['Signal'] -replace '[^\d]', ''), [ref]$sig)) { $S.Signal = $sig } else { $S.Signal = -1 }
                    if ([int]::TryParse(([string]$blk['Channel'] -replace '[^\d]', ''), [ref]$ch)) { $S.Channel = $ch } else { $S.Channel = 0 }
                    [void][double]::TryParse(([string]$blk['Receive rate (Mbps)']),  [ref]$rr)
                    [void][double]::TryParse(([string]$blk['Transmit rate (Mbps)']), [ref]$tr)
                    $S.RxRate = $rr; $S.TxRate = $tr
                    $band = [string]$blk['Band']
                    if (-not $band) {
                        if ($S.Channel -gt 0 -and $S.Channel -le 14) { $band = '2.4 GHz' }
                        elseif ($S.Channel -gt 14) { $band = '5 GHz' }
                    }
                    $S.Band = $band
                } else {
                    $S.Ssid = ''; $S.Bssid = ''; $S.Signal = -1; $S.Channel = 0; $S.Band = ''; $S.Radio = ''
                    $S.RxRate = 0; $S.TxRate = 0
                    $S.Note = $info.Note
                }
            }
        } else {
            $S.Ssid = ''; $S.Bssid = ''; $S.Signal = -1; $S.Channel = 0; $S.Band = ''; $S.Radio = ''
            $S.RxRate = 0; $S.TxRate = 0; $S.Note = ''
        }
    } catch { $S.LastError = 'wlan: ' + $_.Exception.Message }

    # ---- 3. Router ping every 3 seconds ----
    try {
        if ($S.Gateway) {
            if (((Get-Date) - $lastPing).TotalSeconds -ge 3) {
                $lastPing = Get-Date
                $reply = $null
                try { $reply = $ping.Send([string]$S.Gateway, 1000) } catch { $reply = $null }
                if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $S.RouterPing = [int]$reply.RoundtripTime
                } else {
                    $S.RouterPing = -1
                }
            }
        } else { $S.RouterPing = $null }
    } catch { $S.LastError = 'ping: ' + $_.Exception.Message }

    # ---- 4. Internet ping (Cloudflare 1.1.1.1) every 3 seconds ----
    try {
        if ($nic) {
            if (((Get-Date) - $lastInet).TotalSeconds -ge 3) {
                $lastInet = Get-Date
                $reply2 = $null
                try { $reply2 = $ping.Send('1.1.1.1', 1500) } catch { $reply2 = $null }
                if ($reply2 -and $reply2.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $S.InetPing = [int]$reply2.RoundtripTime
                    $S.InetVia = ''
                } else {
                    # ping got no answer: it may just be blocked, so try a normal web connection to two servers
                    $tc = Test-Tcp '1.1.1.1' 443 1000
                    if ($tc -lt 0) { $tc = Test-Tcp '8.8.8.8' 443 1000 }
                    if ($tc -ge 0) { $S.InetPing = $tc; $S.InetVia = 'tcp' } else { $S.InetPing = -1; $S.InetVia = '' }
                }
            }
        } else { $S.InetPing = $null }
    } catch { $S.LastError = 'inet ping: ' + $_.Exception.Message }

    # ---- 4b. outages (every 3 s; a long gap means the PC slept, which is not an outage)
    try {
        $nowO = Get-Date
        if (($nowO - $lastOutEval).TotalSeconds -ge 3) {
            if (($nowO - $lastOutEval).TotalSeconds -gt 30) {
                if ($out.Active) { $recS = @{ Start = $out.Start; End = $lastOutEval; Seconds = [int][Math]::Max(1, ($lastOutEval - $out.Start).TotalSeconds); Cause = [string]$out.Cause }; Save-Outage $recS; $S.LastOutage = $recS; $S.OutageSeq = [int]$S.OutageSeq + 1 }
                $out.Active = $false; $out.Pending = ''; $out.Count = 0; $out.ClearCount = 0; $out.Cause = ''
                $S.OutageActive = $false
            }
            $lastOutEval = $nowO
            $cause = Get-OutageCause $S.Connected $S.Gateway $S.RouterPing $S.InetPing
            $ev = Step-Outage $out $cause $nowO
            if ($null -ne $ev -and $ev.Type -eq 'start') { $S.OutageActive = $true; $S.OutageStart = $ev.Start }
            if ($null -ne $ev -and $ev.Type -eq 'end') { Save-Outage $ev; $S.OutageActive = $false; $S.LastOutage = $ev; $S.OutageSeq = [int]$S.OutageSeq + 1 }
            if ($out.Active) { $S.OutageCause = [string]$out.Cause; $S.OutageStart = $out.Start }
        }
    } catch { $S.LastError = 'outage: ' + $_.Exception.Message }

    # ---- 4c. data usage totals (every 5 s) and saving (every minute)
    try {
        if (((Get-Date) - $lastUsageCalc).TotalSeconds -ge 5) { $lastUsageCalc = Get-Date; Update-UsageTotals }
        if ($usageDirty -and ((Get-Date) - $lastUsageSave).TotalSeconds -ge 60) { $lastUsageSave = Get-Date; Save-Usage }
    } catch { $S.LastError = 'usage: ' + $_.Exception.Message }

    # ---- 5. history file (written here, never on the UI thread)
    try {
        if ($S.HistEnabled -and $null -ne $netCsv -and $S.Connected) {
            $nowD = Get-Date
            if (($nowD - $lastHist).TotalSeconds -ge [double]$S.HistInterval) {
                $lastHist = $nowD
                $sigCell = ''; if ($S.IsWifi -and [int]$S.Signal -ge 0) { $sigCell = [string]$S.Signal }
                $chCell = ''; if ($S.IsWifi -and [int]$S.Channel -gt 0) { $chCell = [string]$S.Channel }
                $row = (@($nowD.ToString('yyyy-MM-dd HH:mm:ss', $inv), (Clean ([string]$S.LinkType)), (Clean ([string]$S.Adapter)), (Clean ([string]$S.Ssid)),
                          $sigCell, $chCell, (Clean ([string]$S.Band)), [string]$S.LinkSpeed, (F2 $S.Down), (F2 $S.Up), (PingCell $S.RouterPing), (PingCell $S.InetPing)) -join ',')
                [void]$netCsv.Write((Join-Path $DataDir ('network-' + $nowD.ToString('yyyy-MM', $inv) + '.csv')), $row)
            }
        }
    } catch { $S.LastError = 'history file: ' + $_.Exception.Message }

    $ms = 1000
    while ($ms -gt 0 -and -not $S.Stop) { Start-Sleep -Milliseconds 100; $ms -= 100 }
}
try { if ($null -ne $netCsv) { [void]$netCsv.Flush((Join-Path $DataDir ('network-' + (Get-Date).ToString('yyyy-MM', $inv) + '.csv'))) } } catch { }
try { if ($out.Active) { Save-Outage @{ Start = $out.Start; End = (Get-Date); Seconds = [int][Math]::Max(1, ((Get-Date) - $out.Start).TotalSeconds); Cause = [string]$out.Cause } } } catch { }
try { if ($null -ne $outCsv) { [void]$outCsv.Flush((Join-Path $DataDir 'outages.csv')) } } catch { }
try { if ($usageDirty) { Save-Usage } } catch { }
'@

function New-WifiRunspace([string]$source, $argList, [string]$what) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($source)
    foreach ($a in $argList) { [void]$ps.AddArgument($a) }
    $h = $ps.BeginInvoke()
    Write-Log ($what + ' started.')
    return @{ Ps = $ps; Rs = $rs; Handle = $h }
}

function Start-WifiServices {
    if ($script:WifiRunning) { return }
    $script:Wifi['Stop'] = $false
    $script:WifiSamplerRun = New-WifiRunspace $script:WifiSamplerSource @($script:Wifi, $script:DataDir) 'Network sampler'
    $script:DetectorRun = New-WifiRunspace $script:DetectorSource @($script:Wifi, $script:DevQueue) 'Device detector'
    $script:WifiRunning = $true
    $script:NextDnsUtc = [DateTime]::UtcNow.AddSeconds(10)
}

function Stop-WifiServices {
    if (-not $script:WifiRunning) { return }
    $script:WifiRunning = $false
    $script:Wifi['Stop'] = $true
    $script:Wifi['FullCancel'] = $true
    try { Stop-SpeedRunner } catch { }
    foreach ($r in @($script:WifiSamplerRun, $script:DetectorRun)) {
        if ($null -eq $r) { continue }
        try { [void]$r.Ps.BeginStop($null, $null) } catch { }
        [void]$script:WifiOld.Add($r)           # disposed later, once the runspace has really finished
    }
    $script:WifiSamplerRun = $null; $script:DetectorRun = $null
    $w = $script:Wifi
    $w['Connected'] = $false; $w['Ssid'] = ''; $w['Signal'] = -1; $w['Down'] = 0.0; $w['Up'] = 0.0
    $w['RouterPing'] = $null; $w['InetPing'] = $null; $w['Adapter'] = ''; $w['LocalIp'] = ''; $w['Gateway'] = ''
    $w['IsWifi'] = $false; $w['LinkSpeed'] = 0; $w['DlHist'] = [double[]]@(); $w['UpHist'] = [double[]]@()
    Write-Log 'Network services stopped.'
}

function Clean-WifiOld {
    foreach ($r in @($script:WifiOld.ToArray())) {
        $done = $true
        try { $done = $r.Handle.IsCompleted } catch { $done = $true }
        if ($done) {
            try { $r.Ps.Dispose() } catch { }
            try { $r.Rs.Close(); $r.Rs.Dispose() } catch { }
            $script:WifiOld.Remove($r)
        }
    }
}

# ---- small helpers used by the Wi-Fi code
function Format-Mbps([double]$v) {
    if ($v -ge 100) { return (Fmt $v '0') }
    return (Fmt $v '0.0')
}

function Get-SignalColor([int]$pct) {
    if ($pct -ge 67) { return $script:Pal.Teal }
    if ($pct -ge 34) { return $script:Pal.Amber }
    return $script:Pal.Red
}

function Format-Ago([double]$sec) {
    if ($sec -lt 60) { return 'just now' }
    if ($sec -lt 3600) { return ('{0} min ago' -f [int][Math]::Floor($sec / 60)) }
    if ($sec -lt 86400) { return ('{0} h ago' -f [int][Math]::Floor($sec / 3600)) }
    return ('{0} d ago' -f [int][Math]::Floor($sec / 86400))
}

function Convert-ToUtc($v) {
    if ($null -eq $v -or ([string]$v) -eq '') { return [datetime]::MinValue }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    try {
        return [datetime]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch { return [datetime]::MinValue }
}

function Split-TextLines([string]$text, [int]$max) {
    $lines = @()
    $cur = ''
    foreach ($w in ($text -split '\s+')) {
        if (-not $w) { continue }
        if (($cur.Length + $w.Length + 1) -gt $max -and $cur) { $lines += $cur; $cur = $w }
        elseif ($cur) { $cur = $cur + ' ' + $w }
        else { $cur = $w }
    }
    if ($cur) { $lines += $cur }
    return $lines
}

# Short message as a popup (replaces the tray balloon of the original program)
function Show-Balloon([string]$title, [string]$text) {
    try {
        $a = [pscustomobject]@{
            Type = 'info'; Title = $title; Value = $null; ValueText = ''
            Lines = @(Split-TextLines $text 48 | Select-Object -First 3); Accent = $script:Pal.Teal
            Buttons = @(@{ Id = 'ok'; Text = 'OK'; Primary = $true })
        }
        Show-AlertPopup $a
    } catch { Write-Log ('Show-Balloon: ' + $_.Exception.Message) 'WARN' }
}

# ---------------------------------------------------------------- Wi-Fi assistant: devices on your network
# Background runspace: DHCP listener (UDP 67) + ARP poll (3 s) + ping sweep (20 s). Events reach the UI through a queue.
$script:DevFile      = Join-Path $script:DataDir 'devices.json'
$script:DevQueue     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Devices      = @{}
$script:DevicesDirty = $false
$script:LastDevSave  = [datetime]::UtcNow
$script:LastStatus   = @{}
$script:DevScroll    = 0
$script:DevRows      = @()
$script:DevPanelRect = [System.Drawing.Rectangle]::Empty

$script:DetectorSource = @'
param($S, $Q)

$ALL = [long]4294967295

function Convert-IpToLong([string]$ip) {
    $p = $ip.Split('.')
    if ($p.Length -ne 4) { return [long]0 }
    try { return ([long]$p[0] * 16777216) + ([long]$p[1] * 65536) + ([long]$p[2] * 256) + [long]$p[3] } catch { return [long]0 }
}

function Convert-LongToIp([long]$n) {
    return ('{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255))
}

function Convert-Mac([string]$raw) {
    if (-not $raw) { return $null }
    $h = ($raw -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($h.Length -ne 12) { return $null }
    return ($h -replace '(.{2})(?=.)', '$1:')
}

# broadcast, all-zero and multicast addresses are never devices
function Test-GoodMac([string]$mac) {
    if (-not $mac) { return $false }
    if ($mac -eq 'FF:FF:FF:FF:FF:FF') { return $false }
    if ($mac -eq '00:00:00:00:00:00') { return $false }
    $b0 = [Convert]::ToInt32($mac.Substring(0, 2), 16)
    if (($b0 -band 1) -eq 1) { return $false }
    return $true
}

# Parse a DHCP packet sent by a CLIENT (op = 1). Returns $null for anything else.
function Parse-Dhcp([byte[]]$b, [int]$n) {
    if ($n -lt 241) { return $null }
    if ($b[0] -ne 1) { return $null }
    if ($b[236] -ne 99 -or $b[237] -ne 130 -or $b[238] -ne 83 -or $b[239] -ne 99) { return $null }
    if ($b[2] -ne 6) { return $null }
    $mac = ((0..5 | ForEach-Object { $b[28 + $_].ToString('X2') }) -join ':')
    $ci = '{0}.{1}.{2}.{3}' -f $b[12], $b[13], $b[14], $b[15]
    $o = @{ Mac = $mac; Ciaddr = $ci; Type = 0; Host = ''; ReqIp = ''; Vendor = '' }
    $i = 240
    while ($i -lt $n) {
        $code = [int]$b[$i]
        if ($code -eq 255) { break }
        if ($code -eq 0) { $i++; continue }
        if (($i + 1) -ge $n) { break }
        $len = [int]$b[$i + 1]
        $d = $i + 2
        if (($d + $len) -gt $n) { break }
        if ($code -eq 53 -and $len -ge 1) { $o.Type = [int]$b[$d] }
        elseif ($code -eq 12) { $o.Host = ([Text.Encoding]::ASCII.GetString($b, $d, $len) -replace '[^\x20-\x7E]', '').Trim() }
        elseif ($code -eq 50 -and $len -eq 4) { $o.ReqIp = '{0}.{1}.{2}.{3}' -f $b[$d], $b[$d + 1], $b[$d + 2], $b[$d + 3] }
        elseif ($code -eq 60) { $o.Vendor = ([Text.Encoding]::ASCII.GetString($b, $d, $len) -replace '[^\x20-\x7E]', '').Trim() }
        $i = $d + $len
    }
    return $o
}

function Post-Status([string]$key, [string]$text) {
    $Q.Enqueue(@{ T = 'status'; Key = $key; Text = $text })
}

# Network range to scan: our own /24 (never larger)
function Get-Subnet {
    $ip = [string]$S.LocalIp
    if (-not $ip) { return $null }
    $ipL = Convert-IpToLong $ip
    $mkL = Convert-IpToLong ([string]$S.Mask)
    if ($mkL -lt 4294967040) { $mkL = [long]4294967040 }
    $net = $ipL -band $mkL
    $bc = $net -bor ((-bnot $mkL) -band $ALL)
    return @{ Net = $net; Mask = $mkL; First = ($net + 1); Last = ($bc - 1) }
}

function Invoke-Sweep($sub) {
    $selfIp = [string]$S.LocalIp
    $tasks = New-Object 'System.Collections.Generic.List[object]'
    $pings = New-Object 'System.Collections.Generic.List[System.Net.NetworkInformation.Ping]'
    for ($k = $sub.First; $k -le $sub.Last; $k++) {
        $ip = Convert-LongToIp $k
        if ($ip -eq $selfIp) { continue }
        $p = New-Object System.Net.NetworkInformation.Ping
        $pings.Add($p)
        try { $tasks.Add($p.SendPingAsync($ip, 800)) } catch { }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks.ToArray(), 4000) } catch { }
    $alive = 0
    foreach ($t in $tasks) {
        try {
            if ($t.IsCompleted -and -not $t.IsFaulted -and -not $t.IsCanceled -and $t.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $alive++ }
        } catch { }
    }
    foreach ($p in $pings) { try { $p.Dispose() } catch { } }
    return $alive
}

function Open-DhcpSocket {
    $sk = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $sk.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $sk.EnableBroadcast = $true
        $sk.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 67)))
    } catch { $sk.Close(); throw }
    return $sk
}

$sock = $null
$nextDhcpTry = [datetime]'2000-01-01'
$lastArp = [datetime]'2000-01-01'
$lastSweep = [datetime]'2000-01-01'
$buf = New-Object byte[] 2048

try {
    while (-not $S.Stop) {

        # ---- 1. DHCP listener (UDP 67): who is asking for an address? ----
        if ($null -eq $sock -and ((Get-Date) -ge $nextDhcpTry)) {
            try {
                $sock = Open-DhcpSocket
                Post-Status 'dhcp' 'DHCP listener on UDP 67 is running.'
            } catch {
                $sock = $null
                $nextDhcpTry = (Get-Date).AddSeconds(60)
                Post-Status 'dhcp' ('DHCP listener unavailable (' + $_.Exception.Message + '). Using ARP and ping sweep only.')
            }
        }
        if ($sock) {
            try {
                if ($sock.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead)) {
                    $guard = 0
                    while ($sock.Available -gt 0 -and $guard -lt 50) {
                        $guard++
                        [System.Net.EndPoint]$remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                        $cnt = $sock.ReceiveFrom($buf, [ref]$remote)
                        $o = Parse-Dhcp $buf $cnt
                        if ($o -and (Test-GoodMac $o.Mac)) {
                            $ip = ''
                            if ($o.ReqIp) { $ip = $o.ReqIp }
                            elseif ($o.Ciaddr -and $o.Ciaddr -ne '0.0.0.0') { $ip = $o.Ciaddr }
                            $Q.Enqueue(@{ T = 'dhcp'; Mac = $o.Mac; Ip = $ip; Hostname = $o.Host; Vendor = $o.Vendor; Msg = [int]$o.Type; Src = 'dhcp' })
                        }
                    }
                }
            } catch {
                try { $sock.Close() } catch { }
                $sock = $null
                $nextDhcpTry = (Get-Date).AddSeconds(5)
                Post-Status 'dhcp' ('DHCP listener stopped (' + $_.Exception.Message + ').')
            }
        } else {
            Start-Sleep -Milliseconds 200
        }

        $sub = Get-Subnet

        # ---- 2. Ping sweep of our /24, every 20 seconds ----
        if ($sub -and (((Get-Date) - $lastSweep).TotalSeconds -ge 20)) {
            $lastSweep = Get-Date
            try {
                $alive = Invoke-Sweep $sub
                Post-Status 'sweep' ('Ping sweep works (' + (Convert-LongToIp $sub.First) + ' - ' + (Convert-LongToIp $sub.Last) + ').')
                $S.SweepReplies = [int]$alive
            } catch { Post-Status 'sweepErr' ('Ping sweep error: ' + $_.Exception.Message) }
            $lastArp = [datetime]'2000-01-01'
        }

        # ---- 3. ARP neighbour poll, every 3 seconds ----
        if ($sub -and (((Get-Date) - $lastArp).TotalSeconds -ge 3)) {
            $lastArp = Get-Date
            if ($S.Mac -and $S.LocalIp) {
                $Q.Enqueue(@{ T = 'seen'; Mac = [string]$S.Mac; Ip = [string]$S.LocalIp; Src = 'self' })
            }
            try {
                $rows = Get-NetNeighbor -AddressFamily IPv4 -InterfaceAlias ([string]$S.Adapter) -ErrorAction SilentlyContinue
                foreach ($r in $rows) {
                    # only entries confirmed recently count as "answered"
                    if ([string]$r.State -ne 'Reachable') { continue }
                    $mac = Convert-Mac ([string]$r.LinkLayerAddress)
                    if (-not (Test-GoodMac $mac)) { continue }
                    $ip = [string]$r.IPAddress
                    $ipL = Convert-IpToLong $ip
                    if (($ipL -band $sub.Mask) -ne $sub.Net) { continue }
                    if ($ipL -lt $sub.First -or $ipL -gt $sub.Last) { continue }
                    $Q.Enqueue(@{ T = 'seen'; Mac = $mac; Ip = $ip; Src = 'arp' })
                }
            } catch { Post-Status 'arp' ('ARP poll error: ' + $_.Exception.Message) }
        }
    }
} finally {
    if ($sock) { try { $sock.Close() } catch { } }
}
'@

# ---------- Device store (devices.json, local only) ------------------------
function Test-GoodMac([string]$mac) {
    if (-not $mac) { return $false }
    if ($mac -eq 'FF:FF:FF:FF:FF:FF' -or $mac -eq '00:00:00:00:00:00') { return $false }
    try { $b0 = [Convert]::ToInt32($mac.Substring(0, 2), 16) } catch { return $false }
    if (($b0 -band 1) -eq 1) { return $false }
    return $true
}

function Load-Devices {
    try {
        if (-not (Test-Path -LiteralPath $script:DevFile)) { return }
        $raw = Get-Content -LiteralPath $script:DevFile -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return }
        $parsed = $raw | ConvertFrom-Json
        $items = @()
        foreach ($x in @($parsed)) { if ($x -is [array]) { $items += $x } else { $items += $x } }
        foreach ($j in $items) {
            if (-not $j.Mac) { continue }
            $mac = [string]$j.Mac
            $script:Devices[$mac] = @{
                Mac = $mac; Ip = [string]$j.Ip; Name = [string]$j.Name
                Hostname = [string]$j.Hostname; Vendor = [string]$j.Vendor
                Private = [bool]$j.Private
                FirstSeen = (Convert-ToUtc $j.FirstSeen); LastSeen = (Convert-ToUtc $j.LastSeen)
            }
        }
        Write-Log ('Loaded ' + $script:Devices.Count + ' known device(s).')
    } catch { Write-Log ('Load-Devices failed: ' + $_.Exception.Message) 'WARN' }
}

function Save-Devices {
    try {
        $out = @()
        foreach ($d in $script:Devices.Values) {
            $out += [pscustomobject]@{
                Mac = $d.Mac; Name = $d.Name; Hostname = $d.Hostname; Vendor = $d.Vendor
                Ip = $d.Ip; Private = $d.Private; Guess = (Get-DeviceGuess $d)
                FirstSeen = $d.FirstSeen.ToString('o'); LastSeen = $d.LastSeen.ToString('o')
            }
        }
        if ($out.Count -eq 0) { $json = '[]' } else { $json = ConvertTo-Json -InputObject $out -Depth 3 }
        $tmp = $script:DevFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:DevFile -Force
        $script:DevicesDirty = $false
        $script:LastDevSave = [datetime]::UtcNow
    } catch { Write-Log ('Save-Devices failed: ' + $_.Exception.Message) 'WARN' }
}

# ---------- Device helpers --------------------------------------------------
function Test-DeviceOnline($d) {
    return ((([datetime]::UtcNow - $d.LastSeen).TotalSeconds) -le 50)
}

# Name shown for a device: your own name, else automatic (This PC / Router), else empty
function Get-DeviceName($d) {
    if ($d.Name) { return [string]$d.Name }
    $W = $script:Wifi
    if ($W.Mac -and $d.Mac -eq $W.Mac) { return ('This PC (' + $env:COMPUTERNAME + ')') }
    if ($W.Gateway -and $d.Ip -eq $W.Gateway) { return 'Router' }
    return ''
}

function Get-UnnamedOnlineCount {
    $n = 0
    foreach ($d in $script:Devices.Values) {
        if ((Test-DeviceOnline $d) -and -not (Get-DeviceName $d)) { $n++ }
    }
    return $n
}

function Process-DeviceEvent($e) {
    if ($e.T -eq 'status') {
        $k = [string]$e.Key
        if ($script:LastStatus[$k] -ne [string]$e.Text) {
            $script:LastStatus[$k] = [string]$e.Text
            Write-Log ('Detector: ' + $e.Text)
        }
        return
    }
    $mac = [string]$e.Mac
    if (-not (Test-GoodMac $mac)) { return }
    $now = [datetime]::UtcNow
    $d = $script:Devices[$mac]
    $kind = ''
    $gap = 0.0
    if ($null -eq $d) {
        $priv = ((([Convert]::ToInt32($mac.Substring(0, 2), 16)) -band 2) -ne 0)
        $d = @{ Mac = $mac; Ip = ''; Name = ''; Hostname = ''; Vendor = ''; Private = $priv; FirstSeen = $now; LastSeen = $now }
        $script:Devices[$mac] = $d
        $script:DevicesDirty = $true
        $kind = 'new'
    } else {
        $gap = ($now - $d.LastSeen).TotalSeconds
    }
    if ($e.Ip -and $d.Ip -ne [string]$e.Ip) { $d.Ip = [string]$e.Ip; $script:DevicesDirty = $true }
    if ($e.Hostname -and $d.Hostname -ne [string]$e.Hostname) { $d.Hostname = [string]$e.Hostname; $script:DevicesDirty = $true }
    if ($e.Vendor -and $d.Vendor -ne [string]$e.Vendor) { $d.Vendor = [string]$e.Vendor; $script:DevicesDirty = $true }
    if ($e.Msg -ne 7) { $d.LastSeen = $now }   # 7 = DHCP RELEASE (device is leaving)

    if (-not $kind -and $gap -gt 300) { $kind = 'back' }
    if ($kind) { Log-DeviceEvent $d $kind }
    if ($kind -and -not (Get-DeviceName $d)) { On-DeviceAlert $d $kind }
}

function Process-DeviceQueue {
    $count = 0
    $item = $null
    while ($count -lt 300 -and $script:DevQueue.TryDequeue([ref]$item)) {
        $count++
        try { Process-DeviceEvent $item } catch { Write-Log ('Device event error: ' + $_.Exception.Message) 'ERROR' }
    }
    return $count
}

# ---------- Naming dialog ---------------------------------------------------
function Show-NameDialog([string]$mac) {
    $d = $script:Devices[$mac]
    if ($null -eq $d) { return }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Name this device'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 380), (S 222))

    $lines = @()
    $lines += ('IP address:   ' + $d.Ip)
    $lines += ('MAC address:  ' + $d.Mac)
    if ($d.Hostname) { $lines += ('Calls itself:   ' + $d.Hostname) }
    if ($d.Vendor)   { $lines += ('Vendor class:  ' + $d.Vendor) }
    if ($d.Private)  { $lines += 'Private MAC: this device hides its real hardware address on the network.' }
    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point((S 14), (S 12))
    $info.Size = New-Object System.Drawing.Size((S 352), (S 112))
    $info.Text = ($lines -join "`r`n")
    $dlg.Controls.Add($info)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point((S 14), (S 130))
    $lbl.Size = New-Object System.Drawing.Size((S 352), (S 18))
    $lbl.Text = 'Name (for example: Mum''s phone, Smart TV):'
    $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point((S 14), (S 150))
    $tb.Size = New-Object System.Drawing.Size((S 352), (S 24))
    $tb.MaxLength = 40
    $tb.Text = [string]$d.Name
    $dlg.Controls.Add($tb)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Save'
    $btnSave.Location = New-Object System.Drawing.Point((S 14), (S 184))
    $btnSave.Size = New-Object System.Drawing.Size((S 100), (S 28))
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnSave)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = 'Clear name'
    $btnClear.Location = New-Object System.Drawing.Point((S 122), (S 184))
    $btnClear.Size = New-Object System.Drawing.Size((S 110), (S 28))
    $btnClear.add_Click({ $tb.Text = ''; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($btnClear)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point((S 240), (S 184))
    $btnCancel.Size = New-Object System.Drawing.Size((S 100), (S 28))
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel

    try {
        $res = $dlg.ShowDialog()
        if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
            $d.Name = $tb.Text.Trim()
            $script:DevicesDirty = $true
            Save-Devices
            Write-Log ('Device named: ' + $d.Mac + ' = "' + $d.Name + '"')
        }
    } finally {
        $dlg.Dispose()
        $script:Form.Invalidate()
    }
}

# ---------- "Block..." help: copy the MAC and explain how to block it -------
function Show-BlockHelp([string]$mac) {
    try { [System.Windows.Forms.Clipboard]::SetText($mac) } catch { Write-Log ('Clipboard failed: ' + $_.Exception.Message) 'WARN' }
    $gw = [string]$script:Wifi.Gateway
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Block this device'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 460), (S 330))

    $routerLine = 'Open your router''s app, or its admin page in a browser.'
    if ($gw) { $routerLine = 'Open your router''s app, or its admin page: http://' + $gw }
    $text = @(
        ('MAC address (copied to the clipboard):  ' + $mac),
        '',
        'A PC cannot remove a device from your network. Only your router can.',
        '',
        ('1.  ' + $routerLine),
        '2.  Look for "Connected devices", "Device list", "Access control" or "MAC filter".',
        '3.  Find the device with this MAC address (paste it into the search box if you can) and choose Block or Deny.',
        '4.  Not sure who it is? Change the Wi-Fi password. This disconnects everyone, then reconnect your own devices.'
    ) -join "`r`n"
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point((S 16), (S 14))
    $lbl.Size = New-Object System.Drawing.Size((S 428), (S 260))
    $lbl.Text = $text
    $dlg.Controls.Add($lbl)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point((S 344), (S 286))
    $btnClose.Size = New-Object System.Drawing.Size((S 100), (S 30))
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnClose)
    $dlg.CancelButton = $btnClose

    if ($gw) {
        $btnOpen = New-Object System.Windows.Forms.Button
        $btnOpen.Text = 'Open router page'
        $btnOpen.Location = New-Object System.Drawing.Point((S 196), (S 286))
        $btnOpen.Size = New-Object System.Drawing.Size((S 140), (S 30))
        $btnOpen.add_Click({ try { Start-Process ('http://' + $gw) } catch { } })
        $dlg.Controls.Add($btnOpen)
    }
    try { [void]$dlg.ShowDialog() } finally { $dlg.Dispose() }
}

# ---------- Sorting / formatting for the device list ----------------------------
function Get-IpSortKey([string]$ip) {
    if (-not $ip) { return [long]0 }
    $p = $ip.Split('.')
    if ($p.Length -ne 4) { return [long]0 }
    try { return ([long]$p[0] * 16777216) + ([long]$p[1] * 65536) + ([long]$p[2] * 256) + [long]$p[3] } catch { return [long]0 }
}

function Get-SortedDevices {
    $list = @($script:Devices.Values)
    return @($list | Sort-Object -Property @(
        @{ Expression = { if (Test-DeviceOnline $_) { 0 } else { 1 } } },
        @{ Expression = { if (Test-DeviceOnline $_) { Get-IpSortKey $_.Ip } else { -1 * $_.LastSeen.Ticks } } }
    ))
}

function Get-DeviceRowAt([System.Drawing.Point]$pt) {
    if (-not $script:NetRect.Contains($pt)) { return $null }
    foreach ($r in $script:DevRows) { if ($r.Rect.Contains($pt)) { return $r } }
    return $null
}

# ---------------------------------------------------------------- Wi-Fi assistant: speed test (curl.exe, Cloudflare)
$script:SpeedQueue       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:SpeedRunning     = $false
$script:SpeedManual      = $false
$script:SpeedVerify      = $false
$script:SpeedStartUtc    = [datetime]::UtcNow
$script:NextAutoUtc      = [datetime]::UtcNow.AddSeconds(75)
$script:VerifyDueUtc     = $null
$script:LastSlowAlertUtc = [datetime]'2000-01-01'

# Background job: download from Cloudflare with curl.exe, bound to the Wi-Fi adapter's IP
$script:SpeedSource = @'
param($Ip, $Q, $S)

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) { $curl = 'curl.exe' }

function Run-Curl([string]$bind, [long]$bytes) {
    $a = '-s -S -o NUL -w "%{http_code};%{size_download};%{time_total};%{time_starttransfer}" --connect-timeout 8 --max-time 30 '
    if ($bind) { $a += ('--interface ' + $bind + ' ') }
    $a += ('"https://speed.cloudflare.com/__down?bytes=' + $bytes + '"')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $curl
    $psi.Arguments = $a
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $S.CurlPid = $p.Id
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $S.CurlPid = 0
    return @{ Exit = $p.ExitCode; Out = $out.Trim(); Err = $err.Trim() }
}

function Parse-Num([string]$t) {
    $v = 0.0
    [void][double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
    return $v
}

try {
    $sizes = @(25000000, 10000000, 5000000, 2000000)      # 403 = refused -> try a smaller file
    $bind = [string]$Ip
    $refused = 0
    foreach ($bytes in $sizes) {
        $res = Run-Curl $bind $bytes
        if ($res.Exit -eq 45 -and $bind) { $bind = ''; $res = Run-Curl '' $bytes }   # could not bind: retry unbound
        $parts = $res.Out -split ';'
        $code = 0; $size = 0.0; $tt = 0.0; $tst = 0.0
        if ($parts.Length -ge 4) {
            $code = [int](Parse-Num $parts[0]); $size = Parse-Num $parts[1]; $tt = Parse-Num $parts[2]; $tst = Parse-Num $parts[3]
        }
        if ($code -eq 403) { $refused++; continue }
        if ($size -gt 0 -and ($code -eq 200 -or $res.Exit -eq 28)) {
            $dur = $tt - $tst
            if ($dur -lt 0.15) { $dur = $tt }
            if ($dur -gt 0) {
                $mbps = [math]::Round(($size * 8.0) / $dur / 1000000.0, 2)
                $Q.Enqueue(@{ T = 'speed'; Status = 'ok'; Mbps = $mbps; Bytes = [long]$size; Secs = [math]::Round($dur, 2); Retried = ($refused -gt 0) })
                return
            }
        }
        $msg = $res.Err
        if (-not $msg) { $msg = 'curl exit code ' + $res.Exit + ', HTTP ' + $code }
        $Q.Enqueue(@{ T = 'speed'; Status = 'error'; Msg = $msg })
        return
    }
    $Q.Enqueue(@{ T = 'speed'; Status = 'refused' })
} catch {
    $Q.Enqueue(@{ T = 'speed'; Status = 'error'; Msg = $_.Exception.Message })
}
'@

function Start-SpeedTest([bool]$manual, [bool]$verify = $false) {
    if ($script:SpeedRunning) {
        if ($manual) { Show-Balloon 'Speed test' 'A speed test is already running.' }
        return
    }
    $W = $script:Wifi
    if (-not $W.Connected -or -not $W.LocalIp) {
        if ($manual) { [void](Show-SpeedPopup @{ Type = 'speed'; Kind = 'error'; Msg = 'No network connection.'; Limit = [double]$script:Settings['SlowLimit'] }) }
        return
    }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:SpeedSource).AddArgument([string]$W.LocalIp).AddArgument($script:SpeedQueue).AddArgument($W)
        $script:SpeedRs = $rs
        $script:SpeedPs = $ps
        $script:SpeedManual = $manual
        $script:SpeedVerify = $verify
        $script:SpeedStartUtc = [datetime]::UtcNow
        $script:SpeedRunning = $true
        [void]$ps.BeginInvoke()
        Write-Log ('Speed test started (manual=' + $manual + ', verify=' + $verify + ', bound to ' + $W.LocalIp + ').')
        $script:Form.Invalidate()
    } catch {
        $script:SpeedRunning = $false
        Write-Log ('Speed test could not start: ' + $_.Exception.Message) 'ERROR'
    }
}

function Stop-SpeedRunner {
    try { if ($script:SpeedPs) { [void]$script:SpeedPs.BeginStop($null, $null) } } catch { }
    try {
        $cp = [int]$script:Wifi.CurlPid
        if ($cp -gt 0) { Stop-Process -Id $cp -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Show-SpeedPopup($a) {
    $limit = [double]$a.Limit
    $lines = @()
    $big = ''
    $accent = $script:Pal.Amber
    $kind = [string]$a.Kind
    if ($kind -eq 'slow' -or $kind -eq 'fast') {
        $big = (Format-Mbps ([double]$a.Mbps)) + ' Mbps'
        if ($kind -eq 'slow') {
            $accent = $script:Pal.Red
            if ($a.Reason -eq 'manual') { $title = 'Your internet is slow'; $lines += ('Below your ' + $limit + ' Mbps limit.') }
            else { $title = 'Slow internet!'; $lines += ('Below ' + $limit + ' Mbps in 2 tests, 20 seconds apart.') }
        } else {
            $accent = $script:Pal.Teal
            if ($a.Reason -eq 'recovered') { $title = 'Speed is back!'; $lines += 'Your internet recovered from slow.' }
            elseif ($a.Reason -eq 'firstday') { $title = 'Good speed today'; $lines += 'First good test of the day.' }
            else { $title = 'Speed test result'; $lines += ('Above your ' + $limit + ' Mbps limit. Looks good.') }
        }
        if ($a.Retried) { $lines += 'Used a smaller file (server refused the bigger one).' }
    } elseif ($kind -eq 'refused') {
        $title = 'Test refused by the server'
        $big = 'Refused'
        $lines += 'Cloudflare said no (HTTP 403) to every file size.'
        $lines += 'This is NOT a slow connection. Try again later.'
    } else {
        $title = 'Speed test failed'
        $big = '--'
        $m = [string]$a.Msg
        if ($m.Length -gt 56) { $m = $m.Substring(0, 56) }
        $lines += $m
    }
    $item = [pscustomobject]@{
        Type = 'speed'; Mac = ''; Title = $title; Value = $null; ValueText = $big; Accent = $accent; Lines = $lines
        Buttons = @(@{ Id = 'again'; Text = 'Test again' }, @{ Id = 'ok'; Text = 'OK'; Primary = $true })
    }
    Show-AlertPopup $item
    Write-Log ('Speed popup shown [' + $kind + '].')
    return $true
}

function Save-LastSpeed([double]$mbps) {
    $script:Settings['LastSpeed'] = $mbps
    $script:Settings['LastSpeedUtc'] = [datetime]::UtcNow.ToString('o')
    Save-Settings
}

function Handle-SpeedResult($r) {
    $script:SpeedRunning = $false
    try { if ($script:SpeedPs) { $script:SpeedPs.Dispose() } } catch { }
    try { if ($script:SpeedRs) { $script:SpeedRs.Close(); $script:SpeedRs.Dispose() } } catch { }
    $manual = $script:SpeedManual
    $verify = $script:SpeedVerify
    $W = $script:Wifi
    $limit = [double]$script:Settings['SlowLimit']
    $now = [datetime]::UtcNow
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $status = [string]$r.Status
    if ($manual) { $srcName = 'manual' } elseif ($verify) { $srcName = 'auto (confirm)' } else { $srcName = 'auto' }
    if ($status -eq 'ok') { Log-SpeedRow 'ok' $r.Mbps $srcName $r.Bytes $r.Secs }
    elseif ($status -eq 'refused') { Log-SpeedRow 'refused' $null $srcName $null $null }
    else { Log-SpeedRow 'error' $null $srcName $null $null }

    if ($status -eq 'ok') {
        $mbps = [double]$r.Mbps
        Write-Log ('Speed test result: ' + $mbps + ' Mbps (' + $r.Bytes + ' bytes in ' + $r.Secs + ' s, retried=' + $r.Retried + ', manual=' + $manual + ', verify=' + $verify + ', limit=' + $limit + ').')
        $W['LastSpeed'] = $mbps
        $W['LastSpeedTime'] = $now
        $W['LastSpeedText'] = 'just now'
        Save-LastSpeed $mbps
        $slow = ($mbps -lt $limit)

        if ($manual) {
            $script:VerifyDueUtc = $null
            if (-not $slow) {
                $script:Settings['SlowActive'] = $false
                $script:Settings['LastFastDate'] = $today
                Save-Settings
            }
            if ($slow) { $k = 'slow' } else { $k = 'fast' }
            [void](Show-SpeedPopup @{ Type = 'speed'; Kind = $k; Reason = 'manual'; Mbps = $mbps; Limit = $limit; Retried = [bool]$r.Retried })
        } elseif ($slow) {
            if ($verify) {
                # second slow result in a row -> real slow alert (at most once every 15 minutes)
                $script:VerifyDueUtc = $null
                $script:Settings['SlowActive'] = $true
                Save-Settings
                if ((($now - $script:LastSlowAlertUtc).TotalMinutes) -ge 15) {
                    $script:LastSlowAlertUtc = $now
                    Request-Alert @{ Type = 'speed'; Kind = 'slow'; Reason = 'auto'; Mbps = $mbps; Limit = $limit; Retried = [bool]$r.Retried }
                } else {
                    Write-Log 'Slow alert skipped (one every 15 minutes).'
                }
            } else {
                # first slow result: double-check in 20 seconds
                $script:VerifyDueUtc = $now.AddSeconds(20)
                Write-Log 'Slow result - confirming with a second test in 20 seconds.'
            }
        } else {
            $script:VerifyDueUtc = $null
            if ($script:Settings['SlowActive']) {
                $script:Settings['SlowActive'] = $false
                $script:Settings['LastFastDate'] = $today
                Save-Settings
                Request-Alert @{ Type = 'speed'; Kind = 'fast'; Reason = 'recovered'; Mbps = $mbps; Limit = $limit; Retried = [bool]$r.Retried }
            } elseif ([string]$script:Settings['LastFastDate'] -ne $today) {
                $script:Settings['LastFastDate'] = $today
                Save-Settings
                Request-Alert @{ Type = 'speed'; Kind = 'fast'; Reason = 'firstday'; Mbps = $mbps; Limit = $limit; Retried = [bool]$r.Retried }
            }
        }
    } elseif ($status -eq 'refused') {
        # a refused test is never "slow"
        Write-Log 'Speed test refused by the server (HTTP 403 for every size).' 'WARN'
        $script:VerifyDueUtc = $null
        $W['LastSpeed'] = $null
        $W['LastSpeedText'] = 'server refused'
        if ($manual) { [void](Show-SpeedPopup @{ Type = 'speed'; Kind = 'refused'; Limit = $limit }) }
    } else {
        Write-Log ('Speed test failed: ' + $r.Msg) 'WARN'
        $script:VerifyDueUtc = $null
        if ($manual) { [void](Show-SpeedPopup @{ Type = 'speed'; Kind = 'error'; Msg = [string]$r.Msg; Limit = $limit }) }
    }
    $script:Form.Invalidate()
}

# once per second: collect results and schedule automatic tests
function Update-SpeedScheduler {
    $item = $null
    while ($script:SpeedQueue.TryDequeue([ref]$item)) {
        try { Handle-SpeedResult $item } catch { Write-Log ('Speed result error: ' + $_.Exception.Message) 'ERROR' }
    }
    $now = [datetime]::UtcNow
    if ($script:SpeedRunning -and (($now - $script:SpeedStartUtc).TotalSeconds -gt 150)) {
        Write-Log 'Speed test took too long - giving up.' 'WARN'
        Stop-SpeedRunner
        $script:SpeedRunning = $false
        $script:VerifyDueUtc = $null
    }
    if (-not $script:SpeedRunning) {
        if ($script:VerifyDueUtc -and $now -ge $script:VerifyDueUtc) {
            $script:VerifyDueUtc = $null
            Start-SpeedTest $false $true
        } elseif ($script:Settings['AutoSpeedTest'] -and $now -ge $script:NextAutoUtc) {
            if ($script:Wifi.Connected) {
                $script:NextAutoUtc = $now.AddMinutes(30)
                Start-SpeedTest $false $false
            } else {
                $script:NextAutoUtc = $now.AddSeconds(60)
            }
        }
    }
    # "last speed test" tile text
    $W = $script:Wifi
    if ($null -ne $W.LastSpeed -and $W.LastSpeedTime) {
        $W['LastSpeedText'] = Format-Ago (($now - [datetime]$W.LastSpeedTime).TotalSeconds)
    }
}

function Restore-LastSpeed {
    try {
        if ([double]$script:Settings['LastSpeed'] -gt 0 -and $script:Settings['LastSpeedUtc']) {
            $script:Wifi['LastSpeed'] = [double]$script:Settings['LastSpeed']
            $script:Wifi['LastSpeedTime'] = Convert-ToUtc $script:Settings['LastSpeedUtc']
        }
    } catch { }
}

# ---------------------------------------------------------------- Wi-Fi assistant: DNS Shield (scam filter check)
$script:DnsQueue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Dns         = @{ Shield = 'unknown'; Summary = 'Checking your DNS servers...'; Servers = @(); At = $null }
$script:DnsRunning  = $false
$script:DnsStartUtc = [datetime]::UtcNow
$script:NextDnsUtc  = [datetime]::UtcNow.AddSeconds(10)
$script:FixProc     = $null
$script:FixMode     = ''
$script:FixStartUtc = [datetime]::UtcNow
$script:DnsChoice   = ''

# Background job: read DNS servers, classify them, test that they answer
$script:DnsSource = @'
param($Q, $WifiAlias)

function New-DnsTables {
    $f = @{}; $p = @{}
    $filterList = @(
        @('Cloudflare (malware filter)', '1.1.1.2', '1.0.0.2', '2606:4700:4700::1112', '2606:4700:4700::1002'),
        @('Cloudflare (family filter)', '1.1.1.3', '1.0.0.3', '2606:4700:4700::1113', '2606:4700:4700::1003'),
        @('Quad9 (malware filter)', '9.9.9.9', '149.112.112.112', '9.9.9.11', '149.112.112.11', '2620:fe::fe', '2620:fe::9', '2620:fe::11', '2620:fe::fe:11'),
        @('AdGuard', '94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'),
        @('AdGuard (family filter)', '94.140.14.15', '94.140.15.16', '2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff'),
        @('CleanBrowsing', '185.228.168.9', '185.228.169.9', '185.228.168.10', '185.228.169.11', '185.228.168.168', '185.228.169.168', '2a0d:2a00:1::2', '2a0d:2a00:2::2'),
        @('OpenDNS FamilyShield', '208.67.222.123', '208.67.220.123')
    )
    $plainList = @(
        @('Google DNS', '8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'),
        @('Cloudflare (no filter)', '1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'),
        @('Quad9 (no filter)', '9.9.9.10', '149.112.112.10', '2620:fe::10'),
        @('OpenDNS', '208.67.222.222', '208.67.220.220'),
        @('AdGuard (no filter)', '94.140.14.140', '94.140.14.141')
    )
    foreach ($row in $filterList) { for ($i = 1; $i -lt $row.Count; $i++) { $f[([System.Net.IPAddress]::Parse($row[$i])).ToString()] = $row[0] } }
    foreach ($row in $plainList)  { for ($i = 1; $i -lt $row.Count; $i++) { $p[([System.Net.IPAddress]::Parse($row[$i])).ToString()] = $row[0] } }
    return @{ Filter = $f; Plain = $p }
}

function Test-PrivateV4([string]$ip) {
    $o = $ip.Split('.')
    if ($o.Length -ne 4) { return $false }
    $a = [int]$o[0]; $b = [int]$o[1]
    if ($a -eq 10) { return $true }
    if ($a -eq 192 -and $b -eq 168) { return $true }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
    if ($a -eq 169 -and $b -eq 254) { return $true }
    return $false
}

# Classify one DNS server address. $v6Prefixes = list of 8-byte prefixes (/64) of this adapter's IPv6 addresses.
function Get-DnsClass([string]$ip, $tables, $v6Prefixes) {
    $addr = [System.Net.IPAddress]::Parse($ip)
    $canon = $addr.ToString()
    $res = @{ Kind = 'plain'; Label = 'Other DNS server'; Typo = '' }
    if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if (Test-PrivateV4 $canon) { $res.Kind = 'router'; $res.Label = 'Router'; return $res }
    } else {
        if ($addr.IsIPv6LinkLocal) { $res.Kind = 'router'; $res.Label = 'Router'; return $res }
        $bytes = $addr.GetAddressBytes()
        if (($bytes[0] -band 0xFE) -eq 0xFC) { $res.Kind = 'router'; $res.Label = 'Router'; return $res }
        foreach ($pre in @($v6Prefixes)) {
            $same = $true
            for ($i = 0; $i -lt 8; $i++) { if ($bytes[$i] -ne $pre[$i]) { $same = $false; break } }
            if ($same) { $res.Kind = 'router'; $res.Label = 'Router'; return $res }
        }
    }
    if ($tables.Filter.ContainsKey($canon)) { $res.Kind = 'filter'; $res.Label = [string]$tables.Filter[$canon]; return $res }
    if ($tables.Plain.ContainsKey($canon))  { $res.Kind = 'plain';  $res.Label = [string]$tables.Plain[$canon]; return $res }
    # unknown public IPv4: look for a one-number typo of a well-known server (8.8.8.4 instead of 8.8.4.4)
    if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $mine = $canon.Split('.')
        $cands = New-Object System.Collections.ArrayList
        foreach ($known in (@($tables.Filter.Keys) + @($tables.Plain.Keys))) {
            if ($known.Contains(':')) { continue }
            $k = $known.Split('.')
            $diff = 0
            for ($i = 0; $i -lt 4; $i++) { if ($mine[$i] -ne $k[$i]) { $diff++ } }
            if ($diff -eq 1) { [void]$cands.Add($known) }
        }
        if ($cands.Count -gt 0) { $res.Typo = ((@($cands) | Select-Object -First 2) -join ' or ') }
    }
    return $res
}

# All DNS servers of all connected adapters (placeholders fec0:0:0:ffff::1/2/3 are ignored)
function Get-DnsRecords([string]$wifiAlias) {
    $tables = New-DnsTables
    $recs = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($n.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        if ($n.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }
        $props = $n.GetIPProperties()
        $hasGw = $false
        foreach ($ga in $props.GatewayAddresses) {
            $t = $ga.Address.ToString()
            if ($t -ne '0.0.0.0' -and $t -ne '::') { $hasGw = $true }
        }
        $prefixes = New-Object System.Collections.ArrayList
        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $ua.Address.IsIPv6LinkLocal) {
                $b = $ua.Address.GetAddressBytes()
                [void]$prefixes.Add([byte[]]($b[0..7]))
            }
        }
        foreach ($da in $props.DnsAddresses) {
            $ip = $da.ToString()
            $pct = $ip.IndexOf('%'); if ($pct -ge 0) { $ip = $ip.Substring(0, $pct) }
            if ($ip -like 'fec0:0:0:ffff::*') { continue }
            $key = $n.Name + '|' + $ip
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $c = Get-DnsClass $ip $tables $prefixes
            [void]$recs.Add(@{
                Ip = $ip; Adapter = $n.Name; IsWifi = ($n.Name -eq $wifiAlias); HasGw = $hasGw
                Kind = $c.Kind; Label = $c.Label; Typo = $c.Typo
                LinkLocal = ($da.IsIPv6LinkLocal); Answers = $null; Ms = $null
            })
        }
    }
    return ,$recs
}

# Does this DNS server answer? (Resolve-DnsName example.com -Server x)
function Test-DnsServer([string]$ip) {
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return @{ Answers = $null; Ms = $null } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Resolve-DnsName -Name 'example.com' -Server $ip -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        return @{ Answers = $true; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return @{ Answers = $false; Ms = $null }
    }
}

# ON only if every server on the internet-facing adapter(s) is a filtering resolver and at least one answers
function Get-ShieldVerdict($recs) {
    $all = @($recs)
    $use = @($all | Where-Object { $_.HasGw })
    if ($use.Count -eq 0) { $use = $all }
    if ($use.Count -eq 0) { return @{ Shield = 'off'; Summary = 'No DNS servers found on your connected adapters.' } }
    $filters = @($use | Where-Object { $_.Kind -eq 'filter' })
    $routers = @($use | Where-Object { $_.Kind -eq 'router' })
    $plains  = @($use | Where-Object { $_.Kind -eq 'plain' })
    $typos   = @($use | Where-Object { $_.Typo })
    $filterOk = @($filters | Where-Object { $_.Answers -ne $false })
    if ($typos.Count -gt 0) {
        $t = $typos[0]
        return @{ Shield = 'off'; Summary = ('Check DNS server ' + $t.Ip + ': it looks like a typo of ' + $t.Typo + '.') }
    }
    if ($filters.Count -gt 0 -and $routers.Count -eq 0 -and $plains.Count -eq 0) {
        if ($filterOk.Count -gt 0) {
            $names = @($filters | ForEach-Object { $_.Label } | Select-Object -Unique)
            return @{ Shield = 'on'; Summary = ('Scam filter active: ' + ($names -join ', ') + '.') }
        }
        return @{ Shield = 'off'; Summary = 'Your filtering DNS servers are not answering.' }
    }
    if ($filters.Count -gt 0) { return @{ Shield = 'off'; Summary = 'Mixed DNS: a non-filtering server can bypass the scam filter.' } }
    if ($routers.Count -gt 0 -and $plains.Count -eq 0) { return @{ Shield = 'off'; Summary = 'Using your router''s DNS: no scam filter known.' } }
    $pn = @($plains | ForEach-Object { $_.Label } | Select-Object -Unique)
    return @{ Shield = 'off'; Summary = ('Plain DNS, no scam filter: ' + ($pn -join ', ') + '.') }
}

try {
    $recs = Get-DnsRecords ([string]$WifiAlias)
    foreach ($r in $recs) {
        if ($r.LinkLocal) { continue }                       # link-local router addresses cannot be tested reliably
        $t = Test-DnsServer ([string]$r.Ip)
        $r.Answers = $t.Answers
        $r.Ms = $t.Ms
    }
    $v = Get-ShieldVerdict $recs
    $out = @()
    $done = @{}
    foreach ($r in $recs) {
        if ($done.ContainsKey($r.Ip)) { continue }
        $done[$r.Ip] = $true
        $out += @{ Ip = $r.Ip; Kind = $r.Kind; Label = $r.Label; Typo = $r.Typo; Answers = $r.Answers; Ms = $r.Ms; HasGw = $r.HasGw }
    }
    $Q.Enqueue(@{ T = 'dns'; Shield = $v.Shield; Summary = $v.Summary; Servers = $out; Error = '' })
} catch {
    $Q.Enqueue(@{ T = 'dns'; Shield = 'unknown'; Summary = 'DNS check failed.'; Servers = @(); Error = $_.Exception.Message })
}
'@

function Start-DnsCheck {
    if ($script:DnsRunning) { return }
    $W = $script:Wifi
    if (-not $W.Connected) { $script:NextDnsUtc = [datetime]::UtcNow.AddSeconds(30); return }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:DnsSource).AddArgument($script:DnsQueue).AddArgument([string]$W.Adapter)
        $script:DnsRs = $rs
        $script:DnsPs = $ps
        $script:DnsStartUtc = [datetime]::UtcNow
        $script:DnsRunning = $true
        [void]$ps.BeginInvoke()
    } catch {
        $script:DnsRunning = $false
        Write-Log ('DNS check could not start: ' + $_.Exception.Message) 'ERROR'
    }
}

function Show-DnsPopup($a) {
    $lines = @(Split-TextLines ([string]$a.Summary) 48)
    if ($lines.Count -gt 2) { $lines = $lines[0..1] }
    $lines += 'Scam and malware sites may not be blocked now.'
    $item = [pscustomobject]@{
        Type = 'dns'; Mac = ''; Title = 'DNS Shield turned OFF!'; Value = $null; ValueText = ''; Accent = $script:Pal.Red; Lines = $lines
        Buttons = @(@{ Id = 'dnsfix'; Text = 'Fix it'; Primary = $true }, @{ Id = 'ok'; Text = 'OK' })
    }
    Show-AlertPopup $item
    Write-Log 'DNS popup shown (shield turned off).'
    return $true
}

function Handle-DnsResult($r) {
    $script:DnsRunning = $false
    try { if ($script:DnsPs) { $script:DnsPs.Dispose() } } catch { }
    try { if ($script:DnsRs) { $script:DnsRs.Close(); $script:DnsRs.Dispose() } } catch { }
    if ($r.Error) { Write-Log ('DNS check error: ' + $r.Error) 'WARN' }
    $prev = [string]$script:Dns.Shield
    $now = [string]$r.Shield
    $script:Dns = @{ Shield = $now; Summary = [string]$r.Summary; Servers = @($r.Servers); At = [datetime]::UtcNow }
    Write-Log ('DNS Shield: ' + $now + ' - ' + $r.Summary)
    if ($now -eq 'on') {
        if (-not $script:Settings['DnsWasOn']) { $script:Settings['DnsWasOn'] = $true; Save-Settings }
    } elseif ($now -eq 'off') {
        $wasOn = ($prev -eq 'on') -or ($prev -eq 'unknown' -and [bool]$script:Settings['DnsWasOn'])
        if ($script:Settings['DnsWasOn']) { $script:Settings['DnsWasOn'] = $false; Save-Settings }
        if ($wasOn) { Request-Alert @{ Type = 'dns'; Kind = 'off'; Summary = [string]$r.Summary } }
    }
    $script:Form.Invalidate()
}

# ---------- "Fix it": set Cloudflare's scam filter (needs the Windows admin prompt) ----------
function Show-DnsFixDialog {
    $alias = [string]$script:Wifi.Adapter
    if (-not $alias) { Show-Balloon 'DNS Shield' 'No network connection.'; return }
    $script:DnsChoice = ''
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'DNS Shield'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.TopMost = $true
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 470), (S 290))

    $text = @(
        ('Right now: ' + $script:Dns.Summary),
        '',
        ('"Turn on scam filter" sets Cloudflare''s malware-blocking DNS (1.1.1.2 and 1.0.0.2) on this PC''s network adapter "' + $alias + '".'),
        'Windows will ask for administrator permission. Nothing changes unless you approve it.',
        '',
        '"Back to automatic" returns to the DNS your router gives out (the normal setting).'
    ) -join "`r`n"
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point((S 16), (S 14))
    $lbl.Size = New-Object System.Drawing.Size((S 438), (S 200))
    $lbl.Text = $text
    $dlg.Controls.Add($lbl)

    $b1 = New-Object System.Windows.Forms.Button
    $b1.Text = 'Turn on scam filter'
    $b1.Location = New-Object System.Drawing.Point((S 16), (S 246))
    $b1.Size = New-Object System.Drawing.Size((S 170), (S 30))
    $b1.add_Click({ $script:DnsChoice = 'filter'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($b1)

    $b2 = New-Object System.Windows.Forms.Button
    $b2.Text = 'Back to automatic'
    $b2.Location = New-Object System.Drawing.Point((S 194), (S 246))
    $b2.Size = New-Object System.Drawing.Size((S 150), (S 30))
    $b2.add_Click({ $script:DnsChoice = 'auto'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($b2)

    $b3 = New-Object System.Windows.Forms.Button
    $b3.Text = 'Cancel'
    $b3.Location = New-Object System.Drawing.Point((S 352), (S 246))
    $b3.Size = New-Object System.Drawing.Size((S 100), (S 30))
    $b3.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($b3)
    $dlg.CancelButton = $b3

    try { [void]$dlg.ShowDialog() } finally { $dlg.Dispose() }
    if ($script:DnsChoice) { Invoke-DnsChange $script:DnsChoice $alias }
}

function Invoke-DnsChange([string]$mode, [string]$alias) {
    if ($script:FixProc -and -not $script:FixProc.HasExited) { Show-Balloon 'DNS Shield' 'A DNS change is already waiting for permission.'; return }
    $a = $alias.Replace("'", "''")
    if ($mode -eq 'filter') {
        $inner = "try { Set-DnsClientServerAddress -InterfaceAlias '$a' -ServerAddresses '1.1.1.2','1.0.0.2','2606:4700:4700::1112','2606:4700:4700::1002' -ErrorAction Stop } catch { Set-DnsClientServerAddress -InterfaceAlias '$a' -ServerAddresses '1.1.1.2','1.0.0.2' -ErrorAction Stop }"
    } else {
        $inner = "Set-DnsClientServerAddress -InterfaceAlias '$a' -ResetServerAddresses -ErrorAction Stop"
    }
    $cmd = "try { $inner; Clear-DnsClientCache; exit 0 } catch { exit 1 }"
    try {
        $script:FixProc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $cmd + '"')
        $script:FixMode = $mode
        $script:FixStartUtc = [datetime]::UtcNow
        Write-Log ('DNS change requested (' + $mode + ') for adapter ' + $alias + '; waiting for the Windows admin prompt.')
    } catch {
        Write-Log ('DNS change not started: ' + $_.Exception.Message) 'WARN'
        Show-Balloon 'DNS Shield' 'DNS was not changed (permission not given).'
    }
}

function Update-DnsScheduler {
    $item = $null
    while ($script:DnsQueue.TryDequeue([ref]$item)) {
        try { Handle-DnsResult $item } catch { Write-Log ('DNS result error: ' + $_.Exception.Message) 'ERROR' }
    }
    $now = [datetime]::UtcNow
    if ($script:DnsRunning -and (($now - $script:DnsStartUtc).TotalSeconds -gt 90)) {
        Write-Log 'DNS check took too long - giving up.' 'WARN'
        try { if ($script:DnsPs) { [void]$script:DnsPs.BeginStop($null, $null) } } catch { }
        $script:DnsRunning = $false
    }
    # result of the elevated DNS change
    if ($script:FixProc) {
        $done = $false
        try { $done = $script:FixProc.HasExited } catch { $done = $true }
        if ($done) {
            $code = 1
            try { $code = $script:FixProc.ExitCode } catch { }
            $script:FixProc = $null
            if ($code -eq 0) {
                Write-Log ('DNS changed (' + $script:FixMode + ').')
                $script:NextDnsUtc = $now.AddSeconds(3)
                $script:Dns.Summary = 'Checking your DNS servers...'
            } else {
                Write-Log ('DNS change did not complete (exit code ' + $code + ').') 'WARN'
                Show-Balloon 'DNS Shield' 'DNS was not changed.'
            }
        } elseif ((($now - $script:FixStartUtc).TotalSeconds) -gt 180) {
            $script:FixProc = $null
        }
    }
    if (-not $script:DnsRunning -and $now -ge $script:NextDnsUtc) {
        $script:NextDnsUtc = $now.AddMinutes(10)                  # re-check every 10 minutes
        Start-DnsCheck
    }
}

# ---------------------------------------------------------------- popup with buttons (CPU/GPU/RAM, disk, device, speed, DNS alerts)
$script:PopBtns = @()

function Paint-Popup($g, [int]$w, [int]$h) {
    $d = $script:PopData
    if ($null -eq $d) { return }
    $p = $script:Pal; $F = $script:Fonts
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($p.Bg)
    $acc = $d.Accent
    $bw = 1.6 * $script:Scale
    $path = New-RoundPath ($bw / 2) ($bw / 2) ($w - $bw) ($h - $bw) ((S 14) - $bw / 2)
    $g.DrawPath((Get-Pen $acc $bw $false), $path)
    $path.Dispose()
    $m = (S 16)
    Draw-Text $g $d.Title $F.Popup (Get-Brush $acc) $m (S 10) ($w - 2 * $m - (S 24)) (S 22) 'LM'
    if ([int]$d.ValueY -ge 0) { Draw-Text $g $d.Value $F.PopupBig (Get-Brush $acc) $m $d.ValueY ($w - 2 * $m) (S 42) 'LM' }
    $mut = Get-Brush $p.Muted
    for ($i = 0; $i -lt $d.Lines.Count; $i++) {
        Draw-Text $g ([string]$d.Lines[$i]) $F.Chip $mut $m ($d.LinesY + $i * (S 16)) ($w - 2 * $m) (S 16) 'LM'
    }
    # small x in the corner
    $xr = $script:PopHit['x']
    if ($script:PopHover -eq 'x') { $xc = $p.Text } else { $xc = $p.Muted }
    $xp = Get-Pen $xc (1.5 * $script:Scale) $true
    $cx = $xr.X + $xr.Width / 2.0; $cy = $xr.Y + $xr.Height / 2.0; $u = 3.5 * $script:Scale
    $g.DrawLine($xp, [single]($cx - $u), [single]($cy - $u), [single]($cx + $u), [single]($cy + $u))
    $g.DrawLine($xp, [single]($cx + $u), [single]($cy - $u), [single]($cx - $u), [single]($cy + $u))
    # buttons
    foreach ($b in $script:PopBtns) {
        $r = $b.Rect
        $hover = ($script:PopHover -eq $b.Id)
        if ($b.Primary) {
            $fc = $acc
            if ($hover) { $fc = [System.Drawing.Color]::FromArgb([Math]::Min(255, $acc.R + 30), [Math]::Min(255, $acc.G + 30), [Math]::Min(255, $acc.B + 30)) }
            $tc = [System.Drawing.Color]::FromArgb(14, 22, 30)
        } else {
            if ($hover) { $fc = $p.Hover } else { $fc = $p.Chip }
            if ($b.Danger) { $tc = [System.Drawing.Color]::FromArgb(255, 125, 120) } else { $tc = $p.Text }
        }
        Fill-Round $g (Get-Brush $fc) $r.X $r.Y $r.Width $r.Height (S 8)
        if (-not $b.Primary) {
            $bp = New-RoundPath ($r.X + 0.5) ($r.Y + 0.5) ($r.Width - 1) ($r.Height - 1) (S 8)
            $g.DrawPath((Get-Pen $p.PanelLine $script:Px1 $false), $bp)
            $bp.Dispose()
        }
        Draw-Text $g ([string]$b.Text) $F.Chip (Get-Brush $tc) $r.X $r.Y $r.Width $r.Height 'CM'
    }
}

function Show-AlertPopup($a) {
    Ensure-Popup
    $valText = ''
    if ($a.ValueText) { $valText = [string]$a.ValueText }
    elseif ($null -ne $a.Value) { $valText = (Fmt ([double]$a.Value) '0') + '%' }
    $sev = 0.0
    if ($null -ne $a.Value) { $sev = [double]$a.Value }
    if ($a.Accent) { $acc = $a.Accent } elseif ($sev -gt 95) { $acc = $script:Pal.Red } else { $acc = $script:Pal.Amber }

    $w = (S 348); $m = (S 16)
    $lines = @($a.Lines)
    $y = (S 34)
    $valueY = -1
    if ($valText) { $valueY = $y; $y += (S 46) }
    $linesY = $y
    $y += $lines.Count * (S 16) + (S 8)
    if ($a.Buttons) { $btns = @($a.Buttons) } else { $btns = @(@{ Id = 'ok'; Text = 'OK'; Primary = $true }) }
    $btnY = $y
    $h = $y + (S 30) + (S 14)

    $list = New-Object System.Collections.ArrayList
    $hit = @{}
    $n = $btns.Count
    $gap = (S 8)
    $bwid = [int](($w - 2 * $m - ($n - 1) * $gap) / $n)
    for ($i = 0; $i -lt $n; $i++) {
        $b = $btns[$i]
        $r = New-Object System.Drawing.Rectangle(($m + $i * ($bwid + $gap)), $btnY, $bwid, (S 30))
        [void]$list.Add(@{ Id = [string]$b.Id; Text = [string]$b.Text; Primary = [bool]$b.Primary; Danger = [bool]$b.Danger; Rect = $r })
        $hit[[string]$b.Id] = $r
    }
    $hit['x'] = New-Object System.Drawing.Rectangle(($w - (S 28)), (S 8), (S 18), (S 18))
    $script:PopBtns = $list
    $script:PopHit = $hit
    $script:PopData = @{ Title = [string]$a.Title; Value = $valText; ValueY = $valueY; Lines = $lines; LinesY = $linesY; Accent = $acc; Mac = [string]$a.Mac; Type = [string]$a.Type }
    $script:PopHover = $null

    $pf = $script:Popup
    $pf.Size = New-Object System.Drawing.Size($w, $h)
    $rp = New-RoundPath 0 0 $w $h (S 14)
    $oldR = $pf.Region
    $pf.Region = New-Object System.Drawing.Region($rp)
    $rp.Dispose()
    if ($null -ne $oldR) { $oldR.Dispose() }
    Place-Popup
    $pf.BackColor = $script:Pal.Bg
    $pf.Show()
    $pf.Invalidate()
    $script:PopRepaints = 0
    $script:PopRepaintTimer.Stop(); $script:PopRepaintTimer.Start()
    $script:PopHideTimer.Stop(); $script:PopHideTimer.Start()
    $script:LastPopup = Get-Date
}

# ---------------------------------------------------------------- Wi-Fi assistant: alerts that need buttons
function On-DeviceAlert($d, [string]$kind) {
    if (-not $script:Settings['DeviceAlerts'] -or -not $script:Settings['AlertsEnabled']) { return }
    $age = ((Get-Date) - $script:StartTime).TotalSeconds
    if ($age -lt 45) {
        Write-Log ('Device alert skipped (start-up scan) [' + $kind + ']: ' + $d.Mac + ' ip=' + $d.Ip)
        return
    }
    Request-Alert @{ Type = 'device'; Mac = [string]$d.Mac; Kind = $kind }
}

function Request-Alert($a) {
    if (-not [bool]$script:Settings['AlertsEnabled']) { return }
    if ($a.Type -eq 'speed' -and -not [bool]$script:Settings['AlertSpeed']) { return }
    if ($a.Type -eq 'dns' -and -not [bool]$script:Settings['AlertDns']) { return }
    if ($a.Type -eq 'device' -and -not [bool]$script:Settings['DeviceAlerts']) { return }
    if ($a.Type -eq 'outage' -and -not [bool]$script:Settings['AlertOutage']) { return }
    if ($a.Type -eq 'data' -and -not [bool]$script:Settings['AlertData']) { return }
    if ($a.Type -eq 'battery' -and -not [bool]$script:Settings['AlertBattery']) { return }
    if ($a.Type -eq 'device') {
        foreach ($q in $script:AlertQueue.ToArray()) { if ($q -is [hashtable] -and $q.Type -eq 'device' -and $q.Mac -eq $a.Mac) { return } }
        if ($script:Popup -and $script:Popup.Visible -and $script:PopData -and $script:PopData.Mac -eq $a.Mac) { return }
    }
    $script:AlertQueue.Enqueue($a)
    Pump-Popups
}

function Show-DevicePopup($a, [bool]$force = $false) {
    $d = $script:Devices[[string]$a.Mac]
    if ($null -eq $d) { return $false }
    if (-not $force -and (Get-DeviceName $d)) { return $false }   # it was named in the meantime
    if ($a.Kind -eq 'back') { $title = 'Unknown device is back!' } else { $title = 'New device on your network!' }
    $lines = @()
    if ($d.Ip) { $lines += ('IP address:   ' + $d.Ip) } else { $lines += 'IP address:   not known yet' }
    if ($d.Hostname) { $lines += ('Calls itself:   ' + $d.Hostname) } else { $lines += 'Calls itself:   (no name announced)' }
    if ($d.Private) { $lines += 'Private MAC (random address)' }
    $gs2 = Get-DeviceGuess $d
    if ($gs2) { $lines += ('Looks like: ' + $gs2 + ' (a guess)') }
    $item = [pscustomobject]@{
        Type = 'device'; Mac = [string]$d.Mac; Title = $title; Value = $null; ValueText = ''; Accent = $script:Pal.Amber; Lines = $lines
        Buttons = @(@{ Id = 'mine'; Text = 'It''s mine'; Primary = $true }, @{ Id = 'block'; Text = 'Block...'; Danger = $true })
    }
    Show-AlertPopup $item
    Write-Log ('Popup shown [' + $a.Kind + ']: ' + $d.Mac + ' ip=' + $d.Ip)
    return $true
}

# Wi-Fi alerts wait in the queue as small descriptions; the popup is built when it is their turn.
function Show-WifiAlert($a) {
    try {
        if ($a.Type -eq 'device') { return [bool](@(Show-DevicePopup $a)[-1]) }
        if ($a.Type -eq 'speed')  { return [bool](@(Show-SpeedPopup $a)[-1]) }
        if ($a.Type -eq 'dns')    { return [bool](@(Show-DnsPopup $a)[-1]) }
        if ($a.Type -eq 'outage') { return [bool](@(Show-OutagePopup $a)[-1]) }
        if ($a.Type -eq 'data')   { return [bool](@(Show-DataPopup $a)[-1]) }
    } catch { Write-Log ('Show-WifiAlert error: ' + $_.Exception.Message) 'ERROR' }
    return $false
}

function Pump-Popups {
    if ($script:AlertQueue.Count -eq 0 -or $script:AutoHidden) { return }
    if ((New-TimeSpan -Start $script:LastPopup -End (Get-Date)).TotalSeconds -lt 10) { return }
    while ($script:AlertQueue.Count -gt 0) {
        $a = $script:AlertQueue.Dequeue()
        if ($a -is [hashtable]) { if (Show-WifiAlert $a) { break } }
        else { Show-AlertPopup $a; break }
    }
}

function Invoke-PopupAction([string]$id) {
    $d = $script:PopData
    $mac = ''
    if ($d) { $mac = [string]$d.Mac }
    switch ($id) {
        'mine'   { Hide-Popup; if ($mac) { Show-NameDialog $mac } }
        'block'  { Hide-Popup; if ($mac) { Show-BlockHelp $mac } }
        'again'  { Hide-Popup; Start-SpeedTest $true }
        'dash'   { Hide-Popup; Open-WebPage 'net' $script:NetworkHtml }
        'dnsfix' { Hide-Popup; Show-DnsFixDialog }
        default  { Hide-Popup }
    }
}

# ---------------------------------------------------------------- Wi-Fi page of the expanded view
function Set-NetView([string]$view) {
    $script:Settings['NetView'] = $view
    Save-Settings
    if ($view -eq 'Speed') { Load-SpeedHistory }
    if ($view -eq 'Nearby' -and -not $script:Scan.Running -and ((Get-Date) - $script:Scan.At).TotalSeconds -gt 20) { Start-WifiScan }
    $script:Form.Invalidate()
}

function Set-ExpTab([string]$tab) {
    $script:Settings['ExpandedTab'] = $tab
    Save-Settings
    $script:Form.Invalidate()
}

function Draw-Tabs($g, [double]$x, [double]$y, [double]$cw) {
    $p = $script:Pal
    $th = (S 24); $gap = (S 6)
    $items = @(@('tab_sys', 'System', 'System'), @('tab_wifi', 'Network', 'Network'))
    $n = $items.Count
    $tw = [int](($cw - ($n - 1) * $gap) / $n)
    for ($i = 0; $i -lt $n; $i++) {
        $it = $items[$i]
        $rx = [int]($x + $i * ($tw + $gap))
        $r = New-Object System.Drawing.Rectangle($rx, [int]$y, $tw, $th)
        $script:Hit[$it[0]] = $r
        $sel = ([string]$script:Settings['ExpandedTab'] -eq $it[2])
        $hov = ($script:Hover -eq $it[0])
        if ($sel) { $fill = $p.Teal; $tc = [System.Drawing.Color]::FromArgb(14, 22, 30) }
        elseif ($hov) { $fill = $p.Hover; $tc = $p.Text }
        else { $fill = $p.Chip; $tc = $p.Muted }
        Fill-Pill $g (Get-Brush $fill) $r.X $r.Y $r.Width $r.Height
        Draw-Text $g $it[1] $script:Fonts.Chip (Get-Brush $tc) $r.X $r.Y $r.Width $r.Height 'CM'
    }
}

function Get-PingView($v, [int]$good, [int]$warn) {
    $p = $script:Pal
    if ($null -eq $v) { return @{ Text = '--'; Color = $p.Muted } }
    if ($v -lt 0) { return @{ Text = 'lost'; Color = $p.Red } }
    if ($v -lt 1) { $t = '<1 ms' } else { $t = ([string]$v + ' ms') }
    if ($v -le $good) { $c = $p.Teal } elseif ($v -le $warn) { $c = $p.Amber } else { $c = $p.Red }
    return @{ Text = $t; Color = $c }
}

function Draw-DeviceList($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text
    Draw-Panel $g $x $y $w $h ''
    Draw-NetViewPills $g $x $y
    $script:DevPanelRect = New-Object System.Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h)
    $script:DevRows = @()
    $devs = @(Get-SortedDevices)
    $online = 0
    foreach ($d in $devs) { if (Test-DeviceOnline $d) { $online++ } }
    Draw-Text $g ('{0} online' -f $online) $F.Muted $mut ($x + $w - (S 100)) ($y + (S 5)) (S 90) (S 14) 'RM'

    $rowH = (S 34)
    $top = $y + (S 26)
    $avail = $h - (S 26) - (S 6)
    $vis = [Math]::Max(1, [int][Math]::Floor($avail / $rowH))
    $maxScroll = [Math]::Max(0, $devs.Count - $vis)
    if ($script:DevScroll -gt $maxScroll) { $script:DevScroll = $maxScroll }
    if ($script:DevScroll -lt 0) { $script:DevScroll = 0 }

    if ($devs.Count -eq 0) {
        Draw-Text $g 'Scanning your network...' $F.Chip $mut $x $top $w ($h - (S 34)) 'CM'
        return
    }

    $rows = New-Object System.Collections.ArrayList
    $sep = Get-Pen $p.PanelLine $script:Px1 $false
    for ($i = 0; $i -lt $vis; $i++) {
        $idx = $script:DevScroll + $i
        if ($idx -ge $devs.Count) { break }
        $d = $devs[$idx]
        $ry = $top + $i * $rowH
        $isOn = Test-DeviceOnline $d
        $name = Get-DeviceName $d
        $unnamed = (-not $name)
        if ($unnamed) { $gs = Get-DeviceGuess $d; if ($gs) { $name = $gs + ' - unnamed' } else { $name = 'Unnamed device' } }

        if ($i -gt 0) { $g.DrawLine($sep, [single]($x + (S 10)), [single]$ry, [single]($x + $w - (S 10)), [single]$ry) }

        if ($isOn) { $dotBr = Get-Brush $p.Teal } else { $dotBr = Get-Brush $p.Off }
        $dr = (S 4)
        $g.FillEllipse($dotBr, [single]($x + (S 12)), [single]($ry + $rowH / 2.0 - $dr), [single](2 * $dr), [single](2 * $dr))

        if ($unnamed) { $nameBr = Get-Brush $p.Amber } elseif ($isOn) { $nameBr = $txt } else { $nameBr = $mut }
        $textX = $x + (S 28)
        $statW = (S 84)
        $textW = $w - (S 28) - $statW - (S 14)
        Draw-Text $g $name $F.PanelTitle $nameBr $textX ($ry + (S 2)) $textW (S 16) 'LM'

        $parts = @()
        if ($d.Ip) { $parts += [string]$d.Ip }
        if ($d.Hostname) { $parts += ('calls itself: ' + $d.Hostname) }
        elseif ($d.Vendor) { $parts += ('vendor: ' + $d.Vendor) }
        if ($d.Private) { $parts += 'private MAC' }
        Draw-Text $g ($parts -join '  |  ') $F.Muted $mut $textX ($ry + (S 18)) $textW (S 14) 'LM'

        $sx = $x + $w - $statW - (S 12)
        if ($isOn) { Draw-Text $g 'online' $F.Muted (Get-Brush $p.Teal) $sx ($ry + (S 9)) $statW (S 14) 'RM' }
        else { Draw-Text $g (Format-Ago (([datetime]::UtcNow - $d.LastSeen).TotalSeconds)) $F.Muted $mut $sx ($ry + (S 9)) $statW (S 14) 'RM' }

        [void]$rows.Add(@{ Mac = [string]$d.Mac; Rect = (New-Object System.Drawing.Rectangle([int]($x + (S 4)), [int]$ry, [int]($w - (S 8)), [int]$rowH)) })
    }
    $script:DevRows = $rows

    if ($devs.Count -gt $vis) {
        $trackH = $vis * $rowH
        $thumbH = [Math]::Max((S 16), [int]($trackH * $vis / [double]$devs.Count))
        $thumbY = $top + [int](($trackH - $thumbH) * $script:DevScroll / [double]$maxScroll)
        $g.FillRectangle((Get-Brush ([System.Drawing.Color]::FromArgb(110, 138, 155, 176))), [single]($x + $w - (S 6)), [single]$thumbY, [single](S 3), [single]$thumbH)
    }
}

function Format-LinkSpeed([double]$mbps) {
    if ($mbps -le 0) { return '' }
    if ($mbps -ge 1000) { return ((Fmt ($mbps / 1000.0) '0.#') + ' Gbps') }
    return ((Fmt $mbps '0') + ' Mbps')
}

function Paint-WifiPage($g, [double]$x, [double]$y, [double]$cw, [int]$h) {
    $p = $script:Pal; $F = $script:Fonts; $W = $script:Wifi
    $m = $script:Pad; $gap = (S 6); $footH = (S 26)
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text

    # --- how much room is there? Fit the page, or keep normal sizes and scroll
    $y0 = $y; $fy = $h - $m - $footH; $viewBottom = $fy - $gap
    $keysBefore = @($script:Hit.Keys)
    $ph = (S 74); $gh = (S 104); $uh = (S 58); $th = (S 58); $minList = (S 200)
    $need = $ph + $gh + $uh + $th + $minList + 4 * $gap
    $extra = ($viewBottom - $y0) - $need
    $scrollMode = ($extra -lt 0)
    if ($extra -gt 0) { $gh += [int][Math]::Min($extra * 0.4, [double](S 160)) }     # taller window: the graph grows a little, the list gets the rest
    $totalW = $x + $cw + $m
    if ($scrollMode) {
        $viewH = $viewBottom - $y0
        $script:NetMax = [Math]::Max(0.0, $need - $viewH)
        if ($script:NetScroll -gt $script:NetMax) { $script:NetScroll = $script:NetMax }
        if ($script:NetScroll -lt 0) { $script:NetScroll = 0.0 }
        $y = $y0 - $script:NetScroll
        $gstate = $g.Save()
        $g.SetClip((New-Object System.Drawing.RectangleF([single]0, [single]$y0, [single]$totalW, [single]$viewH)))
    } else { $script:NetScroll = 0.0; $script:NetMax = 0.0 }
    $viewRect = New-Object System.Drawing.Rectangle(0, [int]$y0, [int]$totalW, [int]($viewBottom - $y0))
    $script:NetRect = $viewRect

    # --- connection panel (wired or Wi-Fi)
    Draw-Panel $g $x $y $cw $ph ''
    $sig = [int]$W.Signal
    $ssid = [string]$W.Ssid
    $nowText = ('Now ' + (Format-Mbps ([double]$W.Down)) + ' / ' + (Format-Mbps ([double]$W.Up)) + ' Mbps')
    if (-not [bool]$script:Settings['WifiEnabled']) {
        Draw-Text $g 'Network monitoring is off' $F.Title $txt ($x + (S 12)) ($y + (S 10)) ($cw - (S 24)) (S 22) 'LM'
        Draw-Text $g 'Turn it on in Settings > Network assistant.' $F.Chip $mut ($x + (S 12)) ($y + (S 34)) ($cw - (S 24)) (S 18) 'LM'
    } elseif ($W.Connected -and $W.IsWifi -and $sig -ge 0 -and $ssid.Length -gt 0) {
        $line2 = ''
        if ($W.Band) { $line2 = [string]$W.Band }
        if ($W.Channel -gt 0) { if ($line2) { $line2 += '   |   ' }; $line2 += ('Channel ' + $W.Channel) }
        if ($W.Radio) { if ($line2) { $line2 += '   |   ' }; $line2 += [string]$W.Radio }
        Draw-Text $g $ssid $F.Title $txt ($x + (S 12)) ($y + (S 6)) ($cw - (S 140)) (S 22) 'LM'
        Draw-Text $g $line2 $F.Chip $mut ($x + (S 12)) ($y + (S 28)) ($cw - (S 140)) (S 18) 'LM'
        $l3 = ('Link ' + (Fmt ([double]$W.RxRate) '0') + ' / ' + (Fmt ([double]$W.TxRate) '0') + ' Mbps    ' + $nowText)
        Draw-Text $g $l3 $F.Muted $mut ($x + (S 12)) ($y + (S 49)) ($cw - (S 140)) (S 16) 'LM'
        $sc = Get-SignalColor $sig
        Draw-Text $g ([string]$sig + '%') $F.Tile (Get-Brush $sc) ($x + $cw - (S 120)) ($y + (S 6)) (S 108) (S 28) 'RM'
        $bx = $x + $cw - (S 120); $bwid = (S 108); $by = $y + (S 40); $bh = (S 6)
        $g.FillRectangle((Get-Brush $p.Track), [single]$bx, [single]$by, [single]$bwid, [single]$bh)
        $g.FillRectangle((Get-Brush $sc), [single]$bx, [single]$by, [single]($bwid * $sig / 100.0), [single]$bh)
        Draw-Text $g 'SIGNAL' $F.Muted $mut $bx ($by + (S 8)) $bwid (S 14) 'RM'
    } elseif ($W.Connected -and $W.IsWifi -and $W.Note -eq 'location') {
        Draw-Text $g 'Wi-Fi name is blocked' $F.Title $txt ($x + (S 12)) ($y + (S 10)) ($cw - (S 24)) (S 22) 'LM'
        Draw-Text $g 'Turn on Windows Location (Settings > Privacy) to see it.' $F.Chip $mut ($x + (S 12)) ($y + (S 34)) ($cw - (S 24)) (S 18) 'LM'
    } elseif ($W.Connected) {
        # wired connection (or Wi-Fi without details): show the adapter
        if ($W.IsWifi) { $kind = 'Wi-Fi' } else { $kind = 'Wired connection' }
        $ls = Format-LinkSpeed ([double]$W.LinkSpeed)
        $line2 = $kind
        if ($ls) { $line2 += ('   |   ' + $ls) }
        if ($W.LocalIp) { $line2 += ('   |   IP ' + $W.LocalIp) }
        $l3 = ''
        if ($W.Gateway) { $l3 = ('Gateway ' + $W.Gateway + '    ') }
        Draw-Text $g ([string]$W.Adapter) $F.Title $txt ($x + (S 12)) ($y + (S 6)) ($cw - (S 140)) (S 22) 'LM'
        Draw-Text $g $line2 $F.Chip $mut ($x + (S 12)) ($y + (S 28)) ($cw - (S 24)) (S 18) 'LM'
        Draw-Text $g ($l3 + $nowText) $F.Muted $mut ($x + (S 12)) ($y + (S 49)) ($cw - (S 140)) (S 16) 'LM'
        if ($ls) {
            Draw-Text $g $ls $F.Tile (Get-Brush $p.Teal) ($x + $cw - (S 130)) ($y + (S 6)) (S 118) (S 28) 'RM'
            Draw-Text $g 'LINK SPEED' $F.Muted $mut ($x + $cw - (S 130)) ($y + (S 36)) (S 118) (S 14) 'RM'
        }
    } else {
        Draw-Text $g 'No network connection' $F.Title $txt ($x + (S 12)) ($y + (S 10)) ($cw - (S 24)) (S 22) 'LM'
        Draw-Text $g 'No active adapter with an IPv4 address was found.' $F.Chip $mut ($x + (S 12)) ($y + (S 34)) ($cw - (S 24)) (S 18) 'LM'
    }
    $y += $ph + $gap

    # --- traffic of the active adapter, last 2 minutes
    $dl = $W.DlHist; $up = $W.UpHist
    if ($null -eq $dl) { $dl = [double[]]@() }
    if ($null -eq $up) { $up = [double[]]@() }
    $peak = [Math]::Max((Get-Peak $dl), (Get-Peak $up))
    $mx = Get-NiceMax $peak 5.0
    Draw-GraphPanel $g $x $y $cw $gh 'Network traffic  2 min' @(@{ Data = $dl; Color = $p.Teal }, @{ Data = $up; Color = $p.Blue }) $mx ('max ' + (Fmt $mx '0.#') + ' Mbps') @(@{ Text = 'Down'; Color = $p.Teal }, @{ Text = 'Up'; Color = $p.Blue })
    $y += $gh + $gap

    # --- data used in this period
    Draw-UsageOutagePanel $g $x $y $cw $uh
    $y += $uh + $gap

    # --- tiles: router ping | internet ping | last speed test
    $tw = [int](($cw - 2 * $gap) / 3)
    $rv = Get-PingView $W.RouterPing 20 80
    Draw-Tile $g $x $y $tw $th 'Router ping' $rv.Text 'to your router' $rv.Color
    $iv = Get-PingView $W.InetPing 40 100
    if ([string]$W.InetVia -eq 'tcp') { $iSub = 'web check (ping blocked)' } else { $iSub = 'to Cloudflare' }
    Draw-Tile $g ($x + $tw + $gap) $y $tw $th 'Internet ping' $iv.Text $iSub $iv.Color
    if ($null -ne $W.LastSpeed) { Draw-Tile $g ($x + 2 * ($tw + $gap)) $y $tw $th 'Last speed test' ((Format-Mbps ([double]$W.LastSpeed)) + ' Mbps') ([string]$W.LastSpeedText) $p.Teal }
    else { Draw-Tile $g ($x + 2 * ($tw + $gap)) $y $tw $th 'Last speed test' '--' ([string]$W.LastSpeedText) $p.Muted }
    $y += $th + $gap

    # --- devices / Wi-Fi / DNS / speed
    if ($scrollMode) { $listH = $minList } else { $listH = [Math]::Max($minList, ($viewBottom - $y)) }
    switch ([string]$script:Settings['NetView']) {
        'Nearby' { Draw-NearbyList $g $x $y $cw $listH }
        'Dns'    { Draw-DnsView $g $x $y $cw $listH }
        'Speed'  { Draw-SpeedView $g $x $y $cw $listH }
        default  { Draw-DeviceList $g $x $y $cw $listH }
    }
    if ($scrollMode) {
        $g.Restore($gstate)
        # whatever is scrolled out of view must not react to the mouse
        foreach ($k in @($script:Hit.Keys)) {
            if ($keysBefore -contains $k) { continue }
            $ir = [System.Drawing.Rectangle]::Intersect($script:Hit[$k], $viewRect)
            if ($ir.IsEmpty) { $script:Hit.Remove($k) } else { $script:Hit[$k] = $ir }
        }
        $script:DevPanelRect = [System.Drawing.Rectangle]::Intersect($script:DevPanelRect, $viewRect)
        $script:ScanPanelRect = [System.Drawing.Rectangle]::Intersect($script:ScanPanelRect, $viewRect)
        if ($script:NetMax -gt 0) {
            $trackH = $viewBottom - $y0
            $thumbH = [Math]::Max([double](S 24), $trackH * $trackH / $need)
            $thumbY = $y0 + ($trackH - $thumbH) * $script:NetScroll / $script:NetMax
            $g.FillRectangle((Get-Brush ([System.Drawing.Color]::FromArgb(120, 138, 155, 176))), [single]($totalW - (S 11)), [single]$thumbY, [single](S 3), [single]$thumbH)
        }
    }

    # --- footer buttons
    $bw3 = [int](($cw - 2 * $gap) / 3)
    $script:Hit['w_speed'] = New-Object System.Drawing.Rectangle([int]$x, $fy, $bw3, $footH)
    $script:Hit['w_full'] = New-Object System.Drawing.Rectangle([int]($x + $bw3 + $gap), $fy, $bw3, $footH)
    $script:Hit['w_dash'] = New-Object System.Drawing.Rectangle([int]($x + 2 * ($bw3 + $gap)), $fy, [int]($cw - 2 * ($bw3 + $gap)), $footH)
    if ($script:SpeedRunning) { $sl = 'Testing...' } else { $sl = 'Speed test' }
    if ($script:FullRunning) { $fl = ('Full test ' + [int]$W.FullPct + '%') } else { $fl = 'Full test' }
    Draw-Button $g $script:Hit['w_speed'] $sl ($script:Hover -eq 'w_speed')
    Draw-Button $g $script:Hit['w_full'] $fl ($script:Hover -eq 'w_full')
    Draw-Button $g $script:Hit['w_dash'] 'Dashboard' ($script:Hover -eq 'w_dash')
}

# ---------------------------------------------------------------- network history files + Full test
# network-YYYY-MM.csv   one row every few seconds (written by the network sampler)
# speedtests.csv        every speed test result
# device-events.csv     every new / returning device
# fulltests\*.json      the detailed report of every full test, fulltests.csv = one summary line per test
$script:NetworkHtml = Join-Path $script:DataDir 'network.html'
$script:FullDir     = Join-Path $script:DataDir 'fulltests'
$script:SpeedCsvPath = Join-Path $script:DataDir 'speedtests.csv'
$script:EventCsvPath = Join-Path $script:DataDir 'device-events.csv'
$script:FullCsvPath  = Join-Path $script:DataDir 'fulltests.csv'
$script:SpeedCsv = New-Object CsvAppender('Timestamp,Result,Mbps,Source,AdapterType,Adapter,Ssid,Bytes,Seconds')
$script:EventCsv = New-Object CsvAppender('Timestamp,Event,Mac,Ip,Name,Hostname,Vendor')
$script:FullCsv  = New-Object CsvAppender('Timestamp,Grade,Score,DownloadMbps,UploadMbps,RouterPingMs,InternetPingMs,JitterMs,LossPercent,DnsMs,AdapterType,Adapter,Ssid,SignalPercent,Report')

function Log-SpeedRow([string]$result, $mbps, [string]$source, $bytes, $secs) {
    $W = $script:Wifi
    $m = ''; if ($null -ne $mbps) { $m = (Fmt ([double]$mbps) '0.00') }
    $line = (@((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $result, $m, $source, (Csv-Field ([string]$W.LinkType)), (Csv-Field ([string]$W.Adapter)), (Csv-Field ([string]$W.Ssid)), [string]$bytes, [string]$secs) -join ',')
    [void]$script:SpeedCsv.Write($script:SpeedCsvPath, $line)
}

function Log-DeviceEvent($d, [string]$kind) {
    $line = (@((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $kind, [string]$d.Mac, [string]$d.Ip, (Csv-Field ([string](Get-DeviceName $d))), (Csv-Field ([string]$d.Hostname)), (Csv-Field ([string]$d.Vendor))) -join ',')
    [void]$script:EventCsv.Write($script:EventCsvPath, $line)
}

function Flush-NetworkCsv {
    foreach ($pair in @(@($script:SpeedCsv, $script:SpeedCsvPath), @($script:EventCsv, $script:EventCsvPath), @($script:FullCsv, $script:FullCsvPath))) {
        try { if ($pair[0].PendingCount -gt 0) { [void]$pair[0].Flush($pair[1]) } } catch { }
    }
}

# ---------------------------------------------------------------- Full test (about 1-2 minutes)
$script:FullQueue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:FullRunning  = $false
$script:FullStartUtc = [datetime]::UtcNow
$script:FullPs = $null; $script:FullRs = $null

# The DNS Shield helper functions (same ones the DNS check uses) are reused inside the full test.
$script:DnsHelpers = [regex]::Match($script:DnsSource, '(?s)function New-DnsTables.*?(?=\r?\ntry \{\r?\n\s+\$recs = Get-DnsRecords)').Value
$script:FullBody = @'
$ErrorActionPreference = 'Continue'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
$script:RouterIp = [string]$Gateway
$AdapterName = [string]$S.Adapter

function Prog([int]$pct, [string]$text) { $S.FullPct = $pct; $S.FullText = $text }
function Round-Num($v, [int]$d = 1) { if ($null -eq $v) { return $null }; return [math]::Round([double]$v, $d) }
function R1($v) { return (Round-Num $v 1) }
function Parse-Num([string]$t) {
    $v = 0.0
    [void][double]::TryParse($t, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)
    return $v
}
function Num([string]$t) { return (Parse-Num $t) }

# the router's address never appears in the report
function Hide-Router([string]$text) {
    if ($script:RouterIp -and $text) { return $text.Replace($script:RouterIp, 'router (hidden)') }
    return $text
}

# ---------- Wi-Fi details that the widget does not collect every second ----------
function Get-NetshText([string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'netsh.exe'
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(5000)
    return $out
}

function Get-WlanDetails([string]$adapterName) {
    $res = @{ Rssi = $null; RssiEstimated = $true; Auth = '' }
    try {
        $blocks = New-Object System.Collections.ArrayList
        $cur = $null
        foreach ($line in ((Get-NetshText 'wlan show interfaces') -split "`r?`n")) {
            if ($line -match '^\s+([^:]+?)\s*:\s?(.*)$') {
                $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
                if ($k -eq 'Name') { $cur = @{}; [void]$blocks.Add($cur) }
                if ($null -ne $cur) { $cur[$k] = $v }
            }
        }
        $blk = $null
        foreach ($b in $blocks) { if ($b['Name'] -eq $adapterName) { $blk = $b; break } }
        if (-not $blk -and $blocks.Count -gt 0) { $blk = $blocks[0] }
        if ($blk) {
            $res.Auth = [string]$blk['Authentication']
            $rssi = 0
            if ($blk.ContainsKey('Rssi') -and [int]::TryParse(([string]$blk['Rssi'] -replace '[^\d-]', ''), [ref]$rssi)) { $res.Rssi = $rssi; $res.RssiEstimated = $false }
        }
    } catch { }
    if ($null -eq $res.Rssi -and [int]$S.Signal -ge 0) { $res.Rssi = [int][math]::Round([int]$S.Signal / 2.0 - 100) }   # signal quality -> approximate dBm
    return $res
}

# Other Wi-Fi networks on or near our channel (needs no admin; may be empty)
function Get-CrowdCount([int]$channel, [string]$bssid) {
    try {
        $out = Get-NetshText 'wlan show networks mode=bssid'
        $list = @(); $cur = $null
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match '^\s*BSSID\s+\d+\s*:\s*(.+)$') { $cur = @{ Bssid = $Matches[1].Trim().ToLower(); Channel = 0 }; $list += $cur; continue }
            if ($cur -and $line -match '^\s*Channel\s*:\s*(\d+)') { $cur.Channel = [int]$Matches[1] }
        }
        if ($list.Count -eq 0 -or $channel -le 0) { return $null }
        $n = 0
        foreach ($e in $list) {
            if ($e.Bssid -eq ([string]$bssid).ToLower()) { continue }
            if ($channel -le 14) { if ([math]::Abs($e.Channel - $channel) -le 4) { $n++ } }
            elseif ($e.Channel -eq $channel) { $n++ }
        }
        return $n
    } catch { return $null }
}

# ---------- latency / packet loss ----------
function Ping-Stats([string]$target, [int]$count, [int]$timeout) {
    if (-not $target) { return $null }
    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object 'System.Collections.Generic.List[double]'
    $lost = 0
    for ($i = 0; $i -lt $count; $i++) {
        if ($S.FullCancel) { break }
        try {
            $r = $ping.Send($target, $timeout)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $times.Add([double]$r.RoundtripTime) } else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 150
    }
    $sent = $times.Count + $lost
    $res = @{ Target = $target; Sent = $sent; Received = $times.Count; Lost = $lost; Loss = 0.0; LossPct = 0.0; Min = $null; Avg = $null; Max = $null; Jitter = $null }
    if ($sent -gt 0) { $res.Loss = (R1 ($lost * 100.0 / $sent)); $res.LossPct = $res.Loss }
    if ($times.Count -gt 0) {
        $mn = $times[0]; $mx = $times[0]; $sum = 0.0
        foreach ($t in $times) { if ($t -lt $mn) { $mn = $t }; if ($t -gt $mx) { $mx = $t }; $sum += $t }
        $res.Min = R1 $mn; $res.Max = R1 $mx; $res.Avg = R1 ($sum / $times.Count)
        if ($times.Count -gt 1) {
            $dsum = 0.0
            for ($i = 1; $i -lt $times.Count; $i++) { $dsum += [math]::Abs($times[$i] - $times[$i - 1]) }
            $res.Jitter = R1 ($dsum / ($times.Count - 1))
        } else { $res.Jitter = 0.0 }
    }
    return $res
}

# ---------- speed (curl.exe, bound to the active adapter) ----------
function Invoke-Curl([string]$argText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $curl
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $S.CurlPid = $p.Id
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $S.CurlPid = 0
    return @{ Exit = $p.ExitCode; Out = $out.Trim(); Err = $err.Trim() }
}

function Measure-Download([string]$ip) {
    $refused = 0
    $bind = $ip
    foreach ($bytes in 25000000, 10000000, 5000000, 2000000) {
        $a = '-s -S -o NUL -w "%{http_code};%{size_download};%{time_total};%{time_starttransfer}" --connect-timeout 8 --max-time 30 '
        if ($bind) { $a += ('--interface ' + $bind + ' ') }
        $a += ('"https://speed.cloudflare.com/__down?bytes=' + $bytes + '"')
        $res = Invoke-Curl $a
        if ($res.Exit -eq 45 -and $bind) { $bind = ''; $a = $a.Replace(('--interface ' + $ip + ' '), ''); $res = Invoke-Curl $a }
        $parts = $res.Out -split ';'
        $code = 0; $size = 0.0; $tt = 0.0; $tst = 0.0
        if ($parts.Length -ge 4) { $code = [int](Parse-Num $parts[0]); $size = Parse-Num $parts[1]; $tt = Parse-Num $parts[2]; $tst = Parse-Num $parts[3] }
        if ($code -eq 403) { $refused++; continue }
        if ($size -gt 0 -and ($code -eq 200 -or $res.Exit -eq 28)) {
            $dur = $tt - $tst
            if ($dur -lt 0.15) { $dur = $tt }
            if ($dur -gt 0) { return @{ Status = 'ok'; Mbps = (Round-Num (($size * 8.0) / $dur / 1000000.0) 2); Retried = ($refused -gt 0); Msg = '' } }
        }
        $m = $res.Err; if (-not $m) { $m = 'curl exit ' + $res.Exit + ', HTTP ' + $code }
        return @{ Status = 'error'; Mbps = $null; Retried = $false; Msg = $m }
    }
    return @{ Status = 'refused'; Mbps = $null; Retried = $true; Msg = 'The server refused every file size (HTTP 403).' }
}

function Measure-Upload([string]$ip) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('upl-' + [guid]::NewGuid().ToString('N') + '.bin')
    $refused = 0
    $bind = $ip
    try {
        foreach ($bytes in 5000000, 2000000, 1000000) {
            $buf = New-Object byte[] $bytes
            (New-Object System.Random).NextBytes($buf)
            [System.IO.File]::WriteAllBytes($tmp, $buf)
            $a = '-s -S -o NUL -w "%{http_code};%{size_upload};%{time_total};%{time_pretransfer};%{time_starttransfer}" --connect-timeout 8 --max-time 40 '
            if ($bind) { $a += ('--interface ' + $bind + ' ') }
            $a += ('-X POST -H "Content-Type: application/octet-stream" --data-binary "@' + $tmp + '" "https://speed.cloudflare.com/__up"')
            $res = Invoke-Curl $a
            if ($res.Exit -eq 45 -and $bind) { $bind = ''; $a = $a.Replace(('--interface ' + $ip + ' '), ''); $res = Invoke-Curl $a }
            $parts = $res.Out -split ';'
            $code = 0; $size = 0.0; $tt = 0.0; $tpre = 0.0; $tst = 0.0
            if ($parts.Length -ge 5) { $code = [int](Parse-Num $parts[0]); $size = Parse-Num $parts[1]; $tt = Parse-Num $parts[2]; $tpre = Parse-Num $parts[3]; $tst = Parse-Num $parts[4] }
            if ($code -eq 403 -or $code -eq 413) { $refused++; continue }
            if ($size -gt 0 -and $code -ge 200 -and $code -lt 300) {
                $dur = $tst - $tpre
                if ($dur -lt 0.15) { $dur = $tt }
                if ($dur -gt 0) { return @{ Status = 'ok'; Mbps = (Round-Num (($size * 8.0) / $dur / 1000000.0) 2); Retried = ($refused -gt 0); Msg = '' } }
            }
            $m = $res.Err; if (-not $m) { $m = 'curl exit ' + $res.Exit + ', HTTP ' + $code }
            return @{ Status = 'error'; Mbps = $null; Retried = $false; Msg = $m }
        }
        return @{ Status = 'refused'; Mbps = $null; Retried = $true; Msg = 'The server refused every upload size.' }
    } finally { try { if (Test-Path $tmp) { Remove-Item $tmp -Force } } catch { } }
}

# ---------- DNS lookup time: median of 5 real names asked from one DNS server ----------
function Measure-DnsLookup([string]$server) {
    if (-not $server) { return $null }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return $null }
    $times = New-Object 'System.Collections.Generic.List[double]'
    foreach ($d in 'example.com', 'google.com', 'cloudflare.com', 'microsoft.com', 'wikipedia.org') {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName -Name $d -Server $server -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            $sw.Stop()
            $times.Add([double]$sw.ElapsedMilliseconds)
        } catch { $sw.Stop() }
    }
    if ($times.Count -eq 0) { return $null }
    $sorted = @($times | Sort-Object)
    return [double]$sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

# ---------- route to the internet (private addresses are hidden) ----------
function Convert-TraceLine([string]$line) {
    if ($line -notmatch '^\s*(\d+)\s+(.*)$') { return $null }
    $hop = [int]$Matches[1]
    $rest = $Matches[2]
    $ms = New-Object 'System.Collections.Generic.List[double]'
    foreach ($m in [regex]::Matches($rest, '(<?\d+)\s*ms')) {
        $t = $m.Groups[1].Value.Replace('<', '')
        $ms.Add((Parse-Num $t))
    }
    $addr = ($rest -replace '(<?\d+)\s*ms', '' -replace '\*', '').Trim()
    if (-not $addr -or $addr -match 'timed out') { $addr = 'no reply' }
    $avg = $null
    if ($ms.Count -gt 0) { $avg = Round-Num (($ms | Measure-Object -Average).Average) 0 }
    return @{ Hop = $hop; Addr = $addr; Ms = $avg }
}

function Hide-HopAddress([string]$addr) {
    if ($addr -eq 'no reply') { return $addr }
    if ($script:RouterIp -and $addr -eq $script:RouterIp) { return 'router (hidden)' }
    try {
        $ip = [System.Net.IPAddress]::Parse($addr)
        if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and (Test-PrivateV4 $addr)) { return 'private address (hidden)' }
    } catch { }
    return $addr
}

function Invoke-Trace([string]$target) {
    $hops = New-Object System.Collections.ArrayList
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'tracert.exe'
        $psi.Arguments = '-d -h 12 -w 800 ' + $target
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.WaitForExit(60000)
        foreach ($line in ($out -split "`r?`n")) {
            $h = Convert-TraceLine $line
            if ($h) { [void]$hops.Add(@{ Hop = $h.Hop; Address = (Hide-HopAddress $h.Addr); Ms = $h.Ms }) }
        }
    } catch { }
    return ,$hops
}

# fallback when tracert.exe is not available: ping with a rising TTL
function Trace-Fallback([string]$target, [int]$maxHops) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buf = New-Object byte[] 32
    $hops = New-Object System.Collections.ArrayList
    for ($ttl = 1; $ttl -le $maxHops; $ttl++) {
        if ($S.FullCancel) { break }
        $addr = 'no reply'; $ms = $null; $st = 'timeout'
        try {
            $opt = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
            $r = $ping.Send($target, 1500, $buf, $opt)
            $st = $r.Status.ToString()
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or $r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $addr = (Hide-HopAddress $r.Address.ToString()); $ms = [int]$r.RoundtripTime
            }
        } catch { $st = 'error' }
        [void]$hops.Add(@{ Hop = $ttl; Address = $addr; Ms = $ms })
        if ($st -eq 'Success') { break }
    }
    return ,$hops
}

# ---------- checks with plain-language explanations (PASS / INFO / WARN) ----------
function Add-Row($rows, [string]$name, [string]$value, [string]$level, [string]$note) {
    [void]$rows.Add(@{ name = $name; value = $value; level = $level; note = $note })
}

function Get-Diagnostics($r) {
    $rows = New-Object System.Collections.ArrayList
    $w = $r.Wifi
    if ($r.IsWifi) {
        if ($null -ne $w.Signal -and $w.Signal -ge 0) {
            if ($w.Signal -ge 70) { $lv = 'PASS'; $nt = 'Strong signal.' } elseif ($w.Signal -ge 40) { $lv = 'INFO'; $nt = 'Usable, but a closer position or 5 GHz would help.' } else { $lv = 'WARN'; $nt = 'Weak signal: expect slow and unstable speeds.' }
            Add-Row $rows 'Wi-Fi signal' ('{0}%' -f $w.Signal) $lv $nt
        }
        if ($null -ne $w.Rssi) {
            $est = ''; if ($w.RssiEstimated) { $est = ' (estimated from signal %)' }
            if ([int]$w.Rssi -ge -60) { $lv = 'PASS' } elseif ([int]$w.Rssi -ge -72) { $lv = 'INFO' } else { $lv = 'WARN' }
            Add-Row $rows 'RSSI' ('{0} dBm{1}' -f $w.Rssi, $est) $lv 'Closer to 0 is better. Below about -70 dBm is weak.'
        }
        $bandText = [string]$w.Band; if ($w.Channel -gt 0) { $bandText = ('{0}, channel {1}' -f $w.Band, $w.Channel) }
        if ($w.Band -like '2.4*') { $nt = '2.4 GHz reaches far but is slower and more crowded than 5 GHz.' } else { $nt = 'Faster band with less interference.' }
        Add-Row $rows 'Band and channel' $bandText 'INFO' $nt
        if ($null -ne $r.Crowd) {
            if ($r.Crowd -ge 6) { $lv = 'WARN' } elseif ($r.Crowd -ge 3) { $lv = 'INFO' } else { $lv = 'PASS' }
            Add-Row $rows 'Nearby networks on your channel' ([string]$r.Crowd) $lv 'Many networks on the same channel slow everyone down.'
        }
        if ($w.Radio) {
            if ($w.Radio -match '802\.11(ax|be|ac)') { $lv = 'PASS'; $nt = 'Modern Wi-Fi standard.' } else { $lv = 'WARN'; $nt = 'Older Wi-Fi standard limits speed.' }
            Add-Row $rows 'Radio type' $w.Radio $lv $nt
        }
        if ($w.RxRate -gt 0) {
            if ($w.RxRate -ge 200) { $lv = 'PASS' } elseif ($w.RxRate -ge 60) { $lv = 'INFO' } else { $lv = 'WARN' }
            Add-Row $rows 'Link rate (receive / transmit)' ('{0} / {1} Mbps' -f $w.RxRate, $w.TxRate) $lv 'Negotiated radio speed between this PC and the router, not your internet speed.'
        }
    } else {
        $ls = [int]$r.LinkSpeed
        if ($ls -ge 1000) { $lv = 'PASS'; $nt = 'Gigabit or faster cable link.' } elseif ($ls -ge 100) { $lv = 'INFO'; $nt = '100 Mbps cable link: it limits speeds above 100 Mbps. Check the cable and the router port.' } elseif ($ls -gt 0) { $lv = 'WARN'; $nt = 'Very slow cable link. Check the cable and the router port.' } else { $lv = 'INFO'; $nt = 'Windows did not report a link speed.' }
        $lt = 'wired'; if ($ls -gt 0) { $lt = ('wired, {0} Mbps' -f $ls) }
        Add-Row $rows 'Connection' $lt $lv $nt
    }
    $rt = $r.Router
    if ($rt -and $null -ne $rt.Avg) {
        if ($rt.Avg -le 10) { $lv = 'PASS' } elseif ($rt.Avg -le 30) { $lv = 'INFO' } else { $lv = 'WARN' }
        Add-Row $rows 'Router latency' ('{0} ms avg (min {1}, max {2})' -f $rt.Avg, $rt.Min, $rt.Max) $lv 'Time to reach your router. Should be a few milliseconds.'
        if ($rt.Jitter -le 8) { $lv = 'PASS' } elseif ($rt.Jitter -le 25) { $lv = 'INFO' } else { $lv = 'WARN' }
        Add-Row $rows 'Router jitter' ('{0} ms' -f $rt.Jitter) $lv 'How much the router ping jumps around.'
    }
    if ($rt) {
        if ($rt.Loss -eq 0) { $lv = 'PASS' } elseif ($rt.Loss -lt 3) { $lv = 'INFO' } else { $lv = 'WARN' }
        Add-Row $rows 'Router packet loss' ('{0}% ({1} of {2} replied)' -f $rt.Loss, $rt.Received, $rt.Sent) $lv 'Lost packets between this PC and the router cause stutter and slow pages.'
    }
    Add-Row $rows 'Router address' 'hidden' 'INFO' 'The router''s address is not stored in this report.'
    foreach ($p in @(@('Cloudflare', $r.Cf), @('Google', $r.Goog))) {
        $s = $p[1]
        if ($s -and $null -ne $s.Avg) {
            if ($s.Avg -le 40) { $lv = 'PASS' } elseif ($s.Avg -le 100) { $lv = 'INFO' } else { $lv = 'WARN' }
            Add-Row $rows ('Internet latency: ' + $p[0]) ('{0} ms avg, {1}% loss' -f $s.Avg, $s.Loss) $lv 'Round trip to the internet.'
        } elseif ($s) {
            Add-Row $rows ('Internet latency: ' + $p[0]) 'no reply' 'WARN' 'No answer from the internet.'
        }
    }
    if ($null -ne $r.DnsMs) {
        if ($r.DnsMs -le 50) { $lv = 'PASS' } elseif ($r.DnsMs -le 150) { $lv = 'INFO' } else { $lv = 'WARN' }
        Add-Row $rows 'DNS lookup time' ('{0} ms (median of 5)' -f $r.DnsMs) $lv 'How fast your DNS server turns names into addresses.'
    }
    $bad = @($r.DnsRecs | Where-Object { $_.Answers -eq $false })
    $typo = @($r.DnsRecs | Where-Object { $_.Typo })
    if ($r.DnsRecs.Count -gt 0) {
        $ok = @($r.DnsRecs | Where-Object { $_.Answers -eq $true }).Count
        if ($bad.Count -gt 0) { $lv = 'WARN' } else { $lv = 'PASS' }
        Add-Row $rows 'DNS servers answering' ('{0} of {1}' -f $ok, $r.DnsRecs.Count) $lv 'Every configured DNS server should answer.'
    }
    if ($typo.Count -gt 0) { Add-Row $rows 'DNS server typo' ($typo[0].Ip + ' (did you mean ' + $typo[0].Typo + '?)') 'WARN' 'A mistyped DNS address can break or slow browsing.' }
    if ($r.Shield -eq 'on') { $lv = 'PASS' } elseif ($typo.Count -gt 0 -or $bad.Count -gt 0) { $lv = 'WARN' } else { $lv = 'INFO' }
    Add-Row $rows 'DNS Shield (scam filter)' (([string]$r.Shield).ToUpper() + ': ' + (Hide-Router $r.ShieldSummary)) $lv 'ON means every DNS server is a filtering resolver.'
    if ($r.DownStatus -eq 'ok') {
        if ($r.Down -ge 25) { $lv = 'PASS' } elseif ($r.Down -ge 10) { $lv = 'INFO' } else { $lv = 'WARN' }
        $nt = 'Download from Cloudflare.'; if ($r.DownRetried) { $nt = 'Measured with a smaller file because the server refused bigger ones.' }
        Add-Row $rows 'Download speed' ('{0} Mbps' -f $r.Down) $lv $nt
    } elseif ($r.DownStatus -eq 'refused') {
        Add-Row $rows 'Download speed' 'refused' 'INFO' 'The speed server refused the test (HTTP 403). This does not mean the connection is slow.'
    } else {
        Add-Row $rows 'Download speed' 'failed' 'WARN' (Hide-Router ([string]$r.DownMsg))
    }
    if ($r.UpStatus -eq 'ok') {
        if ($r.Up -ge 5) { $lv = 'PASS' } elseif ($r.Up -ge 1) { $lv = 'INFO' } else { $lv = 'WARN' }
        Add-Row $rows 'Upload speed' ('{0} Mbps' -f $r.Up) $lv 'Upload to Cloudflare (random test data only).'
    } elseif ($r.UpStatus -eq 'refused') {
        Add-Row $rows 'Upload speed' 'refused' 'INFO' 'The speed server refused the upload test. This does not mean the connection is slow.'
    } else {
        Add-Row $rows 'Upload speed' 'failed' 'WARN' (Hide-Router ([string]$r.UpMsg))
    }
    if ($r.Trace.Count -gt 0) {
        $first = $r.Trace[0]
        $fm = ''; if ($null -ne $first.Ms) { $fm = (', first hop ' + $first.Ms + ' ms') }
        Add-Row $rows 'Route to the internet' ('{0} hops{1}' -f $r.Trace.Count, $fm) 'INFO' 'Traceroute to 1.1.1.1 (see the table below).'
    }
    return $rows
}

function Get-Bottleneck($r) {
    $w = $r.Wifi; $rt = $r.Router; $cf = $r.Cf; $gg = $r.Goog
    $cands = New-Object System.Collections.ArrayList
    function Add-Cand([int]$rank, [string]$title, [string]$detail) { [void]$cands.Add(@{ Rank = $rank; Title = $title; Detail = $detail }) }

    $inetAvg = $null; $inetLoss = 0
    $vals = @()
    foreach ($s in @($cf, $gg)) { if ($s -and $null -ne $s.Avg) { $vals += $s.Avg }; if ($s -and $s.Loss -gt $inetLoss) { $inetLoss = $s.Loss } }
    if ($vals.Count -gt 0) { $inetAvg = Round-Num (($vals | Measure-Object -Average).Average) 1 }
    $routerBad = $false
    if ($rt) {
        if ($rt.Loss -ge 3 -or ($null -ne $rt.Avg -and $rt.Avg -ge 40) -or ($null -ne $rt.Jitter -and $rt.Jitter -ge 25)) { $routerBad = $true }
    }
    if ($routerBad) {
        if ($r.IsWifi) {
            Add-Cand 1 'Wi-Fi link or router' ('Pings to your router average {0} ms with {1}% lost. The slowdown is between this PC and the router, before the internet. Move closer, use the 5 GHz band if you can, or restart the router.' -f $rt.Avg, $rt.Loss)
        } else {
            Add-Cand 1 'Cable, router or this PC''s network port' ('Pings to your router average {0} ms with {1}% lost, although you are on a cable. Check the cable and plugs, try another router port, or restart the router.' -f $rt.Avg, $rt.Loss)
        }
    }
    if ($r.IsWifi -and (($null -ne $w.Signal -and $w.Signal -ge 0 -and $w.Signal -le 35) -or ($null -ne $w.Rssi -and [int]$w.Rssi -le -75))) {
        Add-Cand 2 'Weak Wi-Fi signal' ('Signal is {0}% ({1} dBm). Walls and distance are likely limiting your speed.' -f $w.Signal, $w.Rssi)
    }
    if (-not $routerBad -and (($inetLoss -ge 3) -or ($null -ne $inetAvg -and $inetAvg -ge 100))) {
        Add-Cand 3 'Your internet provider (beyond the router)' ('The router answers quickly, but the internet averages {0} ms with up to {1}% loss. The slowdown is outside your home network.' -f $inetAvg, $inetLoss)
    }
    if ($r.IsWifi -and $w.Band -like '2.4*' -and $null -ne $r.Crowd -and $r.Crowd -ge 6) {
        Add-Cand 4 'Crowded 2.4 GHz channel' ('{0} other networks overlap your channel. Switch to 5 GHz or pick a quieter channel in the router settings.' -f $r.Crowd)
    }
    if ($null -ne $r.DnsMs -and $r.DnsMs -ge 200 -and -not $routerBad) {
        Add-Cand 5 'Slow DNS server' ('DNS lookups take {0} ms. Pages may feel slow to start even though the connection is fine. Try the scam filter or another DNS server.' -f $r.DnsMs)
    }
    if ($r.DownStatus -eq 'ok' -and $r.Down -lt 10 -and -not $routerBad) {
        if ($r.IsWifi -and $w.RxRate -gt 0 -and $r.Down -lt (0.35 * $w.RxRate) -and $null -ne $w.Signal -and $w.Signal -lt 60) {
            Add-Cand 6 'Wi-Fi speed' ('Download is {0} Mbps while the Wi-Fi link is {1} Mbps and the signal is only {2}%. Wi-Fi is the likely limit.' -f $r.Down, $w.RxRate, $w.Signal)
        } else {
            Add-Cand 6 'Internet plan or provider speed' ('Download is only {0} Mbps although the local network and router look healthy. The limit is probably your plan or your provider.' -f $r.Down)
        }
    }
    $items = New-Object System.Collections.ArrayList
    $sorted = @($cands | Sort-Object { $_.Rank })
    foreach ($c in $sorted) { [void]$items.Add(@{ level = 'WARN'; text = ($c.Title + ': ' + $c.Detail) }) }
    if ($r.IsWifi -and $w.Band -like '2.4*' -and @($sorted | Where-Object { $_.Rank -eq 4 }).Count -eq 0) {
        [void]$items.Add(@{ level = 'INFO'; text = 'You are on the 2.4 GHz band. 5 GHz is usually faster if your router and distance allow it.' })
    }
    if ($r.DownStatus -eq 'refused') {
        [void]$items.Add(@{ level = 'INFO'; text = 'The speed server refused the download test. That is not the same as slow, so speed was not judged.' })
    }
    if ($sorted.Count -gt 0) {
        return @{ title = [string]$sorted[0].Title; detail = [string]$sorted[0].Detail; level = 'WARN'; items = @($items) }
    }
    $okText = 'Signal, router, internet latency and DNS all look healthy in this test.'
    if (-not $r.IsWifi) { $okText = 'Cable link, router, internet latency and DNS all look healthy in this test.' }
    return @{ title = 'No clear bottleneck'; detail = $okText; level = 'PASS'; items = @($items) }
}

# ---------- the test ----------
try {
    Prog 2 'Reading the connection'
    $wifi = @{ Signal = $null; Rssi = $null; RssiEstimated = $true; Band = ''; Channel = 0; Radio = ''; RxRate = 0; TxRate = 0 }
    $crowd = $null
    if ($IsWifi) {
        $det = Get-WlanDetails $AdapterName
        $wifi = @{ Signal = [int]$S.Signal; Rssi = $det.Rssi; RssiEstimated = $det.RssiEstimated; Band = [string]$S.Band; Channel = [int]$S.Channel; Radio = [string]$S.Radio; RxRate = [double]$S.RxRate; TxRate = [double]$S.TxRate }
        $crowd = Get-CrowdCount ([int]$S.Channel) ([string]$S.Bssid)
    }

    Prog 6 'Pinging your router (30 pings)'
    $router = $null
    if ($Gateway) { $router = Ping-Stats $Gateway 30 1000 }
    Prog 22 'Pinging the internet (Cloudflare)'
    $cf = Ping-Stats '1.1.1.1' 20 1000
    Prog 34 'Pinging the internet (Google)'
    $goog = Ping-Stats '8.8.8.8' 20 1000

    Prog 44 'Checking DNS servers and the scam filter'
    $recs = Get-DnsRecords $AdapterName
    foreach ($d in $recs) {
        if ($S.FullCancel) { break }
        if ($d.LinkLocal) { continue }
        $t = Test-DnsServer ([string]$d.Ip)
        $d.Answers = $t.Answers; $d.Ms = $t.Ms
    }
    $verdict = Get-ShieldVerdict $recs
    $dnsTarget = $null
    foreach ($d in $recs) { if ($d.IsWifi -and $d.Answers -eq $true -and -not $d.Ip.Contains(':')) { $dnsTarget = $d.Ip; break } }
    if (-not $dnsTarget) { foreach ($d in $recs) { if ($d.Answers -eq $true) { $dnsTarget = $d.Ip; break } } }
    Prog 50 'Timing DNS lookups'
    $dnsMs = Measure-DnsLookup $dnsTarget

    Prog 54 'Testing download speed'
    $dl1 = Measure-Download $Ip
    $dl = $dl1
    $downs = @(); if ($dl1.Status -eq 'ok') { $downs += $dl1.Mbps }
    if ($dl1.Status -eq 'ok' -and -not $S.FullCancel) {
        Prog 66 'Testing download speed (2nd run)'
        $dl2 = Measure-Download $Ip
        if ($dl2.Status -eq 'ok') { $downs += $dl2.Mbps }
    }
    $best = $null; $avg = $null
    if ($downs.Count -gt 0) {
        $best = ($downs | Measure-Object -Maximum).Maximum
        $avg = [math]::Round((($downs | Measure-Object -Sum).Sum / $downs.Count), 2)
    }
    Prog 78 'Testing upload speed'
    $ul = @{ Status = 'error'; Mbps = $null; Retried = $false; Msg = 'cancelled' }
    if (-not $S.FullCancel) { $ul = Measure-Upload $Ip }

    Prog 88 'Tracing the route to the internet'
    $trace = @(Invoke-Trace '1.1.1.1')
    if ($trace.Count -eq 0 -and -not $S.FullCancel) { $trace = @(Trace-Fallback '1.1.1.1' 12) }

    Prog 97 'Working out the result'
    $r = @{
        IsWifi = [bool]$IsWifi; LinkSpeed = [int]$S.LinkSpeed; Wifi = $wifi; Crowd = $crowd
        Router = $router; Cf = $cf; Goog = $goog
        DnsRecs = @($recs); Shield = $verdict.Shield; ShieldSummary = $verdict.Summary; DnsMs = $dnsMs
        Down = $best; DownStatus = $dl.Status; DownRetried = $dl.Retried; DownMsg = $dl.Msg
        Up = $ul.Mbps; UpStatus = $ul.Status; UpMsg = $ul.Msg
        Trace = @($trace)
    }
    if ($downs.Count -gt 0) { $r.DownStatus = 'ok' }
    $bn = Get-Bottleneck $r
    $diag = Get-Diagnostics $r

    # ---- grade, score and short advice
    $score = 100.0
    $tips = New-Object System.Collections.ArrayList
    $ip1 = $cf.Avg
    $rp = $null; if ($router) { $rp = $router.Avg }
    $loss = [double]$cf.Loss
    if ($goog -and [double]$goog.Loss -gt $loss) { $loss = [double]$goog.Loss }
    $jit = $cf.Jitter
    if ($null -eq $ip1) { $score -= 50 }
    elseif ($ip1 -gt 150) { $score -= 35 } elseif ($ip1 -gt 80) { $score -= 20 } elseif ($ip1 -gt 40) { $score -= 8 }
    if ($loss -gt 5) { $score -= 30 } elseif ($loss -gt 1) { $score -= 15 } elseif ($loss -gt 0) { $score -= 5 }
    if ($null -ne $jit) { if ($jit -gt 30) { $score -= 15 } elseif ($jit -gt 15) { $score -= 8 } }
    if ($null -ne $dnsMs) { if ($dnsMs -gt 200) { $score -= 10 } elseif ($dnsMs -gt 100) { $score -= 5 } }
    if ($null -eq $best) { if ($r.DownStatus -ne 'refused') { $score -= 25 } }
    elseif ($best -lt [double]$Limit) { $score -= 25 } elseif ($best -lt 25) { $score -= 10 }
    if ($null -ne $rp) { if ($rp -gt 30) { $score -= 12 } elseif ($rp -gt 15) { $score -= 6 } }
    if ($IsWifi -and $null -ne $wifi.Signal -and [int]$wifi.Signal -ge 0) { if ([int]$wifi.Signal -lt 34) { $score -= 20 } elseif ([int]$wifi.Signal -lt 50) { $score -= 8 } }
    if ($score -lt 0) { $score = 0 }
    if ($score -ge 90) { $grade = 'Excellent' } elseif ($score -ge 75) { $grade = 'Good' } elseif ($score -ge 55) { $grade = 'Fair' } else { $grade = 'Poor' }
    foreach ($it in $bn.items) { if ($it.level -eq 'WARN') { [void]$tips.Add([string]$it.text) } }
    if ($null -ne $jit -and $jit -gt 20) { [void]$tips.Add('The connection is unstable (high jitter). Other devices downloading or streaming may be using the bandwidth.') }
    if ($null -ne $best -and $best -lt [double]$Limit) { [void]$tips.Add('Download speed is below your limit of ' + $Limit + ' Mbps.') }
    if ($tips.Count -eq 0) { [void]$tips.Add('Everything looks good.') }

    # ---- the saved report (the router's address and your local IP are not stored)
    if ($router) { $router.Target = 'router (hidden)' }
    $dnsServers = @()
    $done = @{}
    foreach ($d in $recs) {
        if ($done.ContainsKey($d.Ip)) { continue }
        $done[$d.Ip] = $true
        $ipShown = [string]$d.Ip; if ($d.Kind -eq 'router') { $ipShown = 'router (hidden)' }
        $dnsServers += @{ Ip = $ipShown; Kind = $d.Kind; Label = $d.Label; Typo = $d.Typo; Answers = $d.Answers; Ms = $d.Ms }
    }
    $rep = @{
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv); IsWifi = [bool]$IsWifi
        Adapter = $AdapterName; LinkType = [string]$S.LinkType; LinkSpeedMbps = [int]$S.LinkSpeed
        Ssid = [string]$S.Ssid; Signal = $wifi.Signal; Channel = $wifi.Channel; Band = $wifi.Band; Radio = $wifi.Radio
        RxRate = $wifi.RxRate; TxRate = $wifi.TxRate; Rssi = $wifi.Rssi; RssiEstimated = $wifi.RssiEstimated; Crowd = $crowd
        Router = $router; Internet = $cf; Internet2 = $goog
        Dns = @{ LookupMs = $dnsMs; Shield = $verdict.Shield; ShieldSummary = (Hide-Router $verdict.Summary); Servers = @($dnsServers) }
        Download = @{ Best = $best; Avg = $avg; Runs = @($downs); Status = $r.DownStatus; Msg = (Hide-Router ([string]$dl.Msg)) }
        Upload = @{ Mbps = $ul.Mbps; Status = $ul.Status; Msg = (Hide-Router ([string]$ul.Msg)) }
        Trace = @($trace)
        Diag = @($diag); Bottleneck = $bn
        Summary = @{
            Grade = $grade; Score = [math]::Round($score, 0); DownBest = $best; DownAvg = $avg; Up = $ul.Mbps
            RouterPing = $rp; InternetPing = $ip1; GooglePing = $goog.Avg; Jitter = $jit; LossPct = $loss; DnsAvg = $dnsMs
        }
        Tips = @($tips)
    }
    if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
    $path = Join-Path $OutDir ('fulltest-' + (Get-Date).ToString('yyyyMMdd-HHmmss', $inv) + '.json')
    $json = $rep | ConvertTo-Json -Depth 7
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    try { Get-ChildItem -LiteralPath $OutDir -Filter 'fulltest-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    Prog 100 'Done'
    $Q.Enqueue(@{ T = 'full'; Status = 'ok'; Path = $path; Report = $rep })
} catch {
    $Q.Enqueue(@{ T = 'full'; Status = 'error'; Msg = $_.Exception.Message })
}
'@
$script:FullSource = "param(`$Ip, `$Gateway, `$IsWifi, `$Q, `$S, `$OutDir, `$Limit)`n" + $script:DnsHelpers + "`n" + $script:FullBody

function Start-FullTest {
    if ($script:FullRunning) { Show-Balloon 'Full test' 'A full test is already running.'; return }
    if ($script:SpeedRunning) { Show-Balloon 'Full test' 'Wait for the speed test to finish first.'; return }
    $W = $script:Wifi
    if (-not $W.Connected -or -not $W.LocalIp) { Show-Balloon 'Full test' 'No network connection.'; return }
    try {
        $W['FullPct'] = 0; $W['FullText'] = 'Starting'; $W['FullCancel'] = $false
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:FullSource).AddArgument([string]$W.LocalIp).AddArgument([string]$W.Gateway).AddArgument([bool]$W.IsWifi).AddArgument($script:FullQueue).AddArgument($W).AddArgument($script:FullDir).AddArgument([double]$script:Settings['SlowLimit'])
        $script:FullRs = $rs
        $script:FullPs = $ps
        $script:FullStartUtc = [datetime]::UtcNow
        $script:FullRunning = $true
        [void]$ps.BeginInvoke()
        Write-Log ('Full test started on ' + $W.LinkType + ' adapter ' + $W.Adapter + '.')
        $script:Form.Invalidate()
    } catch {
        $script:FullRunning = $false
        Write-Log ('Full test could not start: ' + $_.Exception.Message) 'ERROR'
    }
}

function Show-FullTestPopup($rep) {
    $s = $rep.Summary
    $grade = [string]$s.Grade
    if ($grade -eq 'Excellent' -or $grade -eq 'Good') { $acc = $script:Pal.Teal } elseif ($grade -eq 'Fair') { $acc = $script:Pal.Amber } else { $acc = $script:Pal.Red }
    $dn = '--'; if ($null -ne $s.DownBest) { $dn = (Format-Mbps ([double]$s.DownBest)) }
    $upt = '--'; if ($null -ne $s.Up) { $upt = (Format-Mbps ([double]$s.Up)) }
    $pg = '--'; if ($null -ne $s.InternetPing) { $pg = (Fmt ([double]$s.InternetPing) '0') }
    $jt = '--'; if ($null -ne $s.Jitter) { $jt = (Fmt ([double]$s.Jitter) '0') }
    $tip = ''
    if ($rep.Bottleneck) { $tip = ([string]$rep.Bottleneck.title + ': ' + [string]$rep.Bottleneck.detail) }
    elseif ($rep.Tips -and @($rep.Tips).Count -gt 0) { $tip = [string]@($rep.Tips)[0] }
    $lines = @(('Download ' + $dn + ' Mbps    Upload ' + $upt + ' Mbps'), ('Internet ping ' + $pg + ' ms    jitter ' + $jt + ' ms    loss ' + (Fmt ([double]$s.LossPct) '0.#') + '%'))
    $lines += @(Split-TextLines $tip 52 | Select-Object -First 2)
    $item = [pscustomobject]@{
        Type = 'full'; Mac = ''; Title = 'Full test finished'; Value = $null; ValueText = $grade; Accent = $acc; Lines = $lines
        Buttons = @(@{ Id = 'dash'; Text = 'Dashboard'; Primary = $true }, @{ Id = 'ok'; Text = 'OK' })
    }
    Show-AlertPopup $item
}

function Handle-FullResult($r) {
    $script:FullRunning = $false
    try { if ($script:FullPs) { $script:FullPs.Dispose() } } catch { }
    try { if ($script:FullRs) { $script:FullRs.Close(); $script:FullRs.Dispose() } } catch { }
    $script:FullPs = $null; $script:FullRs = $null
    $W = $script:Wifi
    if ([string]$r.Status -eq 'ok') {
        $rep = $r.Report
        $s = $rep.Summary
        Write-Log ('Full test finished: ' + $s.Grade + ' (score ' + $s.Score + '), download ' + $s.DownBest + ' Mbps, upload ' + $s.Up + ' Mbps.')
        $name = [System.IO.Path]::GetFileName([string]$r.Path)
        $cells = @((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), [string]$s.Grade, [string]$s.Score)
        foreach ($v in @($s.DownBest, $s.Up, $s.RouterPing, $s.InternetPing, $s.Jitter, $s.LossPct, $s.DnsAvg)) { if ($null -eq $v) { $cells += '' } else { $cells += (Fmt ([double]$v) '0.##') } }
        $cells += (Csv-Field ([string]$rep.LinkType)); $cells += (Csv-Field ([string]$rep.Adapter)); $cells += (Csv-Field ([string]$rep.Ssid))
        if ($rep.IsWifi) { $cells += [string]$rep.Signal } else { $cells += '' }
        $cells += (Csv-Field $name)
        [void]$script:FullCsv.Write($script:FullCsvPath, ($cells -join ','))
        if ($null -ne $s.DownBest) {
            $W['LastSpeed'] = [double]$s.DownBest; $W['LastSpeedTime'] = [datetime]::UtcNow; $W['LastSpeedText'] = 'just now'
            Save-LastSpeed ([double]$s.DownBest)
            Log-SpeedRow 'ok' $s.DownBest 'full test' $null $null
        }
        Show-FullTestPopup $rep
    } else {
        Write-Log ('Full test failed: ' + $r.Msg) 'WARN'
        Show-Balloon 'Full test failed' ([string]$r.Msg)
    }
    $script:Form.Invalidate()
}

function Update-FullTestWatcher {
    $item = $null
    while ($script:FullQueue.TryDequeue([ref]$item)) {
        try { Handle-FullResult $item } catch { Write-Log ('Full test result error: ' + $_.Exception.Message) 'ERROR' }
    }
    if ($script:FullRunning -and (([datetime]::UtcNow - $script:FullStartUtc).TotalMinutes -gt 8)) {
        Write-Log 'Full test took too long - stopping it.' 'WARN'
        try { $script:Wifi['FullCancel'] = $true; [void]$script:FullPs.BeginStop($null, $null) } catch { }
        try { Stop-SpeedRunner } catch { }
        $script:FullRunning = $false
    }
}

# ---------------------------------------------------------------- outages, data usage, Wi-Fi scan, battery, device guesses
$script:OutagePath = Join-Path $script:DataDir 'outages.csv'
$script:Outages = @()
$script:OutagesAt = [DateTime]::MinValue
$script:OutageSeqSeen = 0
$script:DataAlert = @{ Period = ''; L80 = $false; L100 = $false }
$script:ReportHtml = Join-Path $script:DataDir 'provider-report.html'
$script:ScanJsonPath = Join-Path $script:DataDir 'wifi-scan.json'

function Format-Duration([double]$sec) {
    $n = [int][Math]::Round($sec)
    if ($n -lt 60) { return ([string]$n + ' s') }
    if ($n -lt 3600) { return ([string][int][Math]::Floor($n / 60) + ' min ' + [string]($n % 60) + ' s') }
    return ([string][int][Math]::Floor($n / 3600) + ' h ' + [string][int][Math]::Floor(($n % 3600) / 60) + ' min')
}

function Format-GB([double]$bytes) {
    $gb = $bytes / 1e9
    if ($gb -ge 100) { return ((Fmt $gb '0') + ' GB') }
    if ($gb -ge 10) { return ((Fmt $gb '0.0') + ' GB') }
    return ((Fmt $gb '0.00') + ' GB')
}

function Get-CauseLabel([string]$cause) {
    if ($cause -eq 'internet') { return 'internet (beyond your router)' }
    if ($cause -eq 'router') { return 'router or local network' }
    if ($cause -eq 'no link') { return 'no network link on this PC' }
    return $cause
}

# ---------- outages ----------
function Load-Outages {
    $script:OutagesAt = Get-Date
    $list = New-Object System.Collections.ArrayList
    try {
        if (Test-Path -LiteralPath $script:OutagePath) {
            foreach ($ln in @(Get-Content -LiteralPath $script:OutagePath -Tail 300 -Encoding UTF8)) {
                if (-not $ln -or $ln.StartsWith('Start')) { continue }
                $f = $ln.Split(',')
                if ($f.Count -lt 4) { continue }
                $a = [datetime]::MinValue; $b = [datetime]::MinValue
                if (-not [datetime]::TryParseExact($f[0], 'yyyy-MM-dd HH:mm:ss', $script:Inv, [System.Globalization.DateTimeStyles]::None, [ref]$a)) { continue }
                if (-not [datetime]::TryParseExact($f[1], 'yyyy-MM-dd HH:mm:ss', $script:Inv, [System.Globalization.DateTimeStyles]::None, [ref]$b)) { continue }
                [void]$list.Add(@{ Start = $a; End = $b; Seconds = [int]$f[2]; Cause = [string]$f[3] })
            }
        }
    } catch { }
    $script:Outages = @($list)
}

function Show-OutagePopup($a) {
    $cause = [string]$a.Cause
    if ($cause -eq 'internet') { $title = 'Internet is back' } elseif ($cause -eq 'router') { $title = 'Network is back' } else { $title = 'Connection is back' }
    $lines = @(('It was down for ' + (Format-Duration ([double]$a.Seconds)) + '.'), ('From ' + ([datetime]$a.Start).ToString('HH:mm:ss') + ' to ' + ([datetime]$a.End).ToString('HH:mm:ss') + '.'), ('Cause: ' + (Get-CauseLabel $cause) + '.'))
    $item = [pscustomobject]@{
        Type = 'outage'; Mac = ''; Title = $title; Value = $null; ValueText = ''; Accent = $script:Pal.Amber; Lines = $lines
        Buttons = @(@{ Id = 'dash'; Text = 'Dashboard'; Primary = $true }, @{ Id = 'ok'; Text = 'OK' })
    }
    Show-AlertPopup $item
    Write-Log ('Outage popup shown (' + $cause + ', ' + $a.Seconds + ' s).')
    return $true
}

function Update-OutageWatcher {
    $W = $script:Wifi
    if ([int]$W.OutageSeq -ne $script:OutageSeqSeen) {
        $script:OutageSeqSeen = [int]$W.OutageSeq
        Load-Outages
        $lo = $W.LastOutage
        if ($null -ne $lo) {
            Write-Log ('Outage ended: ' + $lo.Cause + ', ' + $lo.Seconds + ' s.')
            if ([int]$lo.Seconds -ge 10) { Request-Alert @{ Type = 'outage'; Cause = [string]$lo.Cause; Seconds = [int]$lo.Seconds; Start = $lo.Start; End = $lo.End } }
        }
    } elseif ((((Get-Date) - $script:OutagesAt).TotalSeconds) -gt 60) { Load-Outages }
}

# ---------- data limit ----------
function Show-DataPopup($a) {
    $pct = [double]$a.Pct
    if ([int]$a.Level -ge 100) { $title = 'Data limit reached'; $acc = $script:Pal.Red } else { $title = 'Data limit almost reached'; $acc = $script:Pal.Amber }
    $lines = @(('Used ' + (Fmt ([double]$a.Used) '0.0') + ' GB of your ' + (Fmt ([double]$a.Limit) '0') + ' GB since ' + [string]$a.Since + '.'), 'Counted on this PC while the dashboard runs.')
    $item = [pscustomobject]@{
        Type = 'data'; Mac = ''; Title = $title; Value = $null; ValueText = ((Fmt $pct '0') + '%'); Accent = $acc; Lines = $lines
        Buttons = @(@{ Id = 'ok'; Text = 'OK'; Primary = $true })
    }
    Show-AlertPopup $item
    return $true
}

function Eval-DataLimit {
    $lim = [double]$script:Settings['DataLimitGB']
    if ($lim -le 0 -or -not [bool]$script:Settings['AlertData']) { return }
    $W = $script:Wifi
    $ps = [string]$W.PeriodStart
    if (-not $ps) { return }
    if ($script:DataAlert.Period -ne $ps) { $script:DataAlert = @{ Period = $ps; L80 = $false; L100 = $false } }
    $used = ([double]$W.PeriodRx + [double]$W.PeriodTx) / 1e9
    $pct = $used / $lim * 100.0
    if ($pct -ge 100 -and -not $script:DataAlert.L100) {
        $script:DataAlert.L100 = $true; $script:DataAlert.L80 = $true
        Request-Alert @{ Type = 'data'; Pct = $pct; Used = $used; Limit = $lim; Level = 100; Since = $ps }
    } elseif ($pct -ge 80 -and -not $script:DataAlert.L80) {
        $script:DataAlert.L80 = $true
        Request-Alert @{ Type = 'data'; Pct = $pct; Used = $used; Limit = $lim; Level = 80; Since = $ps }
    }
}

# data used in this period (Network page)
function Draw-UsageOutagePanel($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts; $wf = $script:Wifi
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text
    Draw-Panel $g $x $y $w $h ''
    $ix = $x + (S 12); $iw = $w - (S 24)
    # ---- data
    $rx = [double]$wf.PeriodRx; $tx = [double]$wf.PeriodTx; $used = $rx + $tx
    $since = [string]$wf.PeriodStart
    if ($since) { $since = ([datetime]$since).ToString('d MMM', $script:Inv) }
    Draw-Text $g ('DATA SINCE ' + $since.ToUpper()) $F.Muted $mut $ix ($y + (S 6)) ($iw / 2) (S 14) 'LM'
    $lim = [double]$script:Settings['DataLimitGB']
    Draw-Text $g ($script:ArrowDown + ' ' + (Format-GB $rx) + '    ' + $script:ArrowUp + ' ' + (Format-GB $tx) + '    total ' + (Format-GB $used)) $F.PanelTitle $txt $ix ($y + (S 20)) $iw (S 16) 'LM'
    if ($lim -gt 0) {
        $pct = $used / ($lim * 1e9) * 100.0
        if ($pct -ge 100) { $bc = $p.Red } elseif ($pct -ge 80) { $bc = $p.Amber } else { $bc = $p.Teal }
        Draw-Text $g ((Fmt $pct '0') + '% of ' + (Fmt $lim '0') + ' GB') $F.Muted (Get-Brush $bc) ($ix + $iw / 2) ($y + (S 6)) ($iw / 2) (S 14) 'RM'
        $g.FillRectangle((Get-Brush $p.Track), [single]$ix, [single]($y + (S 38)), [single]$iw, [single](S 5))
        $g.FillRectangle((Get-Brush $bc), [single]$ix, [single]($y + (S 38)), [single]($iw * [Math]::Min(100.0, $pct) / 100.0), [single](S 5))
    } else {
        Draw-Text $g 'no limit set' $F.Muted $mut ($ix + $iw / 2) ($y + (S 6)) ($iw / 2) (S 14) 'RM'
    }
}

# ---------- nearby Wi-Fi networks and the best channel ----------
$script:ScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Scan = @{ Running = $false; At = [DateTime]::MinValue; Networks = @(); Advice = $null; Error = ''; Seen = $false }
$script:ScanScroll = 0
$script:SysScroll = 0.0      # System tab scroll position (small windows)
$script:NetScroll = 0.0      # Network tab scroll position (small windows)
$script:NetMax = 0.0
$script:NetRect = [System.Drawing.Rectangle]::Empty
$script:SysMax = 0.0
$script:SysRect = [System.Drawing.Rectangle]::Empty
$script:ScanPanelRect = [System.Drawing.Rectangle]::Empty
$script:ScanPs = $null; $script:ScanRs = $null
$script:ScanStartUtc = [DateTime]::UtcNow

$script:ScanSource = @'
param($Q, $MyBssid, $MyChannel)

function Parse-Scan([string]$text) {
    $nets = New-Object System.Collections.ArrayList
    $ssid = ''; $auth = ''; $cur = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^SSID\s+\d+\s*:\s*(.*)$') { $ssid = $Matches[1].Trim(); $auth = ''; $cur = $null; continue }
        if ($line -match '^\s*Authentication\s*:\s*(.+)$' -and $null -eq $cur) { $auth = $Matches[1].Trim(); continue }
        if ($line -match '^\s*BSSID\s+\d+\s*:\s*(.+)$') {
            $cur = @{ Ssid = $ssid; Auth = $auth; Bssid = $Matches[1].Trim().ToLower(); Signal = 0; Radio = ''; Band = ''; Channel = 0; Mine = $false }
            [void]$nets.Add($cur); continue
        }
        if ($null -ne $cur) {
            if ($line -match '^\s*Signal\s*:\s*(\d+)') { $cur.Signal = [int]$Matches[1]; continue }
            if ($line -match '^\s*Radio type\s*:\s*(.+)$') { $cur.Radio = $Matches[1].Trim(); continue }
            if ($line -match '^\s*Band\s*:\s*(.+)$') { $cur.Band = $Matches[1].Trim(); continue }
            if ($line -match '^\s*Channel\s*:\s*(\d+)') { $cur.Channel = [int]$Matches[1]; continue }
        }
    }
    foreach ($n in $nets) {
        if (-not $n.Band) { if ($n.Channel -gt 0 -and $n.Channel -le 14) { $n.Band = '2.4 GHz' } elseif ($n.Channel -gt 14) { $n.Band = '5 GHz' } }
        if ($MyBssid -and $n.Bssid -eq ([string]$MyBssid).ToLower()) { $n.Mine = $true }
    }
    return ,$nets
}

# how crowded a channel is: nearby networks, stronger ones count more, closer channels overlap more (2.4 GHz channels are only 5 MHz apart)
function Score-Channel([string]$band, [int]$ch, $nets) {
    $score = 0.0; $count = 0
    foreach ($n in $nets) {
        if ($n.Mine) { continue }
        if ($band -eq '2.4') {
            if ($n.Band -notlike '2.4*') { continue }
            $d = [math]::Abs($n.Channel - $ch)
            if ($d -le 4) { $w = @(1.0, 0.75, 0.5, 0.25, 0.1)[$d]; $score += $w * ($n.Signal / 100.0); $count++ }
        } else {
            if ($n.Band -notlike '5*') { continue }
            if ($n.Channel -eq $ch) { $score += 1.0 * ($n.Signal / 100.0); $count++ }
            elseif ([math]::Abs($n.Channel - $ch) -le 4) { $score += 0.3 * ($n.Signal / 100.0); $count++ }
        }
    }
    return @{ Channel = $ch; Score = [math]::Round($score, 2); Count = $count }
}

function Get-Advice($nets, [int]$myChannel) {
    $best24 = $null
    foreach ($c in 1, 6, 11) { $r = Score-Channel '2.4' $c $nets; if ($null -eq $best24 -or $r.Score -lt $best24.Score) { $best24 = $r } }
    $best5 = $null
    foreach ($c in 36, 40, 44, 48, 149, 153, 157, 161, 165) { $r = Score-Channel '5' $c $nets; if ($null -eq $best5 -or $r.Score -lt $best5.Score) { $best5 = $r } }
    $mine = $null
    foreach ($n in $nets) { if ($n.Mine) { $mine = $n; break } }
    $myInfo = $null
    if ($mine) {
        if ($mine.Band -like '2.4*') { $myInfo = Score-Channel '2.4' $mine.Channel $nets; $myInfo.Band = '2.4 GHz' } else { $myInfo = Score-Channel '5' $mine.Channel $nets; $myInfo.Band = '5 GHz' }
    } elseif ($myChannel -gt 0) {
        if ($myChannel -le 14) { $myInfo = Score-Channel '2.4' $myChannel $nets; $myInfo.Band = '2.4 GHz' } else { $myInfo = Score-Channel '5' $myChannel $nets; $myInfo.Band = '5 GHz' }
    }
    return @{ Best24 = $best24; Best5 = $best5; Mine = $myInfo }
}

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'netsh.exe'
    $psi.Arguments = 'wlan show networks mode=bssid'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(15000)
    $nets = Parse-Scan $text
    $adv = Get-Advice $nets ([int]$MyChannel)
    $Q.Enqueue(@{ T = 'scan'; Status = 'ok'; Networks = @($nets); Advice = $adv })
} catch {
    $Q.Enqueue(@{ T = 'scan'; Status = 'error'; Msg = $_.Exception.Message })
}
'@

function Start-WifiScan {
    if ($script:Scan.Running) { return }
    try {
        $W = $script:Wifi
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:ScanSource).AddArgument($script:ScanQueue).AddArgument([string]$W.Bssid).AddArgument([int]$W.Channel)
        $script:ScanRs = $rs; $script:ScanPs = $ps
        $script:Scan.Running = $true
        $script:ScanStartUtc = [DateTime]::UtcNow
        [void]$ps.BeginInvoke()
    } catch { $script:Scan.Running = $false; Write-Log ('Wi-Fi scan could not start: ' + $_.Exception.Message) 'WARN' }
}

function Update-ScanWatcher {
    $item = $null
    while ($script:ScanQueue.TryDequeue([ref]$item)) {
        $script:Scan.Running = $false
        try { if ($script:ScanPs) { $script:ScanPs.Dispose() } } catch { }
        try { if ($script:ScanRs) { $script:ScanRs.Close(); $script:ScanRs.Dispose() } } catch { }
        $script:ScanPs = $null; $script:ScanRs = $null
        $script:Scan.At = Get-Date
        $script:Scan.Seen = $true
        if ([string]$item.Status -eq 'ok') {
            $script:Scan.Networks = @($item.Networks); $script:Scan.Advice = $item.Advice; $script:Scan.Error = ''
            try {
                $o = @{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv); Networks = @($item.Networks); Advice = $item.Advice }
                [System.IO.File]::WriteAllText($script:ScanJsonPath, ($o | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        } else { $script:Scan.Error = [string]$item.Msg; Write-Log ('Wi-Fi scan failed: ' + $item.Msg) 'WARN' }
        $script:Form.Invalidate()
    }
    if ($script:Scan.Running -and (([DateTime]::UtcNow - $script:ScanStartUtc).TotalSeconds -gt 40)) { $script:Scan.Running = $false }
    # keep it fresh while the nearby list is showing
    if ([bool]$script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network' -and [string]$script:Settings['NetView'] -eq 'Nearby' -and $script:Form.Visible -and -not $script:Scan.Running -and ((Get-Date) - $script:Scan.At).TotalSeconds -gt 30) { Start-WifiScan }
}

function Draw-NetViewPills($g, [double]$x, [double]$y) {
    $p = $script:Pal; $F = $script:Fonts
    $ph = (S 20); $py = $y + (S 3); $gap = (S 4)
    $items = @(@('nv_dev', 'Devices', 'Devices', (S 58)), @('nv_wifi', 'Wi-Fi', 'Nearby', (S 42)), @('nv_dns', 'DNS', 'Dns', (S 50)), @('nv_speed', 'Speed', 'Speed', (S 48)))
    $cx = $x + (S 8)
    foreach ($it in $items) {
        $r = New-Object System.Drawing.Rectangle([int]$cx, [int]$py, [int]$it[3], [int]$ph)
        $script:Hit[$it[0]] = $r
        $sel = ([string]$script:Settings['NetView'] -eq $it[2])
        $dark = [System.Drawing.Color]::FromArgb(14, 22, 30)
        if ($sel) { $fill = $p.Teal; $tc = $dark }
        elseif ($script:Hover -eq $it[0]) { $fill = $p.Hover; $tc = $p.Text }
        else { $fill = $p.Chip; $tc = $p.Muted }
        Fill-Pill $g (Get-Brush $fill) $r.X $r.Y $r.Width $r.Height
        if ($it[0] -eq 'nv_dns') {
            # a small dot shows the DNS Shield state at a glance
            $sh = [string]$script:Dns.Shield
            if ($sh -eq 'on') { $dc = $p.Teal } elseif ($sh -eq 'off') { $dc = $p.Red } else { $dc = $p.Off }
            if ($sel -and $sh -eq 'on') { $dc = $dark }
            $dr = (S 3)
            $g.FillEllipse((Get-Brush $dc), [single]($r.X + (S 8)), [single]($r.Y + $r.Height / 2.0 - $dr), [single](2 * $dr), [single](2 * $dr))
            Draw-Text $g $it[1] $F.Muted (Get-Brush $tc) ($r.X + (S 8)) $r.Y ($r.Width - (S 8)) $r.Height 'CM'
        } else {
            Draw-Text $g $it[1] $F.Muted (Get-Brush $tc) $r.X $r.Y $r.Width $r.Height 'CM'
        }
        $cx += $it[3] + $gap
    }
}

# DNS details: every DNS server, what it is, whether it answers, and the buttons to re-check or fix
function Draw-DnsView($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts; $D = $script:Dns
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text
    Draw-Panel $g $x $y $w $h ''
    Draw-NetViewPills $g $x $y
    if ($D.Shield -eq 'on') { $pb = Get-Brush $p.Teal; $pt = 'Shield ON' }
    elseif ($D.Shield -eq 'off') { $pb = Get-Brush $p.Red; $pt = 'Shield OFF' }
    else { $pb = $mut; $pt = 'checking...' }
    Draw-Text $g $pt $F.PanelTitle $pb ($x + $w - (S 120)) ($y + (S 3)) (S 110) (S 20) 'RM'
    Draw-Text $g ([string]$D.Summary) $F.Muted $mut ($x + (S 10)) ($y + (S 28)) ($w - (S 20)) (S 14) 'LM'
    $when = 'not checked yet'
    if ($D.At) { $when = 'checked ' + (Format-Ago (([datetime]::UtcNow - [datetime]$D.At).TotalSeconds)) + ', checks again every 10 minutes' }
    if ($script:DnsRunning) { $when = 'checking now...' }
    Draw-Text $g $when $F.Muted $mut ($x + (S 10)) ($y + (S 43)) ($w - (S 20)) (S 14) 'LM'

    $servers = @($D.Servers)
    $rowH = (S 30); $top = $y + (S 62)
    $btnH = (S 28)
    $by = $y + $h - $btnH - (S 8)
    $vis = [Math]::Max(1, [int][Math]::Floor(($by - (S 4) - $top) / $rowH))
    if ($servers.Count -eq 0) { Draw-Text $g 'No DNS servers found yet.' $F.Chip $mut $x $top $w (S 30) 'CM' }
    for ($i = 0; $i -lt [Math]::Min($vis, $servers.Count); $i++) {
        $sv = $servers[$i]
        $ry = $top + $i * $rowH
        $g.DrawLine((Get-Pen $p.PanelLine $script:Px1 $false), [single]($x + (S 10)), [single]$ry, [single]($x + $w - (S 10)), [single]$ry)
        if ($sv.Kind -eq 'filter') { $dot = $p.Teal; $kind = 'Blocks scam sites' } elseif ($sv.Typo) { $dot = $p.Red; $kind = 'Looks like a typing mistake' } elseif ($sv.Kind -eq 'router') { $dot = $p.Off; $kind = 'Your router (passes on to your provider)' } else { $dot = $p.Amber; $kind = 'No scam filtering' }
        $st = 'not tested'
        if ($sv.Answers -eq $true) { $st = 'answers'; if ($null -ne $sv.Ms) { $st = ('answers in ' + $sv.Ms + ' ms') } }
        elseif ($sv.Answers -eq $false) { $st = 'NO ANSWER' }
        $ipText = [string]$sv.Ip
        if ($sv.Kind -eq 'router') { $ipText = 'router' }
        $lab = [string]$sv.Label
        if ($sv.Typo) { $lab = 'did you mean ' + $sv.Typo + '?' }
        $dr = (S 4)
        $g.FillEllipse((Get-Brush $dot), [single]($x + (S 12)), [single]($ry + (S 9) - $dr), [single](2 * $dr), [single](2 * $dr))
        Draw-Text $g ($ipText + '   ' + $lab) $F.PanelTitle $txt ($x + (S 24)) ($ry + (S 2)) ($w - (S 34)) (S 15) 'LM'
        $sc2 = $mut; if ($sv.Answers -eq $false) { $sc2 = Get-Brush $p.Red }
        Draw-Text $g ($kind + '  |  ' + $st) $F.Muted $sc2 ($x + (S 24)) ($ry + (S 16)) ($w - (S 34)) (S 13) 'LM'
    }
    if ($servers.Count -gt $vis) { Draw-Text $g ('+' + ($servers.Count - $vis) + ' more') $F.Muted $mut ($x + (S 10)) ($by - (S 16)) ($w - (S 20)) (S 14) 'RM' }

    # buttons
    $bw = [int](($w - (S 20) - (S 6)) / 2)
    $r1 = New-Object System.Drawing.Rectangle([int]($x + (S 10)), [int]$by, $bw, $btnH)
    $r2 = New-Object System.Drawing.Rectangle([int]($x + (S 10) + $bw + (S 6)), [int]$by, $bw, $btnH)
    $script:Hit['w_dns'] = $r1
    $script:Hit['dns_fix'] = $r2
    if ($script:DnsRunning) { $l1 = 'Checking...' } else { $l1 = 'Check now' }
    Draw-Button $g $r1 $l1 ($script:Hover -eq 'w_dns')
    if ($D.Shield -eq 'on') { $l2 = 'DNS options' } else { $l2 = 'Fix it' }
    Draw-Button $g $r2 $l2 ($script:Hover -eq 'dns_fix')
}

# ---- speed test history (the last results from speedtests.csv)
$script:SpeedHist = @()
$script:SpeedHistAt = [DateTime]::MinValue
function Load-SpeedHistory {
    $script:SpeedHistAt = Get-Date
    $list = New-Object System.Collections.ArrayList
    try {
        if (Test-Path -LiteralPath $script:SpeedCsvPath) {
            foreach ($ln in @(Get-Content -LiteralPath $script:SpeedCsvPath -Tail 40 -Encoding UTF8)) {
                if (-not $ln -or $ln.StartsWith('Timestamp')) { continue }
                $f = $ln.Split(',')
                if ($f.Count -lt 4) { continue }
                $t = [datetime]::MinValue
                if (-not [datetime]::TryParseExact($f[0], 'yyyy-MM-dd HH:mm:ss', $script:Inv, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { continue }
                $m = 0.0
                [void][double]::TryParse($f[2], [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$m)
                [void]$list.Add(@{ Time = $t; Result = [string]$f[1]; Mbps = $m; Source = [string]$f[3] })
            }
        }
    } catch { }
    $script:SpeedHist = @($list)
}

function Draw-SpeedView($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts; $wf = $script:Wifi
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text
    Draw-Panel $g $x $y $w $h ''
    Draw-NetViewPills $g $x $y
    $limit = [double]$script:Settings['SlowLimit']
    # right of the switches: when the next automatic test runs
    if ($script:SpeedRunning) { $auto = 'testing now...' }
    elseif ($script:Settings['AutoSpeedTest']) {
        $mins = [Math]::Max(0, [int][Math]::Ceiling(($script:NextAutoUtc - [datetime]::UtcNow).TotalMinutes))
        $auto = ('next auto test in ' + $mins + ' min')
    } else { $auto = 'auto test is off' }
    Draw-Text $g $auto $F.Muted $mut ($x + $w - (S 150)) ($y + (S 5)) (S 140) (S 14) 'RM'

    # last result
    if ($null -ne $wf.LastSpeed) {
        $lv = [double]$wf.LastSpeed
        if ($lv -lt $limit) { $lc = $p.Red } else { $lc = $p.Teal }
        Draw-Text $g ((Format-Mbps $lv) + ' Mbps') $F.Tile (Get-Brush $lc) ($x + (S 10)) ($y + (S 28)) (S 150) (S 24) 'LM'
        Draw-Text $g ('last result, ' + [string]$wf.LastSpeedText) $F.Muted $mut ($x + (S 10) + (S 150)) ($y + (S 28)) ($w - (S 170)) (S 24) 'LM'
    } else {
        Draw-Text $g 'No speed test yet.' $F.Chip $mut ($x + (S 10)) ($y + (S 28)) ($w - (S 20)) (S 24) 'LM'
    }
    Draw-Text $g ('Slow limit: ' + (Fmt $limit '0') + ' Mbps (change it in Settings > Network assistant)') $F.Muted $mut ($x + (S 10)) ($y + (S 52)) ($w - (S 20)) (S 14) 'LM'

    # recent results, newest first
    $btnH = (S 28)
    $by = $y + $h - $btnH - (S 8)
    $rowH = (S 20); $top = $y + (S 72)
    $vis = [Math]::Max(1, [int][Math]::Floor(($by - (S 4) - $top) / $rowH))
    $hist = @($script:SpeedHist)
    [array]::Reverse($hist)
    $hist = @($hist | Select-Object -First $vis)
    $mx = 1.0
    foreach ($e in $hist) { if ($e.Mbps -gt $mx) { $mx = [double]$e.Mbps } }
    if ($hist.Count -eq 0) { Draw-Text $g 'Results appear here after the first test.' $F.Muted $mut ($x + (S 10)) $top ($w - (S 20)) (S 20) 'LM' }
    $i = 0
    foreach ($e in $hist) {
        $ry = $top + $i * $rowH; $i++
        if ($e.Time.Date -eq (Get-Date).Date) { $tt = $e.Time.ToString('HH:mm', $script:Inv) } else { $tt = $e.Time.ToString('d MMM HH:mm', $script:Inv) }
        Draw-Text $g $tt $F.Muted $mut ($x + (S 10)) $ry (S 78) (S 18) 'LM'
        if ($e.Result -eq 'ok' -and $e.Mbps -gt 0) {
            if ($e.Mbps -lt $limit) { $bc = $p.Red } else { $bc = $p.Teal }
            $bx = $x + (S 92); $bmax = $w - (S 92) - (S 130)
            $g.FillRectangle((Get-Brush $p.Track), [single]$bx, [single]($ry + (S 6)), [single]$bmax, [single](S 6))
            $g.FillRectangle((Get-Brush $bc), [single]$bx, [single]($ry + (S 6)), [single]([Math]::Max([double](S 2), $bmax * $e.Mbps / $mx)), [single](S 6))
            Draw-Text $g ((Format-Mbps ([double]$e.Mbps)) + ' Mbps') $F.Muted (Get-Brush $bc) ($x + $w - (S 126)) $ry (S 76) (S 18) 'RM'
        } else {
            Draw-Text $g ('no result (' + $e.Result + ')') $F.Muted $mut ($x + (S 92)) $ry ($w - (S 92) - (S 60)) (S 18) 'LM'
        }
        Draw-Text $g $e.Source $F.Muted $mut ($x + $w - (S 48)) $ry (S 40) (S 18) 'RM'
    }

    $r1 = New-Object System.Drawing.Rectangle([int]($x + (S 10)), [int]$by, [int]($w - (S 20)), $btnH)
    $script:Hit['sp_run'] = $r1
    if ($script:SpeedRunning) { $l1 = 'Testing...' } else { $l1 = 'Run speed test now' }
    Draw-Button $g $r1 $l1 ($script:Hover -eq 'sp_run')
}

# Wi-Fi networks around you + the quietest channels (the second view of the bottom panel of the Network tab)
function Draw-NearbyList($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts; $sc = $script:Scan
    $mut = Get-Brush $p.Muted; $txt = Get-Brush $p.Text
    Draw-Panel $g $x $y $w $h ''
    $script:ScanPanelRect = New-Object System.Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h)
    Draw-NetViewPills $g $x $y

    # scan button (top right)
    $sr = New-Object System.Drawing.Rectangle([int]($x + $w - (S 84)), [int]($y + (S 3)), [int](S 76), [int](S 20))
    $script:Hit['sc_scan'] = $sr
    if ($script:Hover -eq 'sc_scan') { $sf = $p.Hover; $stc = $p.Text } else { $sf = $p.Chip; $stc = $p.Muted }
    Fill-Pill $g (Get-Brush $sf) $sr.X $sr.Y $sr.Width $sr.Height
    if ($sc.Running) { $slabel = 'Scanning...' } else { $slabel = 'Scan now' }
    Draw-Text $g $slabel $F.Muted (Get-Brush $stc) $sr.X $sr.Y $sr.Width $sr.Height 'CM'

    # advice (two lines)
    $adv = $sc.Advice
    $l1 = 'Scanning for nearby networks...'; $l2 = ''
    if ($sc.Seen -and $sc.Error) { $l1 = 'The scan failed'; $l2 = [string]$sc.Error }
    elseif ($sc.Seen -and @($sc.Networks).Count -eq 0) { $l1 = 'No Wi-Fi networks found'; $l2 = 'No Wi-Fi adapter, or Windows Location is off.' }
    elseif ($adv) {
        $b = $adv.Best24; $f5 = $adv.Best5
        $l1 = ('Quietest channel   2.4 GHz: ' + $b.Channel + '   5 GHz: ' + $f5.Channel)
        $mi = $adv.Mine
        if ($mi) {
            $bestForMine = $b; if ($mi.Band -like '5*') { $bestForMine = $f5 }
            if ($mi.Channel -eq $bestForMine.Channel -or $mi.Score -le ($bestForMine.Score + 0.15)) { $l2 = ('Your channel ' + $mi.Channel + ' is one of the quietest.') }
            else { $l2 = ('Your channel ' + $mi.Channel + ' is crowded (' + $mi.Count + ' overlap). Try ' + $bestForMine.Channel + ' in your router.') }
        }
    }
    Draw-Text $g $l1 $F.Chip $txt ($x + (S 10)) ($y + (S 27)) ($w - (S 20)) (S 16) 'LM'
    Draw-Text $g $l2 $F.Muted (Get-Brush $p.Teal) ($x + (S 10)) ($y + (S 43)) ($w - (S 20)) (S 14) 'LM'

    # list
    $nets = @($sc.Networks | Sort-Object { -[int]$_.Signal })
    $rowH = (S 30); $top = $y + (S 62)
    $vis = [Math]::Max(1, [int][Math]::Floor(($h - (S 62) - (S 4)) / $rowH))
    $maxScroll = [Math]::Max(0, $nets.Count - $vis)
    if ($script:ScanScroll -gt $maxScroll) { $script:ScanScroll = $maxScroll }
    if ($script:ScanScroll -lt 0) { $script:ScanScroll = 0 }
    for ($i = 0; $i -lt $vis; $i++) {
        $idx = $script:ScanScroll + $i
        if ($idx -ge $nets.Count) { break }
        $n = $nets[$idx]
        $ry = $top + $i * $rowH
        $g.DrawLine((Get-Pen $p.PanelLine $script:Px1 $false), [single]($x + (S 10)), [single]$ry, [single]($x + $w - (S 10)), [single]$ry)
        $name = [string]$n.Ssid; if (-not $name) { $name = '(hidden network)' }
        if ($n.Mine) { $nb = Get-Brush $p.Teal; $name = $name + '   (connected)' } else { $nb = $txt }
        Draw-Text $g $name $F.PanelTitle $nb ($x + (S 12)) ($ry + (S 2)) ($w - (S 170)) (S 15) 'LM'
        $det = ([string]$n.Band + '  channel ' + $n.Channel)
        if ($n.Auth) { $det += ('  |  ' + $n.Auth) }
        Draw-Text $g $det $F.Muted $mut ($x + (S 12)) ($ry + (S 16)) ($w - (S 170)) (S 13) 'LM'
        $sg = [int]$n.Signal
        $bx = $x + $w - (S 140); $bwid = (S 80)
        $g.FillRectangle((Get-Brush $p.Track), [single]$bx, [single]($ry + (S 12)), [single]$bwid, [single](S 6))
        $g.FillRectangle((Get-Brush (Get-SignalColor $sg)), [single]$bx, [single]($ry + (S 12)), [single]($bwid * $sg / 100.0), [single](S 6))
        Draw-Text $g ([string]$sg + '%') $F.Muted $txt ($x + $w - (S 56)) ($ry + (S 8)) (S 46) (S 14) 'RM'
    }
    if ($nets.Count -gt $vis) {
        $trackH = $vis * $rowH
        $thumbH = [Math]::Max((S 16), [int]($trackH * $vis / [double]$nets.Count))
        $thumbY = $top + [int](($trackH - $thumbH) * $script:ScanScroll / [double]$maxScroll)
        $g.FillRectangle((Get-Brush ([System.Drawing.Color]::FromArgb(110, 138, 155, 176))), [single]($x + $w - (S 6)), [single]$thumbY, [single](S 3), [single]$thumbH)
    }
}

# ---------- battery (laptops) ----------
$script:Battery = @{ Present = $false; Pct = 0; PluggedIn = $true; Charging = $false; Minutes = $null; At = [DateTime]::MinValue; Alerted = $false }

function Update-Battery {
    $now = Get-Date
    if (($now - $script:Battery.At).TotalSeconds -lt 10) { return }
    $script:Battery.At = $now
    try {
        $pw = [System.Windows.Forms.SystemInformation]::PowerStatus
        $st = $pw.BatteryChargeStatus.ToString()
        $pc = [double]$pw.BatteryLifePercent
        if ($st -match 'NoSystemBattery' -or $pc -lt 0 -or $pc -gt 1.0) { $script:Battery.Present = $false; return }
        $script:Battery.Present = $true
        $script:Battery.Pct = [int][Math]::Round($pc * 100)
        $script:Battery.PluggedIn = ($pw.PowerLineStatus.ToString() -eq 'Online')
        $script:Battery.Charging = ($st -match 'Charging')
        if ([int]$pw.BatteryLifeRemaining -gt 0) { $script:Battery.Minutes = [int]($pw.BatteryLifeRemaining / 60) } else { $script:Battery.Minutes = $null }
    } catch { $script:Battery.Present = $false }
}

function Eval-Battery {
    $b = $script:Battery
    if (-not $b.Present) { return }
    $low = [int]$script:Settings['BatteryLowPct']
    if ($b.PluggedIn -or $b.Pct -gt ($low + 5)) { $b.Alerted = $false; return }
    if ($b.Alerted -or $b.Pct -gt $low) { return }
    if (-not [bool]$script:Settings['AlertBattery'] -or -not [bool]$script:Settings['AlertsEnabled']) { return }
    $b.Alerted = $true
    $lines = @('Plug in the charger soon.')
    if ($null -ne $b.Minutes) { $lines += ('About ' + (Format-Duration ($b.Minutes * 60.0)) + ' left.') }
    if ($b.Pct -le 10) { $acc = $script:Pal.Red } else { $acc = $script:Pal.Amber }
    $item = [pscustomobject]@{ Type = 'battery'; Mac = ''; Title = 'Battery low'; Value = $null; ValueText = ([string]$b.Pct + '%'); Accent = $acc; Lines = $lines; Buttons = @(@{ Id = 'ok'; Text = 'OK'; Primary = $true }) }
    Request-Alert $item
}

function Draw-BatteryPanel($g, [double]$x, [double]$y, [double]$w, [double]$h) {
    $p = $script:Pal; $F = $script:Fonts; $b = $script:Battery
    Draw-Panel $g $x $y $w $h ''
    if ($b.Pct -le 15 -and -not $b.PluggedIn) { $col = $p.Red } elseif ($b.Pct -le 30 -and -not $b.PluggedIn) { $col = $p.Amber } else { $col = $p.Teal }
    Draw-Text $g 'Battery' $F.Muted (Get-Brush $p.Muted) ($x + (S 10)) $y (S 60) $h 'LM'
    $bx = $x + (S 70); $bwid = (S 90); $by = $y + ($h - (S 10)) / 2
    $g.FillRectangle((Get-Brush $p.Track), [single]$bx, [single]$by, [single]$bwid, [single](S 10))
    $g.FillRectangle((Get-Brush $col), [single]$bx, [single]$by, [single]($bwid * $b.Pct / 100.0), [single](S 10))
    if ($b.Charging) { $state = 'charging' } elseif ($b.PluggedIn) { $state = 'plugged in' } else { $state = 'on battery' }
    $t = ([string]$b.Pct + '%   ' + $state)
    if (-not $b.PluggedIn -and $null -ne $b.Minutes) { $t += ('   ' + (Format-Duration ($b.Minutes * 60.0)) + ' left') }
    Draw-Text $g $t $F.PanelTitle (Get-Brush $p.Text) ($bx + $bwid + (S 10)) $y ($w - ($bx - $x) - $bwid - (S 20)) $h 'LM'
}

# ---------- guess what a device is (when you have not named it) ----------
# Best effort: the name the device announces, its DHCP class, then the maker of its network card. Always shown as a guess.
$script:OuiRaw = @'
Apple|00:03:93 00:0A:95 00:0D:93 00:11:24 00:14:51 00:16:CB 00:17:F2 00:19:E3 00:1B:63 00:1C:B3 00:1E:C2 00:1F:5B 00:21:E9 00:23:12 00:25:00 00:26:08 3C:07:54 3C:15:C2 40:6C:8F 44:D8:84 5C:F9:38 60:03:08 70:56:81 78:31:C1 7C:6D:62 84:38:35 88:63:DF 8C:85:90 A4:5E:60 A8:5B:78 AC:BC:32 B8:E8:56 BC:52:B7 C8:2A:14 D0:03:4B D4:9A:20 DC:2B:2A F0:18:98 F4:5C:89 F8:1E:DF
Samsung|00:12:47 00:15:99 00:16:32 00:17:C9 00:1A:8A 00:21:19 00:23:39 08:08:C2 10:1D:C0 18:3A:2D 34:23:BA 5C:0A:5B 78:47:1D 8C:77:12 BC:44:86 E8:50:8B
Google|3C:5A:B4 54:60:09 F4:F5:D8 A4:77:33 30:FD:38
Amazon|00:FC:8B 0C:47:C9 34:D2:70 40:B4:CD 44:65:0D 50:DC:E7 68:37:E9 74:C2:46 84:D6:D0 A0:02:DC F0:D2:F1 FC:65:DE
TP-Link|14:CC:20 18:A6:F7 1C:3B:F3 50:C7:BF 54:C8:0F 60:E3:27 64:70:02 98:DA:C4 A0:F3:C1 B0:95:75 C0:4A:00 D8:07:B6 E8:DE:27 EC:08:6B F4:F2:6D
Netgear|00:09:5B 00:0F:B5 00:14:6C 00:1B:2F 00:22:3F 20:4E:7F 28:C6:8E 44:94:FC A0:40:A0 A4:2B:8C C0:3F:0E E0:46:9A
ASUS|00:0C:6E 00:11:2F 00:15:F2 00:17:31 00:1A:92 00:1E:8C 00:22:15 04:D4:C4 08:60:6E 10:BF:48 1C:87:2C 30:5A:3A 50:46:5D 60:45:CB AC:22:0B F8:32:E4
D-Link|00:05:5D 00:0D:88 00:11:95 00:13:46 00:15:E9 00:17:9A 00:19:5B 00:1B:11 00:1C:F0 00:1E:58 14:D6:4D 1C:7E:E5 28:10:7B 78:54:2E 90:94:E4 B8:A3:86 C8:BE:19
Xiaomi|04:CF:8C 0C:1D:AF 14:F6:5A 28:6C:07 34:CE:00 38:A4:ED 50:64:2B 64:09:80 64:B4:73 74:51:BA 78:11:DC 7C:1D:D9 8C:BE:BE 98:FA:E3 9C:99:A0 AC:C1:EE F0:B4:29 F8:A4:5F
Huawei|00:E0:FC 04:C0:6F 20:F3:A3 28:3C:E4 48:46:FB 54:A5:1B 70:72:3C 80:FB:06 AC:E2:15 E0:19:1D
Raspberry Pi|B8:27:EB DC:A6:32 E4:5F:01 D8:3A:DD 2C:CF:67
Espressif (smart-home chip)|24:0A:C4 24:6F:28 30:AE:A4 3C:71:BF 84:CC:A8 7C:9E:BD A4:CF:12 BC:DD:C2 CC:50:E3 EC:FA:BC
Microsoft|00:03:FF 00:0D:3A 00:12:5A 00:15:5D 00:17:FA 00:1D:D8 00:22:48
Sony|00:01:4A 00:13:A9 00:19:C5 00:1D:0D 00:24:BE BC:60:A7 70:9E:29 F8:D0:AC
Nintendo|00:09:BF 00:16:56 00:17:AB 00:19:1D 00:19:FD 00:1A:E9 00:1B:7A 00:1C:BE 00:1E:35 00:1F:32 00:21:47 00:22:AA 00:22:D7 00:23:CC 00:24:1E 00:25:A0 2C:10:C1 34:AF:2C 40:D2:8A 58:2F:40 7C:BB:8A 8C:56:C5 98:B6:E9 A4:C0:E1 B8:8A:EC CC:9E:00 D8:6B:F7 E0:0C:7F E8:4E:CE
Sonos|00:0E:58 34:7E:5C 48:A6:B8 5C:AA:FD 78:28:CA 94:9F:3E B8:E9:37
Roku|00:0D:4B 08:05:81 10:59:32 20:EF:BD 84:EA:ED B0:A7:37 B8:3E:59 CC:6D:A0 D8:31:34 DC:3A:5E
Philips Hue|00:17:88 EC:B5:FA
Ubiquiti|00:15:6D 00:27:22 04:18:D6 24:A4:3C 44:D9:E7 68:D7:9A 74:83:C2 78:8A:20 80:2A:A8 B4:FB:E4 DC:9F:DB F0:9F:C2 FC:EC:DA
Intel (PC network card)|00:02:B3 00:03:47 00:04:23 00:07:E9 00:0C:F1 00:0E:35 00:11:11 00:12:F0 00:13:02 00:13:20 00:13:CE 00:13:E8 00:15:00 00:16:6F 00:16:76 00:16:EA 00:18:DE 00:19:D1 00:1B:21 00:1C:BF 00:1E:64 00:1F:3B 00:21:5C 00:22:FA 00:24:D7 00:27:10
Virtual machine (VMware)|00:0C:29 00:50:56 00:05:69
Virtual machine (VirtualBox)|08:00:27
Virtual machine (QEMU/KVM)|52:54:00
Synology NAS|00:11:32
'@
$script:Oui = @{}
foreach ($ln in ($script:OuiRaw -split "`r?`n")) {
    if (-not $ln.Contains('|')) { continue }
    $parts = $ln.Split('|')
    foreach ($pre in ($parts[1].Trim() -split '\s+')) { if ($pre) { $script:Oui[$pre.ToUpper()] = $parts[0].Trim() } }
}
# what the device says about itself (name it announced), checked first because it is the most reliable
$script:HostHints = @(
    @('iphone', 'iPhone'), @('ipad', 'iPad'), @('macbook|imac|mac-?mini|^mbp|^mac-', 'Mac'), @('apple-?tv', 'Apple TV'),
    @('galaxy|^sm-[a-z]\d', 'Samsung phone or tablet'), @('^android|android-', 'Android device'),
    @('echo|alexa|kindle|fire-?tv|amazon', 'Amazon device'), @('roku', 'Roku'), @('chromecast|google-?home|^nest', 'Google device'),
    @('playstation|^ps[345]', 'PlayStation'), @('xbox', 'Xbox'), @('nintendo', 'Nintendo console'),
    @('^desktop-|^laptop-|^win-', 'Windows PC'), @('printer|^epson|^brother|^canon|^hp[0-9a-f]{6}', 'Printer'),
    @('^esp[-_]|espressif', 'Smart-home device (ESP)'), @('^raspberrypi', 'Raspberry Pi'),
    @('(^|[-_ ])tv($|[-_ ])|bravia|webos|tizen', 'Smart TV'), @('(^|[-_ ])cam($|[-_ ])|camera', 'Camera')
)

function Get-DeviceGuess($d) {
    $hn = ([string]$d.Hostname).ToLower()
    if ($hn) { foreach ($rule in $script:HostHints) { if ($hn -match $rule[0]) { return [string]$rule[1] } } }
    $vc = [string]$d.Vendor
    if ($vc -like 'MSFT*') { return 'Windows PC' }
    if ($vc -like 'android-dhcp*') { return 'Android device' }
    if ($vc -like 'dhcpcd*' -or $vc -like 'udhcp*') { return 'Linux or smart-home device' }
    $mac = [string]$d.Mac
    if ($mac.Length -ge 8) {
        $pre = $mac.Substring(0, 8).ToUpper()
        if ($script:Oui.ContainsKey($pre)) {
            $lab = [string]$script:Oui[$pre]
            if ($lab.Contains('(') -or $lab -like '*NAS') { return $lab }
            return ($lab + ' device')
        }
    }
    if ($d.Private) { return 'Phone or laptop (private address)' }
    return ''
}

function Open-ProviderReport { Open-WebPage 'report' $script:ReportHtml }

# ---------------------------------------------------------------- Wi-Fi periodic work (every 0.5 s)
$script:WifiTickCount = 0
function Update-WifiTick {
    $script:WifiTickCount = $script:WifiTickCount + 1
    if (-not [bool]$script:Settings['WifiEnabled']) { if (($script:WifiTickCount % 10) -eq 0) { Clean-WifiOld }; return }
    [void](Process-DeviceQueue)
    $age = ([datetime]::UtcNow - $script:LastDevSave).TotalSeconds
    if (($script:DevicesDirty -and $age -gt 10) -or $age -gt 120) { Save-Devices }
    if (($script:WifiTickCount % 2) -eq 0) {
        Update-SpeedScheduler
        Update-DnsScheduler
        Update-FullTestWatcher
        Update-OutageWatcher
        Update-ScanWatcher
        if ([bool]$script:Settings['Expanded'] -and [string]$script:Settings['ExpandedTab'] -eq 'Network' -and [string]$script:Settings['NetView'] -eq 'Speed' -and (((Get-Date) - $script:SpeedHistAt).TotalSeconds -gt 10)) { Load-SpeedHistory }
        if (($script:WifiTickCount % 20) -eq 0) { Clean-WifiOld; Flush-NetworkCsv; Eval-DataLimit }
    }
}

# ---------------------------------------------------------------- timers
$script:TimerMain = New-Object System.Windows.Forms.Timer
$script:TimerMain.Interval = [int]$script:Settings['RefreshMs']
$script:TimerMain.Add_Tick({ try { Main-Tick } catch { Log-Once 'Main tick' (Err-Text $_) } })

$script:TimerAnim = New-Object System.Windows.Forms.Timer
$script:TimerAnim.Interval = 15
$script:TimerAnim.Add_Tick({ try { Step-SnapAnim } catch { $script:Anim['Active'] = $false; $script:TimerAnim.Stop(); Log-Once 'Anim tick' (Err-Text $_) } })

$script:TimerWifi = New-Object System.Windows.Forms.Timer
$script:TimerWifi.Interval = 500
$script:TimerWifi.Add_Tick({ try { Update-WifiTick } catch { Log-Once 'Wifi tick' (Err-Text $_) } })

$script:TimerBadge = New-Object System.Windows.Forms.Timer
$script:TimerBadge.Interval = 500
$script:TimerBadge.Add_Tick({ try { Update-Badge } catch { Log-Once 'Badge tick' (Err-Text $_) } })

$script:TimerFull = New-Object System.Windows.Forms.Timer
$script:TimerFull.Interval = 1000
$script:TimerFull.Add_Tick({ try { Check-Fullscreen } catch { Log-Once 'Fullscreen tick' (Err-Text $_) } })

$script:TimerResize = New-Object System.Windows.Forms.Timer
$script:TimerResize.Interval = 15
$script:TimerResize.Add_Tick({ try { Step-ResizeAnim } catch { Log-Once 'Resize anim' (Err-Text $_); try { Finish-ResizeAnim } catch { } } })
$script:TimerWarm = New-Object System.Windows.Forms.Timer
$script:TimerWarm.Interval = 6000
$script:TimerWarm.Add_Tick({ try { $script:TimerWarm.Stop(); Invoke-Warmup } catch { Log-Once 'Warm-up' (Err-Text $_) } })

$script:TimerLayout = New-Object System.Windows.Forms.Timer
$script:TimerLayout.Interval = 3000
$script:TimerLayout.Add_Tick({ try { Check-Screens } catch { Log-Once 'Layout tick' (Err-Text $_) } })

$script:TimerGlass = New-Object System.Windows.Forms.Timer
$script:TimerGlass.Interval = 2000
$script:TimerGlass.Add_Tick({ try { Update-Glass } catch { Log-Once 'Glass tick' (Err-Text $_) } })

$script:TimerShow = New-Object System.Windows.Forms.Timer
$script:TimerShow.Interval = 250
$script:TimerShow.Add_Tick({ try { if ($script:ShowEvent.WaitOne(0)) { Restore-Widget }; Check-HistoryBuild } catch { Log-Once 'Show tick' (Err-Text $_) } })

# ---------------------------------------------------------------- shutdown
function Stop-Everything {
    if ($script:Cleaned) { return }
    $script:Cleaned = $true
    Write-Log 'Shutting down'
    foreach ($t in @($script:TimerMain, $script:TimerAnim, $script:TimerResize, $script:TimerWarm, $script:TimerFull, $script:TimerWifi, $script:TimerBadge, $script:TimerLayout, $script:TimerGlass, $script:TimerShow, $script:PopRepaintTimer, $script:PopHideTimer)) {
        try { if ($null -ne $t) { $t.Stop(); $t.Dispose() } } catch { }
    }
    try { if ($null -ne $script:Popup) { $script:Popup.Hide(); $script:Popup.Dispose() } } catch { }
    Reset-Badge
    try { if ($null -ne $script:BadgeMenu) { $script:BadgeMenu.Dispose() } } catch { }
    try { if ($null -ne $script:Menu) { $script:Menu.Dispose() } } catch { }
    Stop-Sampler
    Stop-TaskbarProbe
    try { Stop-WifiServices } catch { }
    try { if ($script:Devices.Count -gt 0) { Save-Devices } } catch { }
    try { Flush-NetworkCsv } catch { }
    Drain-Events
    try { [void]$script:AlertCsv.Flush($script:AlertsPath) } catch { }
    try { if ($script:GlassOk) { [void](Set-Affinity 0) } } catch { }
    try { Free-GlassBmp } catch { }
    try { if ($null -ne $script:AnimBmp) { $script:AnimBmp.Dispose() } } catch { }
    try { Clear-GdiCache } catch { }
    try { foreach ($ft in @($script:Fonts.Values)) { $ft.Dispose() } } catch { }
    try { foreach ($sf in @($script:Sf.Values)) { $sf.Dispose() } } catch { }
    try { if ($script:IconHandle) { [void][Native]::DestroyIcon($script:IconHandle) } } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Mutex.Dispose() } catch { }
    try { $script:ShowEvent.Dispose() } catch { }
    Write-Log 'Exit'
}

# ---------------------------------------------------------------- run
try {
    Write-Log ('Start v' + $script:Version + ' pid=' + $PID + ' PS=' + $PSVersionTable.PSVersion + ' dpiScale=' + (Fmt $script:Scale '0.00'))
    if ($script:Settings['Glass']) { $script:Form.Opacity = 0.999 }
    if ($script:Settings['ClickThrough']) { $script:Form.ClickThrough = $true; $script:Form.Opacity = 0.999 }
    try { Sync-Startup } catch { Write-Log ('Startup sync: ' + $_.Exception.Message) 'error' }
    Apply-Layout
    Restore-LastSpeed
    Load-Devices
    Load-Outages
    if ([bool]$script:Settings['WifiEnabled']) { try { Start-WifiServices } catch { Write-Log ('Network services start failed: ' + $_.Exception.Message) 'ERROR' } }
    Start-Sampler
    try { Start-TaskbarProbe } catch { Write-Log ('Taskbar probe start failed: ' + $_.Exception.Message) 'error' }
    $script:TimerMain.Start()
    $script:TimerAnim.Stop()
    $script:TimerLayout.Start()
    $script:TimerGlass.Start()
    $script:TimerWarm.Start()
    $script:TimerFull.Start()
    $script:TimerWifi.Start()
    Update-Badge
    $script:TimerBadge.Start()
    $script:TimerShow.Start()
    [System.Windows.Forms.Application]::Run($script:Form)
} catch {
    Write-Log ('FATAL: ' + (Err-Text $_))
} finally {
    Stop-Everything
}