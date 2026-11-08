using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

// Small per-user bootstrapper; no administrator rights or central file service.
internal static class Program {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SHChangeNotify(uint eventId, uint flags, string path, IntPtr unused);

    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // Used by the build verification. Extraction does not install or launch.
        if (args.Length == 2 && args[0] == "--extract") {
            Extract(Path.GetFullPath(args[1])); return;
        }
        Application.Run(new InstallerForm());
    }

    internal static void Extract(string target) {
        Directory.CreateDirectory(target);
        string root = Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("Line.zip"))
        using (var archive = new ZipArchive(payload, ZipArchiveMode.Read)) {
            foreach (ZipArchiveEntry entry in archive.Entries) {
                string output = Path.GetFullPath(Path.Combine(root, entry.FullName));
                if (!output.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid archive path");
                if (String.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(output); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(output));
                entry.ExtractToFile(output, true);
            }
        }
    }

    internal static void Shortcut(string path, string executable, string directory) {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        dynamic shell = Activator.CreateInstance(shellType);
        dynamic link = shell.CreateShortcut(path);
        link.TargetPath = executable; link.WorkingDirectory = directory;
        link.Description = "Line - direct file sharing";
        // A distinct icon path avoids stale launcher/brand icons cached for line.exe.
        link.IconLocation = Path.Combine(directory, "line-arrows.ico") + ",0"; link.Save();
        SHChangeNotify(0x2000, 0x1005, path, IntPtr.Zero); // UPDATEITEM, PATHW | FLUSH
    }
}

internal sealed class InstallerForm : Form {
    readonly Button install = new Button();
    readonly Label status = new Label();
    readonly ProgressBar progress = new ProgressBar();
    readonly CheckBox desktop = new CheckBox();
    readonly string target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Line");
    bool working;

    internal InstallerForm() {
        Text = "Install Line"; ClientSize = new Size(500, 355);
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen; BackColor = Color.FromArgb(246,245,243);
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
        Font = new Font("Segoe UI", 10);
        var mark = new Bitmap(48, 48);
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("LineIcon.png"))
        using (Image image = Image.FromStream(source))
        using (Graphics graphics = Graphics.FromImage(mark)) {
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(image, new Rectangle(0,0,48,48));
        }
        var brand = new PictureBox { Image = mark, Bounds = new Rectangle(33,28,48,48), SizeMode = PictureBoxSizeMode.Zoom };
        var title = new Label { Text = "Line", Font = new Font("Segoe UI", 25, FontStyle.Bold),
            ForeColor = Color.FromArgb(36,34,32), Bounds = new Rectangle(94,20,365,48) };
        var creator = new Label { Text = "ACTIVE CREATORS", Font = new Font("Segoe UI", 7),
            ForeColor = Color.DimGray, Bounds = new Rectangle(98,67,365,18) };
        var body = new Label { Text = "Share files between your PC and phone.\nNo account. No cloud storage.",
            Bounds = new Rectangle(33,92,435,58) };
        var location = new Label { Text = "Install for this user only:\n" + target,
            Font = new Font("Segoe UI", 8), ForeColor = Color.DimGray, Bounds = new Rectangle(33,159,435,42) };
        desktop.Text = "Create a desktop shortcut"; desktop.Checked = true;
        desktop.SetBounds(33,208,430,28);
        progress.SetBounds(33,245,430,7); progress.Style = ProgressBarStyle.Marquee; progress.Visible = false;
        status.SetBounds(33,260,430,24); status.Font = new Font("Segoe UI", 8);
        install.Text = "Install and open"; install.SetBounds(280,296,185,42);
        install.BackColor = Color.FromArgb(41,39,37); install.ForeColor = Color.White; install.FlatStyle = FlatStyle.Flat;
        install.Click += async (sender, e) => await Install();
        Controls.AddRange(new Control[] { brand, title, creator, body, location, desktop, progress, status, install });
        FormClosing += (sender,e) => { if (working) e.Cancel = true; };
    }

    async Task Install() {
        if (Process.GetProcessesByName("line").Length > 0) {
            MessageBox.Show("Close Line before installing or updating.", "Line"); return;
        }
        working = true; install.Enabled = false; desktop.Enabled = false; progress.Visible = true;
        status.Text = "Getting things ready…";
        try {
            await Task.Run(() => Program.Extract(target));
            string exe = Path.Combine(target, "line.exe");
            string menu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", "Line.lnk");
            Program.Shortcut(menu, exe, target);
            if (desktop.Checked) Program.Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Line.lnk"), exe, target);
            string uninstall = Path.Combine(target, "Uninstall.ps1");
            File.WriteAllText(uninstall, @"$ErrorActionPreference = 'Stop'
$expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Line'))
$actual = [IO.Path]::GetFullPath($PSScriptRoot)
if ($actual -ne $expected -or !(Test-Path -LiteralPath (Join-Path $actual 'line.exe'))) { throw 'Unexpected install directory' }
if (Get-Process -Name line -ErrorAction SilentlyContinue) { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('Close Line and try again.'); exit 1 }
$shortcuts = @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Line.lnk'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Line.lnk'))
foreach ($shortcut in $shortcuts) { if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force } }
Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Line' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $actual -Recurse -Force
# Received files and settings outside the install directory are preserved.
");
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\Line")) {
                key.SetValue("DisplayName", "Line"); key.SetValue("DisplayVersion", "0.9.0");
                key.SetValue("Publisher", "Active Creators"); key.SetValue("InstallLocation", target); key.SetValue("DisplayIcon", Path.Combine(target, "line-arrows.ico"));
                key.SetValue("UninstallString", "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + uninstall + "\"");
                key.SetValue("NoModify", 1); key.SetValue("NoRepair", 1);
            }
            status.Text = "Line is ready.";
            Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = target, UseShellExecute = true });
            working = false; Close();
        } catch (Exception e) {
            working = false; progress.Visible = false; install.Enabled = true; desktop.Enabled = true;
            status.Text = "Installation could not be completed.";
            MessageBox.Show(e.Message, "Line", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
