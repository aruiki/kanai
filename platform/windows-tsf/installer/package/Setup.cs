using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

// The complete MSI is embedded; no executable downloads or policy changes.
internal static class Setup {
    [STAThread]
    private static int Main() {
        if (!Environment.Is64BitOperatingSystem) {
            MessageBox.Show("64bit版Windowsが必要です。", "KanaAI");
            return 1633;
        }
        string directory = Path.Combine(Path.GetTempPath(), "KanaAI-" + Guid.NewGuid().ToString("N"));
        string package = Path.Combine(directory, "KanaAI.msi");
        try {
            Directory.CreateDirectory(directory);
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("KanaAI.msi"))
            using (FileStream file = new FileStream(package, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read)) {
                if (payload == null) throw new InvalidDataException("Installer payload is missing.");
                payload.CopyTo(file);
                file.Flush(true);
                var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "msiexec.exe"),
                    "/i \"" + package + "\" /qb! /norestart") {
                    UseShellExecute = false, CreateNoWindow = true
                };
                using (Process process = Process.Start(info)) {
                    process.WaitForExit();
                    int code = process.ExitCode;
                    if (code == 0 || code == 3010) {
                        MessageBox.Show(code == 3010 ? "インストールしました。Windowsを再起動してください。" :
                            "インストールしました。Win + SpaceでKanaAIを選択してください。", "KanaAI");
                    } else {
                        MessageBox.Show("インストールできませんでした。エラーコード: " + code, "KanaAI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    return code;
                }
            }
        } catch (Exception error) {
            MessageBox.Show("インストールできませんでした。\n" + error.Message, "KanaAI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        } finally {
            try { if (File.Exists(package)) File.Delete(package); if (Directory.Exists(directory)) Directory.Delete(directory); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
