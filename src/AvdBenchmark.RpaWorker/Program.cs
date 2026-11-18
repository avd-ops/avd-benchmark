// Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Conditions;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

namespace AvdBenchmark.RpaWorker
{
    internal static class Program
    {
        private const int JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int WtsSessionInfoEx = 25;
        private const int UoiName = 2;

        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr pMemory);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseDesktop(IntPtr hDesktop);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int infoType, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, int cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private static bool IsInteractiveDesktopUnlocked()
        {
            IntPtr hDesk = OpenInputDesktop(0, false, 0x0001);
            if (hDesk == IntPtr.Zero) return false;
            try
            {
                var sb = new StringBuilder(64);
                int needed;
                if (!GetUserObjectInformation(hDesk, UoiName, sb, sb.Capacity * 2, out needed))
                {
                    return false;
                }
                return string.Equals(sb.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
            }
            finally
            {
                CloseDesktop(hDesk);
            }
        }

        private static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            return job;
        }

        private static int Main(string[] args)
        {
            if (args.Length < 4)
            {
                Console.Error.WriteLine("Usage: AvdBenchmark.RpaWorker.exe <fixtureExePath> <scratchDir> <logPath> <iterations>");
                return 2;
            }

            string fixtureExe = args[0];
            string scratchDir = args[1];
            string logPath = args[2];
            int iterations = Math.Max(1, int.Parse(args[3]));

            Directory.CreateDirectory(scratchDir);
            Directory.CreateDirectory(Path.GetDirectoryName(logPath) ?? scratchDir);

            using (var writer = new StreamWriter(logPath, true, Encoding.ASCII))
            {
                for (int i = 0; i < iterations; i++)
                {
                    if (!IsInteractiveDesktopUnlocked())
                    {
                        writer.WriteLine("{\"step\":\"desktop-guard\",\"status\":\"not-ready\"}");
                        Thread.Sleep(2000);
                        continue;
                    }

                    IntPtr job = CreateKillOnCloseJob();
                    Process proc = null;
                    try
                    {
                        var sw = Stopwatch.StartNew();
                        proc = Process.Start(new ProcessStartInfo(fixtureExe, "\"" + scratchDir + "\"") { UseShellExecute = false });
                        if (proc == null)
                        {
                            writer.WriteLine("{\"step\":\"launch-fixture\",\"status\":\"failed\"}");
                            continue;
                        }
                        if (job != IntPtr.Zero) AssignProcessToJobObject(job, proc.Handle);

                        long launchMs = sw.ElapsedMilliseconds;
                        using (var automation = new UIA3Automation())
                        {
                            var cf = new ConditionFactory(automation.PropertyLibrary);
                            AutomationElement win = null;
                            while (sw.ElapsedMilliseconds < 30000)
                            {
                                win = automation.FromHandle(proc.MainWindowHandle);
                                if (win != null && proc.MainWindowHandle != IntPtr.Zero) break;
                                Thread.Sleep(50);
                            }
                            if (win == null)
                            {
                                writer.WriteLine("{\"step\":\"window-ready\",\"status\":\"timeout\"}");
                                continue;
                            }
                            long readyMs = sw.ElapsedMilliseconds - launchMs;

                            var swAction = Stopwatch.StartNew();
                            var editor = win.FindFirstDescendant(cf.ByAutomationId("FixtureEditor"));
                            if (editor != null)
                            {
                                editor.Focus();
                                editor.AsTextBox().Text = "synthetic-rpa-iteration-" + i;
                            }
                            long actionMs = swAction.ElapsedMilliseconds;

                            var swSave = Stopwatch.StartNew();
                            var saveBtn = win.FindFirstDescendant(cf.ByAutomationId("SaveFixtureButton"));
                            if (saveBtn != null) saveBtn.AsButton().Invoke();
                            proc.CloseMainWindow();
                            proc.WaitForExit(5000);
                            long saveCloseMs = swSave.ElapsedMilliseconds;

                            writer.WriteLine(string.Format(
                                "{{\"iteration\":{0},\"status\":\"ok\",\"appLaunchMs\":{1},\"windowReadyMs\":{2},\"actionLatencyMs\":{3},\"saveCloseMs\":{4}}}",
                                i, launchMs, readyMs, actionMs, saveCloseMs));
                        }
                    }
                    catch
                    {
                        // Zero-reflection error logging: emit opaque status only, never window titles or paths.
                        writer.WriteLine("{\"step\":\"iteration\",\"status\":\"error\"}");
                    }
                    finally
                    {
                        if (job != IntPtr.Zero) CloseHandle(job);
                        if (proc != null) proc.Dispose();
                    }
                }
            }
            return 0;
        }
    }
}
